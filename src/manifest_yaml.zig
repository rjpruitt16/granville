const std = @import("std");
const download = @import("download.zig");
const server = @import("server.zig");
const driver = @import("driver.zig");
const model_pool = @import("model_pool.zig");

/// Manifest configuration loaded from YAML
pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
    models: std.StringHashMap(ModelConfig),
    server_config: ServerConfig,
    driver_name: []const u8,

    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.driver_name);

        var it = self.models.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.models.deinit();
    }
};

pub const ModelConfig = struct {
    source: []const u8, // huggingface://... or local path
    model_type: model_pool.ModelType,
    gpu_layers: u32,
    context_size: u32,

    pub fn deinit(self: *ModelConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
    }
};

pub const ServerConfig = struct {
    socket_path: []const u8,
    port: u16,
    queue_size: usize,
    workers: ?usize,
};

/// Parse manifest.yaml into Manifest struct
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Manifest {
    var manifest = Manifest{
        .name = try allocator.dupe(u8, "unnamed"),
        .version = try allocator.dupe(u8, "0.0.0"),
        .models = std.StringHashMap(ModelConfig).init(allocator),
        .server_config = .{
            .socket_path = "/tmp/granville.sock",
            .port = 8080,
            .queue_size = 1000,
            .workers = null,
        },
        .driver_name = try allocator.dupe(u8, "granville-llama"),
    };

    var lines = std.mem.splitScalar(u8, content, '\n');
    var current_model: ?[]const u8 = null;
    var in_models = false;
    var in_server = false;

    // Temporary storage for current model being parsed
    var temp_source: ?[]const u8 = null;
    var temp_type: model_pool.ModelType = .inference;
    var temp_gpu_layers: u32 = 0;
    var temp_context_size: u32 = 4096;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Check indentation level
        const indent = countIndent(line);

        // Top-level keys (no indent)
        if (indent == 0) {
            // Save previous model if we were parsing one
            if (current_model != null and temp_source != null) {
                const model_name = try allocator.dupe(u8, current_model.?);
                try manifest.models.put(model_name, .{
                    .source = try allocator.dupe(u8, temp_source.?),
                    .model_type = temp_type,
                    .gpu_layers = temp_gpu_layers,
                    .context_size = temp_context_size,
                });
                current_model = null;
                temp_source = null;
                temp_type = .inference;
                temp_gpu_layers = 0;
                temp_context_size = 4096;
            }

            if (std.mem.startsWith(u8, trimmed, "name:")) {
                const val = getValue(trimmed);
                allocator.free(manifest.name);
                manifest.name = try allocator.dupe(u8, val);
                in_models = false;
                in_server = false;
            } else if (std.mem.startsWith(u8, trimmed, "version:")) {
                const val = getValue(trimmed);
                allocator.free(manifest.version);
                manifest.version = try allocator.dupe(u8, std.mem.trim(u8, val, "\""));
                in_models = false;
                in_server = false;
            } else if (std.mem.startsWith(u8, trimmed, "models:")) {
                in_models = true;
                in_server = false;
            } else if (std.mem.startsWith(u8, trimmed, "server:")) {
                in_models = false;
                in_server = true;
            } else if (std.mem.startsWith(u8, trimmed, "driver:")) {
                const val = getValue(trimmed);
                allocator.free(manifest.driver_name);
                manifest.driver_name = try allocator.dupe(u8, val);
                in_models = false;
                in_server = false;
            }
        } else if (indent == 2 and in_models) {
            // Save previous model
            if (current_model != null and temp_source != null) {
                const model_name = try allocator.dupe(u8, current_model.?);
                try manifest.models.put(model_name, .{
                    .source = try allocator.dupe(u8, temp_source.?),
                    .model_type = temp_type,
                    .gpu_layers = temp_gpu_layers,
                    .context_size = temp_context_size,
                });
                temp_source = null;
                temp_type = .inference;
                temp_gpu_layers = 0;
                temp_context_size = 4096;
            }

            // Model name (e.g., "main:", "ranker:")
            if (std.mem.endsWith(u8, trimmed, ":")) {
                current_model = trimmed[0 .. trimmed.len - 1];
            }
        } else if (indent == 4 and in_models and current_model != null) {
            // Model properties
            if (std.mem.startsWith(u8, trimmed, "source:")) {
                temp_source = getValue(trimmed);
            } else if (std.mem.startsWith(u8, trimmed, "type:")) {
                const val = getValue(trimmed);
                temp_type = parseModelType(val);
            } else if (std.mem.startsWith(u8, trimmed, "gpu_layers:")) {
                const val = getValue(trimmed);
                temp_gpu_layers = std.fmt.parseInt(u32, val, 10) catch 0;
            } else if (std.mem.startsWith(u8, trimmed, "context_size:")) {
                const val = getValue(trimmed);
                temp_context_size = std.fmt.parseInt(u32, val, 10) catch 4096;
            }
        } else if (indent == 2 and in_server) {
            // Server properties
            if (std.mem.startsWith(u8, trimmed, "socket:")) {
                manifest.server_config.socket_path = getValue(trimmed);
            } else if (std.mem.startsWith(u8, trimmed, "port:")) {
                const val = getValue(trimmed);
                manifest.server_config.port = std.fmt.parseInt(u16, val, 10) catch 8080;
            } else if (std.mem.startsWith(u8, trimmed, "queue_size:")) {
                const val = getValue(trimmed);
                manifest.server_config.queue_size = std.fmt.parseInt(usize, val, 10) catch 1000;
            } else if (std.mem.startsWith(u8, trimmed, "workers:")) {
                const val = getValue(trimmed);
                manifest.server_config.workers = std.fmt.parseInt(usize, val, 10) catch null;
            }
        }
    }

    // Save last model if pending
    if (current_model != null and temp_source != null) {
        const model_name = try allocator.dupe(u8, current_model.?);
        try manifest.models.put(model_name, .{
            .source = try allocator.dupe(u8, temp_source.?),
            .model_type = temp_type,
            .gpu_layers = temp_gpu_layers,
            .context_size = temp_context_size,
        });
    }

    return manifest;
}

