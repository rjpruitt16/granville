const std = @import("std");
const builtin = @import("builtin");

const MODELS_DIR = ".granville/models";

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

pub fn downloadModel(allocator: std.mem.Allocator, url: []const u8) !void {
    std.debug.print("Downloading model from: {s}\n", .{url});

    // Extract filename from URL
    const filename = extractFilename(url) orelse "model.gguf";
    std.debug.print("Filename: {s}\n", .{filename});

    // Ensure models directory exists
    const home = try getHomeDir(allocator);
    defer allocator.free(home);
    const models_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, MODELS_DIR });
    defer allocator.free(models_path);

    // Create parent directories if needed
    std.fs.makeDirAbsolute(models_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            // Try creating parent .granville first
            const granville_path = try std.fmt.allocPrint(allocator, "{s}/.granville", .{home});
            defer allocator.free(granville_path);
            std.fs.makeDirAbsolute(granville_path) catch {};
            std.fs.makeDirAbsolute(models_path) catch {};
        },
    };

    // Full path for the downloaded file
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ models_path, filename });
    defer allocator.free(file_path);

    std.debug.print("Saving to: {s}\n", .{file_path});

    // Parse URL
    const uri = std.Uri.parse(url) catch {
        std.debug.print("Error: Invalid URL format\n", .{});
        return error.InvalidUrl;
    };

    // Create HTTP client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Create an allocating writer to collect the response
    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();

    // Make request
    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .response_writer = &response_writer.writer,
    }) catch |err| {
        std.debug.print("Error fetching: {}\n", .{err});
        return error.HttpError;
    };

    // Check response status
    if (result.status != .ok) {
        std.debug.print("Error: HTTP {d}\n", .{@intFromEnum(result.status)});
        return error.HttpError;
    }

    // Get the downloaded data
    const data = response_writer.writer.buffered();

    // Write to file
    var file = try std.fs.createFileAbsolute(file_path, .{});
    defer file.close();
    try file.writeAll(data);

    const size_mb = @as(f64, @floatFromInt(data.len)) / (1024 * 1024);
    std.debug.print("Downloaded {d:.2} MB\n", .{size_mb});
    std.debug.print("Download complete: {s}\n", .{file_path});
}

pub fn getModelsDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = try getHomeDir(allocator);
    defer allocator.free(home);
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, MODELS_DIR });
}

pub fn extractFilename(url: []const u8) ?[]const u8 {
    // Find the last '/' in the URL
    var last_slash: usize = 0;
    for (url, 0..) |c, i| {
        if (c == '/') {
            last_slash = i;
        }
    }

    if (last_slash > 0 and last_slash < url.len - 1) {
        const filename = url[last_slash + 1 ..];
        // Remove query string if present
        for (filename, 0..) |c, i| {
            if (c == '?') {
                return filename[0..i];
            }
        }
        return filename;
    }
    return null;
}

// ============================================================================
// TESTS - No network calls, pure unit tests
// ============================================================================

test "extract filename from huggingface URL" {
    const url = "https://huggingface.co/TheBloke/Llama-2-7B-GGUF/resolve/main/llama-2-7b.Q4_K_M.gguf";
    try std.testing.expectEqualStrings("llama-2-7b.Q4_K_M.gguf", extractFilename(url).?);
}

test "extract filename with query string" {
    const url = "https://example.com/model.gguf?token=abc123&expires=999";
    try std.testing.expectEqualStrings("model.gguf", extractFilename(url).?);
}

test "extract filename returns null for trailing slash" {
    const url = "https://example.com/";
    try std.testing.expect(extractFilename(url) == null);
}

test "extract filename from simple URL" {
    const url = "https://example.com/my-model.gguf";
    try std.testing.expectEqualStrings("my-model.gguf", extractFilename(url).?);
}

test "models directory path construction" {
    const allocator = std.testing.allocator;
    const models_path = try getModelsDir(allocator);
    defer allocator.free(models_path);

    // Should end with .granville/models
    try std.testing.expect(std.mem.endsWith(u8, models_path, ".granville/models"));
}
