const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// PLATFORM-SPECIFIC HELPERS
// ============================================================================

/// Cross-platform home directory lookup
fn getHomeDir(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        // On Windows, use USERPROFILE environment variable
        var env_map = try std.process.getEnvMap(allocator);
        defer env_map.deinit();
        if (env_map.get("USERPROFILE")) |profile| {
            return try allocator.dupe(u8, profile);
        }
        return try allocator.dupe(u8, "C:\\Users\\Default");
    } else {
        // On Unix, use HOME environment variable
        const home = std.posix.getenv("HOME") orelse "/tmp";
        return try allocator.dupe(u8, home);
    }
}

// ============================================================================
// DRIVER INTERFACE
// ============================================================================
// This defines the contract that all inference drivers must implement.
// Drivers are dynamically loaded shared libraries (.dylib/.so/.dll) that
// provide the actual model loading and inference capabilities.
//
// Drivers can be written in ANY language that supports C ABI:
//   - Zig (recommended)
//   - C/C++
//   - Rust (with extern "C")
//   - Go (with cgo)
//
// Example drivers:
//   - granville-llama (llama.cpp backend)
//   - granville-whisper (whisper.cpp for audio)
//   - custom GPU backends
// ============================================================================

pub const REGISTRY_URL = "https://raw.githubusercontent.com/rjpruitt16/granville/main/registry.json";
pub const DRIVERS_DIR = ".granville/drivers";

/// Driver metadata stored in driver.json
pub const DriverManifest = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    platform: []const u8, // e.g., "darwin-arm64", "linux-x86_64"
    lib_name: []const u8, // e.g., "libgranville_llama.dylib"
};

/// Registry entry for a driver
pub const RegistryEntry = struct {
    name: []const u8,
    description: []const u8,
    repo: []const u8,
    official: bool,
    platforms: []const []const u8,
    latest_version: []const u8,
};

/// The interface that all drivers must export
/// These are the C function signatures that drivers implement
pub const DriverVTable = extern struct {
    /// Initialize the driver, returns opaque driver context
    init: *const fn () callconv(.c) ?*anyopaque,

    /// Cleanup driver resources
    deinit: *const fn (?*anyopaque) callconv(.c) void,

    /// Load a model from path, returns opaque model handle
    load_model: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque,

    /// Unload a model
    unload_model: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,

    /// Generate text from prompt
    /// Returns pointer to null-terminated string (caller must free with free_string)
    generate: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8, u32) callconv(.c) [*:0]const u8,

    /// Free a string returned by generate
    free_string: *const fn ([*:0]const u8) callconv(.c) void,

    /// Get driver name
    get_name: *const fn () callconv(.c) [*:0]const u8,

    /// Get driver version
    get_version: *const fn () callconv(.c) [*:0]const u8,
};

/// Loaded driver instance
pub const Driver = struct {
    dynlib: std.DynLib, // cross-platform dynamic library handle
    vtable: *const DriverVTable,
    context: ?*anyopaque,
    name: []const u8,

    pub fn loadModel(self: *Driver, path: []const u8) !*anyopaque {
        // Need null-terminated string for C
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) return error.PathTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        const model = self.vtable.load_model(self.context, path_buf[0..path.len :0]);
        if (model == null) return error.ModelLoadFailed;
        return model.?;
    }

    pub fn unloadModel(self: *Driver, model: *anyopaque) void {
        self.vtable.unload_model(self.context, model);
    }

    pub fn generate(self: *Driver, model: *anyopaque, prompt: []const u8, max_tokens: u32) ![]const u8 {
        var prompt_buf: [32768]u8 = undefined;
        if (prompt.len >= prompt_buf.len) return error.PromptTooLong;
        @memcpy(prompt_buf[0..prompt.len], prompt);
        prompt_buf[prompt.len] = 0;

        const result = self.vtable.generate(self.context, model, prompt_buf[0..prompt.len :0], max_tokens);
        // Return as slice (caller should copy if needed, then call freeString)
        return std.mem.span(result);
    }

    pub fn freeString(self: *Driver, str: []const u8) void {
        self.vtable.free_string(@ptrCast(str.ptr));
    }

    pub fn deinit(self: *Driver) void {
        self.vtable.deinit(self.context);
        // Close dynamic library handle
        self.dynlib.close();
    }
};

// ============================================================================
// DRIVER MANAGER
// ============================================================================

