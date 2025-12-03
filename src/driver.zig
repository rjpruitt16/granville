const std = @import("std");

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
    handle: *anyopaque, // dlopen handle
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
        // Close dlopen handle
        const handle: *anyopaque = self.handle;
        _ = std.c.dlclose(handle);
    }
};

// ============================================================================
// DRIVER MANAGER
// ============================================================================

pub const DriverManager = struct {
    allocator: std.mem.Allocator,
    drivers_path: []const u8,

    pub fn init(allocator: std.mem.Allocator) !DriverManager {
        const home = std.posix.getenv("HOME") orelse "/tmp";
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
        // Determine library extension based on OS
        const lib_ext = switch (@import("builtin").os.tag) {
            .macos => ".dylib",
            .linux => ".so",
            .windows => ".dll",
            else => return error.UnsupportedPlatform,
        };

        // Driver name like "granville-llama" -> lib name "libgranville_llama"
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
            "{s}/{s}/lib{s}{s}",
            .{ self.drivers_path, name, lib_name, lib_ext },
        );
        defer self.allocator.free(lib_path);

        // Convert to null-terminated for dlopen
        var path_buf: [4096]u8 = undefined;
        @memcpy(path_buf[0..lib_path.len], lib_path);
        path_buf[lib_path.len] = 0;

        // Load the shared library
        const handle = std.c.dlopen(path_buf[0..lib_path.len :0], .{ .LAZY = true }) orelse {
            std.debug.print("Failed to load driver: {s}\n", .{std.c.dlerror() orelse "unknown error"});
            return error.DriverLoadFailed;
        };

        // Get the vtable symbol
        const vtable_ptr = std.c.dlsym(handle, "granville_driver_vtable") orelse {
            _ = std.c.dlclose(handle);
            return error.InvalidDriver;
        };

        const vtable: *const DriverVTable = @ptrCast(@alignCast(vtable_ptr));

        // Initialize the driver
        const context = vtable.init();

        return Driver{
            .handle = handle,
            .vtable = vtable,
            .context = context,
            .name = std.mem.span(vtable.get_name()),
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

        // TODO: Actually download and extract the tarball
        // For now, print instructions
        std.debug.print("\nDriver directory created: {s}\n", .{driver_dir});
        std.debug.print("\nTo complete installation manually:\n", .{});
        std.debug.print("  1. Download: {s}\n", .{download_url});
        std.debug.print("  2. Extract to: {s}\n", .{driver_dir});
        std.debug.print("\nAutomatic download coming soon!\n", .{});
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
