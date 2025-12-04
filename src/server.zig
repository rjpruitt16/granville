const std = @import("std");
const msgpack = @import("msgpack");
const cli = @import("cli.zig");
const scheduler = @import("scheduler.zig");
const protocol = @import("protocol.zig");
const driver_mod = @import("driver.zig");
const builtin = @import("builtin");

/// Platform-specific IPC abstraction
const ipc = switch (builtin.os.tag) {
    .windows => WindowsNamedPipe,
    else => UnixSocket,
};

/// Unix socket implementation (Linux, macOS, BSD)
const UnixSocket = struct {
    pub const Server = struct {
        inner: std.net.Server,

        pub fn deinit(self: *Server) void {
            self.inner.deinit();
        }

        pub fn accept(self: *Server) !Connection {
            const conn = try self.inner.accept();
            return Connection{ .stream = conn.stream };
        }
    };

    pub const Connection = struct {
        stream: std.net.Stream,

        pub fn read(self: *Connection, buf: []u8) !usize {
            return self.stream.read(buf);
        }

        pub fn write(self: *Connection, data: []const u8) !usize {
            return self.stream.write(data);
        }

        pub fn close(self: *Connection) void {
            self.stream.close();
        }
    };

    pub fn listen(path: []const u8) !Server {
        // Remove existing socket file
        std.fs.deleteFileAbsolute(path) catch {};

        const address = try std.net.Address.initUnix(path);
        const server = try address.listen(.{ .reuse_address = true });
        return Server{ .inner = server };
    }

    pub fn connect(path: []const u8) !Connection {
        const stream = try std.net.connectUnixSocket(path);
        return Connection{ .stream = stream };
    }

    pub fn defaultPath() []const u8 {
        return "/tmp/granville.sock";
    }
};

/// Windows Named Pipe implementation
const WindowsNamedPipe = struct {
    pub const Server = struct {
        pipe_path: []const u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Server) void {
            self.allocator.free(self.pipe_path);
        }

        pub fn accept(self: *Server) !Connection {
            // Windows named pipe accept - create instance and wait
            const handle = std.os.windows.kernel32.CreateNamedPipeA(
                self.pipe_path.ptr,
                std.os.windows.PIPE_ACCESS_DUPLEX,
                std.os.windows.PIPE_TYPE_BYTE | std.os.windows.PIPE_READMODE_BYTE | std.os.windows.PIPE_WAIT,
                std.os.windows.PIPE_UNLIMITED_INSTANCES,
                8192, // output buffer
                8192, // input buffer
                0, // default timeout
                null, // security attributes
            );

            if (handle == std.os.windows.INVALID_HANDLE_VALUE) {
                return error.CreatePipeFailed;
            }

            // Wait for client connection
            if (std.os.windows.kernel32.ConnectNamedPipe(handle, null) == 0) {
                const err = std.os.windows.kernel32.GetLastError();
                if (err != std.os.windows.ERROR_PIPE_CONNECTED) {
                    std.os.windows.kernel32.CloseHandle(handle);
                    return error.ConnectPipeFailed;
                }
            }

            return Connection{ .handle = handle };
        }
    };

    pub const Connection = struct {
        handle: std.os.windows.HANDLE,

        pub fn read(self: *Connection, buf: []u8) !usize {
            var bytes_read: std.os.windows.DWORD = 0;
            if (std.os.windows.kernel32.ReadFile(
                self.handle,
                buf.ptr,
                @intCast(buf.len),
                &bytes_read,
                null,
            ) == 0) {
                return error.ReadFailed;
            }
            return bytes_read;
        }

        pub fn write(self: *Connection, data: []const u8) !usize {
            var bytes_written: std.os.windows.DWORD = 0;
            if (std.os.windows.kernel32.WriteFile(
                self.handle,
                data.ptr,
                @intCast(data.len),
                &bytes_written,
                null,
            ) == 0) {
                return error.WriteFailed;
            }
            return bytes_written;
        }

        pub fn close(self: *Connection) void {
            _ = std.os.windows.kernel32.DisconnectNamedPipe(self.handle);
            std.os.windows.kernel32.CloseHandle(self.handle);
        }
    };

    pub fn listen(path: []const u8, allocator: std.mem.Allocator) !Server {
        // Convert to Windows named pipe path format
        const pipe_path = try std.fmt.allocPrintZ(allocator, "\\\\.\\pipe\\{s}", .{path});
        return Server{ .pipe_path = pipe_path, .allocator = allocator };
    }

    pub fn connect(path: []const u8) !Connection {
        var pipe_path_buf: [256]u8 = undefined;
        const pipe_path = std.fmt.bufPrintZ(&pipe_path_buf, "\\\\.\\pipe\\{s}", .{path}) catch {
            return error.PathTooLong;
        };

        const handle = std.os.windows.kernel32.CreateFileA(
            pipe_path.ptr,
            std.os.windows.GENERIC_READ | std.os.windows.GENERIC_WRITE,
            0,
            null,
            std.os.windows.OPEN_EXISTING,
            0,
            null,
        );

        if (handle == std.os.windows.INVALID_HANDLE_VALUE) {
            return error.ConnectFailed;
        }

        return Connection{ .handle = handle };
    }

    pub fn defaultPath() []const u8 {
        return "granville";
    }
};