pub const DriverManager = struct {
    allocator: std.mem.Allocator,
    drivers_path: []const u8,

    pub fn init(allocator: std.mem.Allocator) !DriverManager {
        const home = try getHomeDir(allocator);
        defer allocator.free(home);
        const drivers_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, DRIVERS_DIR });

        // Ensure drivers directory exists
        std.fs.makeDirAbsolute(drivers_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                // Try creating parent .granville first
                const granville_path = try std.fmt.allocPrint(allocator, "{s}/.granville", .{home});
                defer allocator.free(granville_path);
                std.fs.makeDirAbsolute(granville_path) catch {};
                std.fs.makeDirAbsolute(drivers_path) catch {};
            },
        };

        return DriverManager{
            .allocator = allocator,
            .drivers_path = drivers_path,
        };
    }

    pub fn deinit(self: *DriverManager) void {
        self.allocator.free(self.drivers_path);
    }

    /// List installed drivers
    pub fn listInstalled(self: *DriverManager) ![]DriverManifest {
        var drivers: std.ArrayListUnmanaged(DriverManifest) = .empty;

        var dir = std.fs.openDirAbsolute(self.drivers_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return try drivers.toOwnedSlice(self.allocator);
            return err;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .directory) {
                // Try to read driver.json from this directory
                if (self.readManifest(entry.name)) |manifest| {
                    try drivers.append(self.allocator, manifest);
                } else |_| {
                    // Skip directories without valid manifest
                }
            }
        }

        return try drivers.toOwnedSlice(self.allocator);
    }

    fn readManifest(self: *DriverManager, driver_name: []const u8) !DriverManifest {
        const manifest_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/driver.json",
            .{ self.drivers_path, driver_name },
        );
        defer self.allocator.free(manifest_path);

        const file = try std.fs.openFileAbsolute(manifest_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        const parsed = try std.json.parseFromSlice(DriverManifest, self.allocator, content, .{});
        defer parsed.deinit();

        // Copy strings since they reference the content buffer which will be freed
        return DriverManifest{
            .name = try self.allocator.dupe(u8, parsed.value.name),
            .version = try self.allocator.dupe(u8, parsed.value.version),
            .description = try self.allocator.dupe(u8, parsed.value.description),
            .platform = try self.allocator.dupe(u8, parsed.value.platform),
            .lib_name = try self.allocator.dupe(u8, parsed.value.lib_name),
        };
    }

    /// Load a driver by name
    pub fn load(self: *DriverManager, name: []const u8) !Driver {
        // Determine library extension and prefix based on OS
        const lib_ext = switch (builtin.os.tag) {
            .macos => ".dylib",
            .linux => ".so",
            .windows => ".dll",
            else => return error.UnsupportedPlatform,
        };
        const lib_prefix = if (builtin.os.tag == .windows) "" else "lib";

        // Driver name like "granville-llama" -> lib name "libgranville_llama" (Unix) or "granville_llama" (Windows)
        // Replace hyphens with underscores for the library name
        var lib_name_buf: [256]u8 = undefined;
        var lib_name_len: usize = 0;
        for (name) |ch| {
            if (lib_name_len >= lib_name_buf.len) break;
            lib_name_buf[lib_name_len] = if (ch == '-') '_' else ch;
            lib_name_len += 1;
        }
        const lib_name = lib_name_buf[0..lib_name_len];

        const lib_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/{s}{s}{s}",
            .{ self.drivers_path, name, lib_prefix, lib_name, lib_ext },
        );
        defer self.allocator.free(lib_path);

        // Load the shared library using std.DynLib (cross-platform)
        var dynlib = std.DynLib.open(lib_path) catch |err| {
            std.debug.print("Failed to load driver '{s}': {}\n", .{ lib_path, err });
            return error.DriverLoadFailed;
        };
        errdefer dynlib.close();

        // Get the vtable symbol
        const vtable_ptr = dynlib.lookup(*const DriverVTable, "granville_driver_vtable") orelse {
            std.debug.print("Driver missing granville_driver_vtable symbol\n", .{});
            return error.InvalidDriver;
        };

        // Initialize the driver
        const context = vtable_ptr.init();

        return Driver{
            .dynlib = dynlib,
            .vtable = vtable_ptr,
            .context = context,
            .name = std.mem.span(vtable_ptr.get_name()),
        };
    }

    /// Install a driver from the registry
    pub fn install(self: *DriverManager, name: []const u8) !void {
        std.debug.print("Fetching registry...\n", .{});

        // For now, construct the download URL directly
        // In production, we'd fetch registry.json first
        const platform = getPlatformString();
        const download_url = try std.fmt.allocPrint(
            self.allocator,
            "https://github.com/rjpruitt16/{s}/releases/latest/download/{s}-{s}.tar.gz",
            .{ name, name, platform },
        );
        defer self.allocator.free(download_url);

        std.debug.print("Downloading {s}...\n", .{download_url});
        std.debug.print("Platform: {s}\n", .{platform});

        // Create driver directory
        const driver_dir = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ self.drivers_path, name },
        );
        defer self.allocator.free(driver_dir);

        std.fs.makeDirAbsolute(driver_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                std.debug.print("Driver already installed. Use 'granville driver update {s}' to update.\n", .{name});
                return error.AlreadyInstalled;
            },
            else => return err,
        };
        errdefer std.fs.deleteTreeAbsolute(driver_dir) catch {};

        // Download the tarball
        const tarball_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}.tar.gz",
            .{ driver_dir, name },
        );
        defer self.allocator.free(tarball_path);

        try downloadFile(self.allocator, download_url, tarball_path);
        defer std.fs.deleteFileAbsolute(tarball_path) catch {};

        // Extract the tarball
        std.debug.print("Extracting...\n", .{});
        try extractTarGz(self.allocator, tarball_path, driver_dir);

        std.debug.print("Driver '{s}' installed successfully.\n", .{name});
    }

    /// Download a file from URL to path
    fn downloadFile(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8) !void {
        const uri = std.Uri.parse(url) catch {
            std.debug.print("Error: Invalid URL format\n", .{});
            return error.InvalidUrl;
        };

        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        // Create an allocating writer to collect the response
        var response_writer = std.Io.Writer.Allocating.init(allocator);
        defer response_writer.deinit();

        const result = client.fetch(.{
            .location = .{ .uri = uri },
            .method = .GET,
            .response_writer = &response_writer.writer,
        }) catch |err| {
            std.debug.print("Error downloading: {}\n", .{err});
            return error.DownloadFailed;
        };

        if (result.status != .ok) {
            std.debug.print("Error: HTTP {d}\n", .{@intFromEnum(result.status)});
            return error.DownloadFailed;
        }

        // Get the downloaded data
        const data = response_writer.writer.buffered();

        // Write to file
        var file = try std.fs.createFileAbsolute(dest_path, .{});
        defer file.close();
        try file.writeAll(data);

        const size_mb = @as(f64, @floatFromInt(data.len)) / (1024 * 1024);
        std.debug.print("Downloaded {d:.2} MB\n", .{size_mb});
    }

    /// Extract a .tar.gz file to a directory
    fn extractTarGz(allocator: std.mem.Allocator, tarball_path: []const u8, dest_dir: []const u8) !void {
        // Use system tar command for simplicity
        var child = std.process.Child.init(
            &.{ "tar", "-xzf", tarball_path, "-C", dest_dir, "--strip-components=1" },
            allocator,
        );
        child.cwd = null;

        const result = try child.spawnAndWait();
        if (result.Exited != 0) {
            std.debug.print("tar extraction failed with exit code: {d}\n", .{result.Exited});
            return error.ExtractionFailed;
        }
    }

    /// Remove an installed driver
    pub fn remove(self: *DriverManager, name: []const u8) !void {
        const driver_dir = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ self.drivers_path, name },
        );
        defer self.allocator.free(driver_dir);

        std.fs.deleteTreeAbsolute(driver_dir) catch |err| {
            if (err == error.FileNotFound) {
                std.debug.print("Driver '{s}' is not installed.\n", .{name});
                return error.NotInstalled;
            }
            return err;
        };

        std.debug.print("Driver '{s}' removed.\n", .{name});
    }
};

fn getPlatformString() []const u8 {
    const os = @import("builtin").os.tag;
    const arch = @import("builtin").cpu.arch;

    return switch (os) {
        .macos => switch (arch) {
            .aarch64 => "darwin-arm64",
            .x86_64 => "darwin-x86_64",
            else => "unknown",
        },
        .linux => switch (arch) {
            .aarch64 => "linux-arm64",
            .x86_64 => "linux-x86_64",
            else => "unknown",
        },
        .windows => "windows-x86_64",
        else => "unknown",
    };
}

// ============================================================================
// TESTS
// ============================================================================

test "platform string detection" {
    const platform = getPlatformString();
    try std.testing.expect(platform.len > 0);
    try std.testing.expect(!std.mem.eql(u8, platform, "unknown"));
}

test "driver manager init" {
    const allocator = std.testing.allocator;
    var manager = try DriverManager.init(allocator);
    defer manager.deinit();

    try std.testing.expect(std.mem.endsWith(u8, manager.drivers_path, ".granville/drivers"));
}