/// Load manifest from file path
pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Manifest {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    return parse(allocator, content);
}

fn countIndent(line: []const u8) usize {
    var count: usize = 0;
    for (line) |c| {
        if (c == ' ') {
            count += 1;
        } else {
            break;
        }
    }
    return count;
}

fn getValue(line: []const u8) []const u8 {
    const colon_idx = std.mem.indexOf(u8, line, ":") orelse return "";
    if (colon_idx + 1 >= line.len) return "";
    return std.mem.trim(u8, line[colon_idx + 1 ..], " \t");
}

fn parseModelType(val: []const u8) model_pool.ModelType {
    if (std.mem.eql(u8, val, "inference")) return .inference;
    if (std.mem.eql(u8, val, "stt")) return .stt;
    if (std.mem.eql(u8, val, "tts")) return .tts;
    if (std.mem.eql(u8, val, "embedding")) return .embedding;
    return .unassigned;
}

/// Convert huggingface:// URL to local path
pub fn resolveModelPath(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, source, "huggingface://")) {
        const last_slash = std.mem.lastIndexOf(u8, source, "/") orelse return error.InvalidSource;
        const filename = source[last_slash + 1 ..];
        // std.posix.getenv doesn't work on Windows (env strings are WTF-16
        // there); getEnvVarOwned is the cross-platform equivalent.
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch try allocator.dupe(u8, "/tmp");
        defer allocator.free(home);
        return std.fmt.allocPrint(allocator, "{s}/.granville/models/{s}", .{ home, filename });
    }
    return allocator.dupe(u8, source);
}

/// Convert huggingface:// to https:// URL for downloading
pub fn huggingfaceToUrl(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    const prefix = "huggingface://";
    if (!std.mem.startsWith(u8, source, prefix)) return error.InvalidSource;

    const path = source[prefix.len..];
    const last_slash = std.mem.lastIndexOf(u8, path, "/") orelse return error.InvalidSource;
    const repo = path[0..last_slash];
    const filename = path[last_slash + 1 ..];

    return std.fmt.allocPrint(
        allocator,
        "https://huggingface.co/{s}/resolve/main/{s}",
        .{ repo, filename },
    );
}

test "parse simple manifest" {
    const yaml =
        \\name: test-agent
        \\version: "1.0"
        \\
        \\models:
        \\  main:
        \\    source: huggingface://TheBloke/test/model.gguf
        \\    type: inference
        \\    gpu_layers: 35
        \\
        \\server:
        \\  socket: /tmp/test.sock
        \\  port: 9000
        \\
        \\driver: granville-llama
    ;

    var manifest = try parse(std.testing.allocator, yaml);
    defer manifest.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("test-agent", manifest.name);
    try std.testing.expectEqualStrings("1.0", manifest.version);
    try std.testing.expectEqual(@as(usize, 1), manifest.models.count());
    try std.testing.expectEqual(@as(u16, 9000), manifest.server_config.port);
}

test "huggingface url conversion" {
    const source = "huggingface://TheBloke/Llama-2-7B-Chat-GGUF/llama-2-7b-chat.Q4_K_M.gguf";
    const url = try huggingfaceToUrl(std.testing.allocator, source);
    defer std.testing.allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://huggingface.co/TheBloke/Llama-2-7B-Chat-GGUF/resolve/main/llama-2-7b-chat.Q4_K_M.gguf",
        url,
    );
}