/// Classification prompt for ranking requests with PII redaction
const RANK_PROMPT =
    \\Classify this task's urgency AND redact any PII (personally identifiable information).
    \\
    \\Reply in this exact format:
    \\PRIORITY: <CRITICAL|HIGH|NORMAL|LOW>
    \\REDACTED: <task with PII replaced>
    \\
    \\Priority levels:
    \\CRITICAL = System emergency, security issue, data loss risk
    \\HIGH = Time-sensitive, blocking other work, customer-facing issue
    \\NORMAL = Regular task, can wait a bit
    \\LOW = Background task, nice-to-have, no deadline
    \\
    \\PII to redact (replace with placeholders):
    \\- Email addresses -> [EMAIL]
    \\- Phone numbers -> [PHONE]
    \\- SSN/ID numbers -> [SSN]
    \\- Names of people -> [NAME]
    \\- Addresses -> [ADDRESS]
    \\- Credit card numbers -> [CARD]
    \\
    \\Task:
;

/// Server context holding loaded driver and model
const ServerContext = struct {
    allocator: std.mem.Allocator,
    driver: ?driver_mod.Driver,
    model: ?*anyopaque,
    model_path: []const u8,

    fn generate(self: *ServerContext, prompt: []const u8, max_tokens: u32) ![]const u8 {
        if (self.driver) |*drv| {
            if (self.model) |model| {
                return drv.generate(model, prompt, max_tokens);
            }
        }
        return error.ModelNotLoaded;
    }

    /// Rank a task by asking the model to classify its priority
    fn rankTask(self: *ServerContext, text: []const u8) scheduler.Priority {
        // Build classification prompt
        var prompt_buf: [4096]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buf, "{s}{s}", .{ RANK_PROMPT, text }) catch {
            return .normal; // Default on error
        };

        // Ask model to classify (short response)
        const response = self.generate(prompt, 10) catch {
            std.debug.print("[ranking] Model error, defaulting to normal\n", .{});
            return .normal;
        };
        defer self.freeString(response);

        // Parse response - look for priority keywords
        const upper = blk: {
            var buf: [64]u8 = undefined;
            const len = @min(response.len, buf.len);
            for (response[0..len], 0..) |c, i| {
                buf[i] = std.ascii.toUpper(c);
            }
            break :blk buf[0..len];
        };

        const priority = if (std.mem.indexOf(u8, upper, "CRITICAL") != null)
            scheduler.Priority.critical
        else if (std.mem.indexOf(u8, upper, "HIGH") != null)
            scheduler.Priority.high
        else if (std.mem.indexOf(u8, upper, "LOW") != null)
            scheduler.Priority.low
        else
            scheduler.Priority.normal;

        std.debug.print("[ranking] '{s}' -> {s} (response: {s})\n", .{
            text[0..@min(text.len, 50)],
            priority.toString(),
            response[0..@min(response.len, 30)],
        });

        return priority;
    }

    fn freeString(self: *ServerContext, str: []const u8) void {
        if (self.driver) |*drv| {
            drv.freeString(str);
        }
    }

    fn deinit(self: *ServerContext) void {
        if (self.driver) |*drv| {
            if (self.model) |model| {
                drv.unloadModel(model);
            }
            drv.deinit();
        }
    }
};

