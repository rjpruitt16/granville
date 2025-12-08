const std = @import("std");
const download = @import("download.zig");
const server = @import("server.zig");
const driver = @import("driver.zig");
const model_pool = @import("model_pool.zig");

const VERSION = "0.2.0"; // Multi-model support

pub const Command = enum {
    download,
    serve,
    driver_install,
    driver_list,
    driver_remove,
    help,
    version,
};

pub const Config = struct {
    command: Command,
    allocator: std.mem.Allocator,
    // Download options
    url: ?[]const u8 = null,
    // Serve options
    model_specs: std.ArrayList(model_pool.ModelSpec),
    port: u16 = 8080,
    socket_path: []const u8 = "/tmp/granville.sock",
    queue_size: usize = 1000,
    num_workers: ?usize = null, // null = auto (min of num_models, 8)
    driver_name: ?[]const u8 = null,
    // Driver options
    driver_backend: []const u8 = "granville-llama",

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .command = .help,
            .allocator = allocator,
            .model_specs = .empty,
        };
    }

    pub fn deinit(self: *Config) void {
        self.model_specs.deinit(self.allocator);
    }
};

pub fn run(allocator: std.mem.Allocator) !void {
    var config = try parseArgs(allocator);
    defer config.deinit();

    switch (config.command) {
        .download => {
            if (config.url) |url| {
                try download.downloadModel(allocator, url);
            } else {
                std.debug.print("Error: URL required for download command\n", .{});
                printUsage();
                return error.MissingArgument;
            }
        },
        .serve => {
            if (config.model_specs.items.len > 0) {
                try server.start(allocator, config);
            } else {
                std.debug.print("Error: At least one model required for serve command\n", .{});
                printUsage();
                return error.MissingArgument;
            }
        },
        .driver_install => {
            if (config.driver_name) |name| {
                var manager = try driver.DriverManager.init(allocator);
                defer manager.deinit();
                manager.install(name) catch |err| {
                    if (err != error.AlreadyInstalled) return err;
                };
            } else {
                std.debug.print("Error: Driver name required\n", .{});
                std.debug.print("Usage: granville driver install <driver-name>\n", .{});
                return error.MissingArgument;
            }
        },
        .driver_list => {
            var manager = try driver.DriverManager.init(allocator);
            defer manager.deinit();
            const drivers = try manager.listInstalled();

            if (drivers.len == 0) {
                std.debug.print("No drivers installed.\n", .{});
                std.debug.print("\nInstall a driver with:\n", .{});
                std.debug.print("  granville driver install granville-llama\n", .{});
            } else {
                std.debug.print("Installed drivers:\n\n", .{});
                for (drivers) |d| {
                    std.debug.print("  {s} v{s}\n", .{ d.name, d.version });
                    std.debug.print("    {s}\n\n", .{d.description});
                }
            }
        },
        .driver_remove => {
            if (config.driver_name) |name| {
                var manager = try driver.DriverManager.init(allocator);
                defer manager.deinit();
                manager.remove(name) catch |err| {
                    if (err != error.NotInstalled) return err;
                };
            } else {
                std.debug.print("Error: Driver name required\n", .{});
                std.debug.print("Usage: granville driver remove <driver-name>\n", .{});
                return error.MissingArgument;
            }
        },
        .help => printUsage(),
        .version => printVersion(),
    }
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    // Use argsWithAllocator for Windows compatibility
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip(); // Skip program name

    var config = Config.init(allocator);

    // Parse command
    if (args.next()) |cmd| {
        if (std.mem.eql(u8, cmd, "download")) {
            config.command = .download;
            // Get URL argument
            if (args.next()) |url| {
                config.url = url;
            }
        } else if (std.mem.eql(u8, cmd, "serve")) {
            config.command = .serve;
            // Parse serve arguments
            while (args.next()) |arg| {
                if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
                    if (args.next()) |port_str| {
                        config.port = std.fmt.parseInt(u16, port_str, 10) catch 8080;
                    }
                } else if (std.mem.eql(u8, arg, "--socket") or std.mem.eql(u8, arg, "-s")) {
                    if (args.next()) |socket_path| {
                        config.socket_path = socket_path;
                    }
                } else if (std.mem.eql(u8, arg, "--queue-size") or std.mem.eql(u8, arg, "-q")) {
                    if (args.next()) |size_str| {
                        config.queue_size = std.fmt.parseInt(usize, size_str, 10) catch 1000;
                    }
                } else if (std.mem.eql(u8, arg, "--driver") or std.mem.eql(u8, arg, "-d")) {
                    if (args.next()) |driver_name| {
                        config.driver_backend = driver_name;
                    }
                } else if (std.mem.eql(u8, arg, "--workers") or std.mem.eql(u8, arg, "-w")) {
                    if (args.next()) |workers_str| {
                        config.num_workers = std.fmt.parseInt(usize, workers_str, 10) catch null;
                    }
                } else if (!std.mem.startsWith(u8, arg, "-")) {
                    // It's a model spec (path or type:id:path format)
                    try config.model_specs.append(allocator, model_pool.ModelSpec.parse(arg));
                }
            }
        } else if (std.mem.eql(u8, cmd, "driver")) {
            // Parse driver subcommand
            if (args.next()) |subcmd| {
                if (std.mem.eql(u8, subcmd, "install")) {
                    config.command = .driver_install;
                    if (args.next()) |name| {
                        config.driver_name = name;
                    }
                } else if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
                    config.command = .driver_list;
                } else if (std.mem.eql(u8, subcmd, "remove") or std.mem.eql(u8, subcmd, "rm")) {
                    config.command = .driver_remove;
                    if (args.next()) |name| {
                        config.driver_name = name;
                    }
                } else {
                    std.debug.print("Unknown driver command: {s}\n", .{subcmd});
                    std.debug.print("Available: install, list, remove\n\n", .{});
                    config.command = .help;
                }
            } else {
                config.command = .driver_list;
            }
        } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
            config.command = .help;
        } else if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
            config.command = .version;
        } else {
            std.debug.print("Unknown command: {s}\n\n", .{cmd});
            config.command = .help;
        }
    }

    return config;
}

