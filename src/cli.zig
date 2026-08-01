const std = @import("std");
const download = @import("download.zig");
const server = @import("server.zig");
const driver = @import("driver.zig");
const model_pool = @import("model_pool.zig");
const manifest_yaml = @import("manifest_yaml.zig");

const VERSION = "0.3.0"; // Manifest support

pub const Command = enum {
    download,
    serve,
    up,
    down,
    pull,
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
    // Manifest options
    manifest_path: []const u8 = "manifest.yaml",
    // Logging options
    verbose: bool = false, // Log full prompts and responses

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
        .up => {
            try runUp(allocator, config.manifest_path);
        },
        .down => {
            try runDown(allocator);
        },
        .pull => {
            try runPull(allocator, config.manifest_path);
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
                } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-V")) {
                    config.verbose = true;
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
        } else if (std.mem.eql(u8, cmd, "up")) {
            config.command = .up;
            // Optional manifest path
            if (args.next()) |path| {
                if (!std.mem.startsWith(u8, path, "-")) {
                    config.manifest_path = path;
                }
            }
        } else if (std.mem.eql(u8, cmd, "down")) {
            config.command = .down;
        } else if (std.mem.eql(u8, cmd, "pull")) {
            config.command = .pull;
            // Optional manifest path
            if (args.next()) |path| {
                if (!std.mem.startsWith(u8, path, "-")) {
                    config.manifest_path = path;
                }
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
        \\    up [manifest.yaml]     Start server from manifest (default: manifest.yaml)
        \\    down                   Stop the running server
        \\    pull [manifest.yaml]   Download models defined in manifest
        \\    serve <models...>      Start the inference server with one or more models
        \\    download <url>         Download a GGUF model from Hugging Face
        \\    driver <subcommand>    Manage inference drivers
        \\    help                   Show this help message
        \\    version                Show version information
        \\
        \\MANIFEST COMMANDS:
        \\    up                     Load manifest.yaml, download models, start server
        \\    down                   Stop server and cleanup socket
        \\    pull                   Download models without starting server
        \\
        \\SERVE OPTIONS:
        \\    <models...>            One or more model specs (see MODEL SPEC FORMAT below)
        \\    -p, --port <port>      Port for HTTP status endpoint (default: 8080)
        \\    -s, --socket <path>    Unix socket path (default: /tmp/granville.sock)
        \\    -q, --queue-size <n>   Maximum queue size (default: 1000)
        \\    -w, --workers <n>      Number of worker threads (default: min(num_models, 8))
        \\    -d, --driver <name>    Inference driver to use (default: granville-llama)
        \\    -V, --verbose          Log full prompts and responses to stderr
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
        \\    granville up                                    # Start from manifest.yaml
        \\    granville up my-config.yaml                     # Start from custom manifest
        \\    granville pull                                  # Download models only
        \\    granville down                                  # Stop server
        \\    granville serve model.gguf                      # Direct serve
        \\    granville driver install granville-llama        # Install driver
        \\
    ;
    std.debug.print("{s}", .{usage});
}

/// Start server from manifest.yaml
fn runUp(allocator: std.mem.Allocator, manifest_path: []const u8) !void {
    std.debug.print("\n[1/4] Loading manifest: {s}\n", .{manifest_path});

    var manifest = manifest_yaml.loadFromFile(allocator, manifest_path) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Error: {s} not found\n", .{manifest_path});
            std.debug.print("Create a manifest.yaml or specify a path: granville up <path>\n", .{});
            return err;
        }
        return err;
    };
    defer manifest.deinit(allocator);

    std.debug.print("  Name: {s} v{s}\n", .{ manifest.name, manifest.version });
    std.debug.print("  Models: {d}\n", .{manifest.models.count()});

    // Check/download models
    std.debug.print("\n[2/4] Checking models...\n", .{});
    var model_specs = std.ArrayList(model_pool.ModelSpec).empty;
    defer model_specs.deinit(allocator);

    var it = manifest.models.iterator();
    while (it.next()) |entry| {
        const model_name = entry.key_ptr.*;
        const model_config = entry.value_ptr.*;

        const local_path = try manifest_yaml.resolveModelPath(allocator, model_config.source);

        if (std.fs.cwd().access(local_path, .{})) {
            std.debug.print("  ✓ {s}: exists\n", .{model_name});
        } else |_| {
            if (std.mem.startsWith(u8, model_config.source, "huggingface://")) {
                std.debug.print("  ↓ {s}: downloading...\n", .{model_name});
                const url = try manifest_yaml.huggingfaceToUrl(allocator, model_config.source);
                defer allocator.free(url);
                try download.downloadModel(allocator, url);
                std.debug.print("  ✓ {s}: downloaded\n", .{model_name});
            } else {
                std.debug.print("  ✗ {s}: not found\n", .{model_name});
                return error.ModelNotFound;
            }
        }

        try model_specs.append(allocator, .{
            .path = local_path,
            .model_type = model_config.model_type,
            .id = null,
        });
    }

    // Install driver
    std.debug.print("\n[3/4] Checking driver...\n", .{});
    var driver_manager = try driver.DriverManager.init(allocator);
    defer driver_manager.deinit();
    driver_manager.install(manifest.driver_name) catch |err| {
        if (err != error.AlreadyInstalled) return err;
    };
    std.debug.print("  ✓ {s}\n", .{manifest.driver_name});

    // Start server
    std.debug.print("\n[4/4] Starting server...\n", .{});
    std.debug.print("  Socket: {s}\n", .{manifest.server_config.socket_path});
    std.debug.print("  Port: {d}\n", .{manifest.server_config.port});

    var cli_config = Config.init(allocator);
    cli_config.command = .serve;
    cli_config.model_specs = model_specs;
    cli_config.socket_path = manifest.server_config.socket_path;
    cli_config.port = manifest.server_config.port;
    cli_config.queue_size = manifest.server_config.queue_size;
    cli_config.num_workers = manifest.server_config.workers;
    cli_config.driver_backend = manifest.driver_name;

    std.debug.print("\nServer ready. Waiting for connections...\n\n", .{});
    try server.start(allocator, cli_config);
}