/// Unranked task - waiting to be classified
const UnrankedTask = struct {
    id: []const u8,
    text: []const u8,
    callback: []const u8,
};

/// Ranked task - ready for inference
const RankedTask = struct {
    id: []const u8,
    text: []const u8,
    callback: []const u8,
    priority: scheduler.Priority,
};

/// Thread-safe queue for unranked tasks (FIFO)
const UnrankedQueue = struct {
    items: std.ArrayListUnmanaged(UnrankedTask),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    fn init(allocator: std.mem.Allocator) UnrankedQueue {
        return .{
            .items = .{},
            .allocator = allocator,
            .mutex = .{},
        };
    }

    fn deinit(self: *UnrankedQueue) void {
        self.items.deinit(self.allocator);
    }

    fn push(self: *UnrankedQueue, task: UnrankedTask) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(self.allocator, task);
    }

    fn pop(self: *UnrankedQueue) ?UnrankedTask {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    fn len(self: *UnrankedQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.items.items.len;
    }
};

/// Thread-safe priority queue for ranked tasks
const RankedQueue = struct {
    items: std.ArrayListUnmanaged(RankedTask),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    fn init(allocator: std.mem.Allocator) RankedQueue {
        return .{
            .items = .{},
            .allocator = allocator,
            .mutex = .{},
        };
    }

    fn deinit(self: *RankedQueue) void {
        self.items.deinit(self.allocator);
    }

    fn push(self: *RankedQueue, task: RankedTask) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(self.allocator, task);
    }

    /// Pop highest priority task (lowest enum value = highest priority)
    fn popHighestPriority(self: *RankedQueue) ?RankedTask {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.items.items.len == 0) return null;

        // Find highest priority task
        var best_idx: usize = 0;
        var best_priority = self.items.items[0].priority;

        for (self.items.items[1..], 1..) |task, i| {
            if (@intFromEnum(task.priority) < @intFromEnum(best_priority)) {
                best_idx = i;
                best_priority = task.priority;
            }
        }

        return self.items.orderedRemove(best_idx);
    }

    fn len(self: *RankedQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.items.items.len;
    }
};

/// Shared context for all threads
const ThreadContext = struct {
    allocator: std.mem.Allocator,
    server_ctx: *ServerContext,
    unranked_queue: *UnrankedQueue,
    ranked_queue: *RankedQueue,
    running: std.atomic.Value(bool),
};