fn printUsage() void {
    const usage =
        \\Granville - Local CPU Model Inference Kernel
        \\
        \\USAGE:
        \\    granville <command> [options]
        \\
        \\COMMANDS:
        \\    download <url>         Download a GGUF model from Hugging Face
        \\    serve <models...>      Start the inference server with one or more models
        \\    driver <subcommand>    Manage inference drivers
        \\    help                   Show this help message
        \\    version                Show version information
        \\
        \\DOWNLOAD OPTIONS:
        \\    <url>                  Hugging Face URL to GGUF model file
        \\
        \\SERVE OPTIONS:
        \\    <models...>            One or more model specs (see MODEL SPEC FORMAT below)
        \\    -p, --port <port>      Port for HTTP status endpoint (default: 8080)
        \\    -s, --socket <path>    Unix socket path (default: /tmp/granville.sock)
        \\    -q, --queue-size <n>   Maximum queue size (default: 1000)
        \\    -w, --workers <n>      Number of worker threads (default: min(num_models, 8))
        \\    -d, --driver <name>    Inference driver to use (default: granville-llama)
        \\
        \\MODEL SPEC FORMAT:
        \\    path.gguf              Simple path (type=unassigned, id=auto)
        \\    type:path.gguf         With type (inference, stt, tts, embedding)
        \\    type:id:path.gguf      With type and explicit ID
        \\
        \\DRIVER SUBCOMMANDS:
        \\    driver install <name>  Install a driver from the registry
        \\    driver list            List installed drivers
        \\    driver remove <name>   Remove an installed driver
        \\
        \\EXAMPLES:
        \\    granville download https://huggingface.co/TheBloke/Llama-2-7B-GGUF/resolve/main/llama-2-7b.Q4_K_M.gguf
        \\    granville driver install granville-llama
        \\    granville serve model.gguf
        \\    granville serve model1.gguf model2.gguf model3.gguf
        \\    granville serve inference:main:llama.gguf stt:whisper:whisper.gguf
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn printVersion() void {
    std.debug.print("granville {s}\n", .{VERSION});
}

test "config init and deinit" {
    var config = Config.init(std.testing.allocator);
    defer config.deinit();
    try std.testing.expectEqual(Command.help, config.command);
    try std.testing.expectEqual(@as(usize, 0), config.model_specs.items.len);
}

test "config default values" {
    var config = Config.init(std.testing.allocator);
    defer config.deinit();
    try std.testing.expectEqual(@as(u16, 8080), config.port);
    try std.testing.expectEqual(@as(usize, 1000), config.queue_size);
    try std.testing.expectEqualStrings("/tmp/granville.sock", config.socket_path);
}

test "config with model specs" {
    var config = Config.init(std.testing.allocator);
    defer config.deinit();
    config.command = .serve;

    try config.model_specs.append(std.testing.allocator, model_pool.ModelSpec.parse("model1.gguf"));
    try config.model_specs.append(std.testing.allocator, model_pool.ModelSpec.parse("inference:model2.gguf"));

    try std.testing.expectEqual(@as(usize, 2), config.model_specs.items.len);
    try std.testing.expectEqualStrings("model1.gguf", config.model_specs.items[0].path);
    try std.testing.expectEqual(model_pool.ModelType.inference, config.model_specs.items[1].model_type);
}