/// Stop running server
fn runDown(_: std.mem.Allocator) !void {
    const socket_path = "/tmp/granville.sock";

    std.debug.print("Stopping Granville server...\n", .{});

    // Remove socket file
    std.fs.cwd().deleteFile(socket_path) catch |err| {
        if (err != error.FileNotFound) {
            std.debug.print("Warning: Could not remove socket: {s}\n", .{socket_path});
        }
    };

    // Note: In a full implementation, we'd send a shutdown signal
    // For now, removing the socket is the cleanup step
    std.debug.print("  ✓ Socket removed: {s}\n", .{socket_path});
    std.debug.print("\nTo fully stop, also kill the granville process:\n", .{});
    std.debug.print("  pkill -f 'granville serve'\n", .{});
}

/// Download models from manifest without starting server
fn runPull(allocator: std.mem.Allocator, manifest_path: []const u8) !void {
    std.debug.print("Pulling models from: {s}\n\n", .{manifest_path});

    var manifest = manifest_yaml.loadFromFile(allocator, manifest_path) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Error: {s} not found\n", .{manifest_path});
            return err;
        }
        return err;
    };
    defer manifest.deinit(allocator);

    var it = manifest.models.iterator();
    while (it.next()) |entry| {
        const model_name = entry.key_ptr.*;
        const model_config = entry.value_ptr.*;

        const local_path = try manifest_yaml.resolveModelPath(allocator, model_config.source);

        if (std.fs.cwd().access(local_path, .{})) {
            std.debug.print("✓ {s}: already downloaded\n", .{model_name});
        } else |_| {
            if (std.mem.startsWith(u8, model_config.source, "huggingface://")) {
                std.debug.print("↓ {s}: downloading...\n", .{model_name});
                const url = try manifest_yaml.huggingfaceToUrl(allocator, model_config.source);
                defer allocator.free(url);
                try download.downloadModel(allocator, url);
                std.debug.print("✓ {s}: downloaded\n", .{model_name});
            } else {
                std.debug.print("✗ {s}: not found at {s}\n", .{ model_name, local_path });
            }
        }
    }

    std.debug.print("\nDone.\n", .{});
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