/// Ranker thread - pulls from unranked queue, classifies, pushes to ranked queue
fn rankerThread(ctx: *ThreadContext) void {
    std.debug.print("[ranker] Started ranking thread\n", .{});

    while (ctx.running.load(.acquire)) {
        if (ctx.unranked_queue.pop()) |task| {
            std.debug.print("[ranker] Ranking task {s}: '{s}'\n", .{
                task.id,
                task.text[0..@min(task.text.len, 40)],
            });

            // Rank the task using the model
            const priority = ctx.server_ctx.rankTask(task.text);

            // Push to ranked queue
            const ranked_task = RankedTask{
                .id = task.id,
                .text = task.text,
                .callback = task.callback,
                .priority = priority,
            };

            ctx.ranked_queue.push(ranked_task) catch |err| {
                std.debug.print("[ranker] Failed to enqueue ranked task: {}\n", .{err});
                sendCallbackError(ctx.allocator, task.callback, task.id, "queue_error", .internal_error) catch {};
            };

            std.debug.print("[ranker] Task {s} ranked as {s}\n", .{ task.id, priority.toString() });
        } else {
            // No tasks, sleep briefly
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    std.debug.print("[ranker] Stopped\n", .{});
}

/// Worker thread - pulls highest priority from ranked queue, runs inference
fn workerThread(ctx: *ThreadContext) void {
    std.debug.print("[worker] Started inference thread\n", .{});

    while (ctx.running.load(.acquire)) {
        if (ctx.ranked_queue.popHighestPriority()) |task| {
            std.debug.print("[worker] Processing task {s} (priority: {s})\n", .{
                task.id,
                task.priority.toString(),
            });

            // Run inference
            const response = ctx.server_ctx.generate(task.text, 256) catch |err| {
                std.debug.print("[worker] Inference failed: {}\n", .{err});
                sendCallbackError(ctx.allocator, task.callback, task.id, "inference_failed", .internal_error) catch {};
                continue;
            };
            defer ctx.server_ctx.freeString(response);

            std.debug.print("[worker] Generated {d} chars for {s}\n", .{ response.len, task.id });

            // Format response as JSON array
            var json_buf: [32768]u8 = undefined;
            const json_response = std.fmt.bufPrint(&json_buf, "[\"{s}\"]", .{response}) catch {
                sendCallbackError(ctx.allocator, task.callback, task.id, "response_too_long", .internal_error) catch {};
                continue;
            };

            // Send result to callback
            sendCallbackResult(ctx.allocator, task.callback, task.id, "__chat__", json_response, task.priority.toString()) catch |err| {
                std.debug.print("[worker] Failed to send callback: {}\n", .{err});
            };
        } else {
            // No tasks, sleep briefly
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    std.debug.print("[worker] Stopped\n", .{});
}

pub fn start(allocator: std.mem.Allocator, model_path: []const u8, config: cli.Config) !void {
    std.debug.print("Starting Granville server...\n", .{});
    std.debug.print("Model: {s}\n", .{model_path});
    std.debug.print("Driver: {s}\n", .{config.driver_backend});
    std.debug.print("Socket: {s}\n", .{config.socket_path});
    std.debug.print("Queue size: {d}\n", .{config.queue_size});
    std.debug.print("Platform: {s}\n", .{@tagName(builtin.os.tag)});

    // Initialize driver manager and load driver
    var manager = try driver_mod.DriverManager.init(allocator);
    defer manager.deinit();

    std.debug.print("\nLoading driver '{s}'...\n", .{config.driver_backend});
    var drv = manager.load(config.driver_backend) catch |err| {
        std.debug.print("Failed to load driver '{s}': {}\n", .{ config.driver_backend, err });
        std.debug.print("\nMake sure the driver is installed:\n", .{});
        std.debug.print("  granville driver install {s}\n", .{config.driver_backend});
        return err;
    };

    std.debug.print("Driver loaded: {s}\n", .{drv.name});

    // Load the model
    std.debug.print("\nLoading model '{s}'...\n", .{model_path});
    const model = drv.loadModel(model_path) catch |err| {
        std.debug.print("Failed to load model: {}\n", .{err});
        drv.deinit();
        return err;
    };
    std.debug.print("Model loaded successfully!\n", .{});

    // Create server context
    var ctx = ServerContext{
        .allocator = allocator,
        .driver = drv,
        .model = model,
        .model_path = model_path,
    };
    defer ctx.deinit();

    // Initialize queues
    var unranked_queue = UnrankedQueue.init(allocator);
    defer unranked_queue.deinit();

    var ranked_queue = RankedQueue.init(allocator);
    defer ranked_queue.deinit();

    // Create thread context
    var thread_ctx = ThreadContext{
        .allocator = allocator,
        .server_ctx = &ctx,
        .unranked_queue = &unranked_queue,
        .ranked_queue = &ranked_queue,
        .running = std.atomic.Value(bool).init(true),
    };

    // Start ranker thread (classifies tasks)
    const ranker = try std.Thread.spawn(.{}, rankerThread, .{&thread_ctx});
    defer {
        thread_ctx.running.store(false, .release);
        ranker.join();
    }

    // Start worker thread (runs inference)
    const worker = try std.Thread.spawn(.{}, workerThread, .{&thread_ctx});
    defer worker.join();

    // Create platform-specific server
    var server = try ipc.listen(config.socket_path);
    defer server.deinit();

    std.debug.print("\nListening on {s}\n", .{config.socket_path});
    std.debug.print("Server ready. Press Ctrl+C to stop.\n\n", .{});
    std.debug.print("Architecture: Submit -> ACK -> Unranked Queue -> Ranker -> Ranked Queue -> Worker -> Callback\n\n", .{});

    // Accept connections (fast path - just ACK and enqueue)
    while (true) {
        var connection = server.accept() catch |err| {
            std.debug.print("Accept error: {}\n", .{err});
            continue;
        };

        // Handle connection (receives task, ACKs, enqueues to unranked queue)
        handleConnection(allocator, &connection, &unranked_queue) catch |err| {
            std.debug.print("Connection error: {}\n", .{err});
        };
    }
}

/// Handle incoming connection - just ACK and enqueue (fast path)
fn handleConnection(
    allocator: std.mem.Allocator,
    connection: *ipc.Connection,
    unranked_queue: *UnrankedQueue,
) !void {
    defer connection.close();

    // Read incoming data
    var read_buf: [8192]u8 = undefined;
    const bytes_read = try connection.read(&read_buf);

    if (bytes_read == 0) return;

    std.debug.print("Received {d} bytes\n", .{bytes_read});

    // Parse MessagePack request
    var reader = std.Io.Reader.fixed(read_buf[0..bytes_read]);
    var write_buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);
    var packer = msgpack.PackerIO.init(&reader, &writer);

    const request_payload = packer.read(allocator) catch |err| {
        std.debug.print("Failed to parse MessagePack: {}\n", .{err});
        try sendErrorResponseConn(allocator, connection, "unknown", "invalid_request", .invalid_request);
        return;
    };
    defer request_payload.free(allocator);

    // Extract fields from request
    const id = (try request_payload.mapGet("id")) orelse {
        try sendErrorResponseConn(allocator, connection, "unknown", "missing_id", .invalid_request);
        return;
    };
    const id_str = id.str.value();

    const text = (try request_payload.mapGet("text")) orelse {
        try sendErrorResponseConn(allocator, connection, id_str, "missing_text", .invalid_request);
        return;
    };
    const text_str = text.str.value();

    const callback = (try request_payload.mapGet("callback")) orelse {
        try sendErrorResponseConn(allocator, connection, id_str, "missing_callback", .invalid_request);
        return;
    };
    const callback_str = callback.str.value();

    std.debug.print("Request: id={s}, text='{s}', callback={s}\n", .{
        id_str,
        text_str[0..@min(text_str.len, 40)],
        callback_str,
    });

    // Send immediate ACK response
    try sendAckResponseConn(allocator, connection, id_str);

    // Enqueue to unranked queue (will be ranked by ranker thread)
    const task = UnrankedTask{
        .id = id_str,
        .text = text_str,
        .callback = callback_str,
    };

    try unranked_queue.push(task);
    std.debug.print("Task {s} queued for ranking\n", .{id_str});
}

/// Send ACK response via IPC connection
fn sendAckResponseConn(allocator: std.mem.Allocator, connection: *ipc.Connection, id: []const u8) !void {
    var write_buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);
    var read_buf: [1]u8 = undefined;
    var reader = std.Io.Reader.fixed(&read_buf);
    var packer = msgpack.PackerIO.init(&reader, &writer);

    var ack = msgpack.Payload.mapPayload(allocator);
    defer ack.free(allocator);

    try ack.mapPut("id", try msgpack.Payload.strToPayload(id, allocator));
    try ack.mapPut("status", try msgpack.Payload.strToPayload("accepted", allocator));

    try packer.write(ack);

    // Get the written bytes and send
    const written = writer.end;
    _ = try connection.write(write_buf[0..written]);
}

/// Send error response via IPC connection
fn sendErrorResponseConn(
    allocator: std.mem.Allocator,
    connection: *ipc.Connection,
    id: []const u8,
    err_msg: []const u8,
    code: protocol.ErrorCode,
) !void {
    var write_buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);
    var read_buf: [1]u8 = undefined;
    var reader = std.Io.Reader.fixed(&read_buf);
    var packer = msgpack.PackerIO.init(&reader, &writer);

    var response = msgpack.Payload.mapPayload(allocator);
    defer response.free(allocator);

    try response.mapPut("id", try msgpack.Payload.strToPayload(id, allocator));
    try response.mapPut("error", try msgpack.Payload.strToPayload(err_msg, allocator));
    try response.mapPut("code", msgpack.Payload.uintToPayload(@intFromEnum(code)));

    try packer.write(response);

    const written = writer.end;
    _ = try connection.write(write_buf[0..written]);
}

/// Send error to callback via IPC
fn sendCallbackError(
    allocator: std.mem.Allocator,
    callback_path: []const u8,
    id: []const u8,
    err_msg: []const u8,
    code: protocol.ErrorCode,
) !void {
    // Connect to callback using platform IPC
    var conn = ipc.connect(callback_path) catch |err| {
        std.debug.print("Failed to connect to callback {s}: {}\n", .{ callback_path, err });
        return err;
    };
    defer conn.close();

    var write_buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);
    var read_buf: [1]u8 = undefined;
    var reader = std.Io.Reader.fixed(&read_buf);
    var packer = msgpack.PackerIO.init(&reader, &writer);

    var response = msgpack.Payload.mapPayload(allocator);
    defer response.free(allocator);

    try response.mapPut("id", try msgpack.Payload.strToPayload(id, allocator));
    try response.mapPut("error", try msgpack.Payload.strToPayload(err_msg, allocator));
    try response.mapPut("code", msgpack.Payload.uintToPayload(@intFromEnum(code)));

    try packer.write(response);

    const written = writer.end;
    _ = try conn.write(write_buf[0..written]);
}

/// Send result to callback via IPC
fn sendCallbackResult(
    allocator: std.mem.Allocator,
    callback_path: []const u8,
    id: []const u8,
    tool_id: []const u8,
    tool_input_json: []const u8,
    priority: []const u8,
) !void {
    // Connect to callback using platform IPC
    var conn = ipc.connect(callback_path) catch |err| {
        std.debug.print("Failed to connect to callback {s}: {}\n", .{ callback_path, err });
        return err;
    };
    defer conn.close();

    var write_buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);
    var read_buf: [1]u8 = undefined;
    var reader = std.Io.Reader.fixed(&read_buf);
    var packer = msgpack.PackerIO.init(&reader, &writer);

    var response = msgpack.Payload.mapPayload(allocator);
    defer response.free(allocator);

    try response.mapPut("id", try msgpack.Payload.strToPayload(id, allocator));
    try response.mapPut("tool_id", try msgpack.Payload.strToPayload(tool_id, allocator));
    try response.mapPut("tool_input_json", try msgpack.Payload.strToPayload(tool_input_json, allocator));
    try response.mapPut("priority", try msgpack.Payload.strToPayload(priority, allocator));

    try packer.write(response);

    const written = writer.end;
    _ = try conn.write(write_buf[0..written]);

    std.debug.print("Sent result to callback {s}\n", .{callback_path});
}

// ============================================================================
// TESTS
// ============================================================================

test "server config defaults" {
    const config = cli.Config{
        .command = .serve,
        .model_path = "/path/to/model.gguf",
    };
    try std.testing.expectEqualStrings("/tmp/granville.sock", config.socket_path);
    try std.testing.expectEqual(@as(usize, 1000), config.queue_size);
    try std.testing.expectEqual(@as(u16, 8080), config.port);
}

test "server config custom values" {
    const config = cli.Config{
        .command = .serve,
        .model_path = "/path/to/model.gguf",
        .socket_path = "/tmp/custom.sock",
        .queue_size = 500,
        .port = 9000,
    };
    try std.testing.expectEqualStrings("/tmp/custom.sock", config.socket_path);
    try std.testing.expectEqual(@as(usize, 500), config.queue_size);
    try std.testing.expectEqual(@as(u16, 9000), config.port);
}
