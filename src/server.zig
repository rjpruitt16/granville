const std = @import("std");
const msgpack = @import("msgpack");
const cli = @import("cli.zig");
const scheduler = @import("scheduler.zig");
const protocol = @import("protocol.zig");
const driver_mod = @import("driver.zig");
const model_pool = @import("model_pool.zig");
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
    const windows = std.os.windows;

    // Windows named pipe constants
    const PIPE_ACCESS_DUPLEX: windows.DWORD = 0x00000003;
    const PIPE_TYPE_BYTE: windows.DWORD = 0x00000000;
    const PIPE_READMODE_BYTE: windows.DWORD = 0x00000000;
    const PIPE_WAIT: windows.DWORD = 0x00000000;
    const PIPE_UNLIMITED_INSTANCES: windows.DWORD = 255;
    const ERROR_PIPE_CONNECTED: windows.Win32Error = .PIPE_CONNECTED;

    // External Windows API functions
    extern "kernel32" fn CreateNamedPipeW(
        lpName: [*:0]const u16,
        dwOpenMode: windows.DWORD,
        dwPipeMode: windows.DWORD,
        nMaxInstances: windows.DWORD,
        nOutBufferSize: windows.DWORD,
        nInBufferSize: windows.DWORD,
        nDefaultTimeOut: windows.DWORD,
        lpSecurityAttributes: ?*anyopaque,
    ) callconv(std.builtin.CallingConvention.winapi) windows.HANDLE;

    extern "kernel32" fn ConnectNamedPipe(
        hNamedPipe: windows.HANDLE,
        lpOverlapped: ?*anyopaque,
    ) callconv(std.builtin.CallingConvention.winapi) windows.BOOL;

    extern "kernel32" fn DisconnectNamedPipe(
        hNamedPipe: windows.HANDLE,
    ) callconv(std.builtin.CallingConvention.winapi) windows.BOOL;

    pub const Server = struct {
        pipe_path_w: []const u16,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Server) void {
            self.allocator.free(self.pipe_path_w);
        }

        pub fn accept(self: *Server) !Connection {
            // Windows named pipe accept - create instance and wait
            const handle = CreateNamedPipeW(
                @ptrCast(self.pipe_path_w.ptr),
                PIPE_ACCESS_DUPLEX,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                PIPE_UNLIMITED_INSTANCES,
                8192, // output buffer
                8192, // input buffer
                0, // default timeout
                null, // security attributes
            );

            if (handle == windows.INVALID_HANDLE_VALUE) {
                return error.CreatePipeFailed;
            }

            // Wait for client connection
            if (ConnectNamedPipe(handle, null) == 0) {
                const err = windows.GetLastError();
                if (err != ERROR_PIPE_CONNECTED) {
                    windows.CloseHandle(handle);
                    return error.ConnectPipeFailed;
                }
            }

            return Connection{ .handle = handle };
        }
    };

    pub const Connection = struct {
        handle: windows.HANDLE,

        pub fn read(self: *Connection, buf: []u8) !usize {
            return windows.ReadFile(self.handle, buf, null);
        }

        pub fn write(self: *Connection, data: []const u8) !usize {
            return windows.WriteFile(self.handle, data, null);
        }

        pub fn close(self: *Connection) void {
            _ = DisconnectNamedPipe(self.handle);
            windows.CloseHandle(self.handle);
        }
    };

    pub fn listen(path: []const u8) !Server {
        // For Windows, we need an allocator - use page allocator as fallback
        const allocator = std.heap.page_allocator;
        // Convert to Windows named pipe path format (wide string)
        var pipe_path_buf: [256]u8 = undefined;
        const pipe_path = std.fmt.bufPrint(&pipe_path_buf, "\\\\.\\pipe\\{s}", .{path}) catch {
            return error.PathTooLong;
        };
        // Convert UTF-8 to UTF-16
        const pipe_path_w = std.unicode.utf8ToUtf16LeAlloc(allocator, pipe_path) catch {
            return error.EncodingFailed;
        };
        return Server{ .pipe_path_w = pipe_path_w, .allocator = allocator };
    }

    pub fn connect(path: []const u8) !Connection {
        var pipe_path_buf: [256]u8 = undefined;
        const pipe_path = std.fmt.bufPrint(&pipe_path_buf, "\\\\.\\pipe\\{s}", .{path}) catch {
            return error.PathTooLong;
        };

        // Convert to UTF-16 for Windows API
        var wide_buf: [512]u16 = undefined;
        const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, pipe_path) catch {
            return error.EncodingFailed;
        };
        wide_buf[wide_len] = 0; // null terminate

        // Use OpenFile for connecting to existing named pipe
        const handle = windows.OpenFile(@ptrCast(wide_buf[0..wide_len :0]), .{
            .access_mask = windows.GENERIC_READ | windows.GENERIC_WRITE,
            .creation = windows.FILE_OPEN,
        }) catch {
            return error.ConnectFailed;
        };

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

/// Result from inference containing both response and which model was used
const InferenceResult = struct {
    response: []const u8,
    model_id: u32,
};

/// Server context holding loaded driver and model pool
const ServerContext = struct {
    allocator: std.mem.Allocator,
    driver: ?driver_mod.Driver,
    pool: ?model_pool.ModelPool,

    /// Generate using any available model (least-busy routing)
    /// If requested_model_id is provided, use that model; otherwise pick least-busy
    fn generateWithRouting(self: *ServerContext, requested_model_id: ?u32, prompt: []const u8, max_tokens: u32) !InferenceResult {
        if (self.pool) |*pool| {
            // Use atomic acquire for least-busy routing to prevent race conditions
            const model = if (requested_model_id) |id|
                pool.getById(id) orelse return error.ModelNotFound
            else
                pool.acquireLeastBusy(null) orelse return error.NoModelsAvailable;

            defer pool.markIdle(model);
            const response = try pool.generate(model, prompt, max_tokens);
            return .{ .response = response, .model_id = model.id };
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

        // Ask model to classify (short response) - uses least-busy routing
        const result = self.generateWithRouting(null, prompt, 10) catch {
            std.debug.print("[ranking] Model error, defaulting to normal\n", .{});
            return .normal;
        };
        defer self.freeString(result.response);

        // Parse response - look for priority keywords
        const upper = blk: {
            var buf: [64]u8 = undefined;
            const len = @min(result.response.len, buf.len);
            for (result.response[0..len], 0..) |c, i| {
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
            result.response[0..@min(result.response.len, 30)],
        });

        return priority;
    }

    fn freeString(self: *ServerContext, str: []const u8) void {
        if (self.pool) |*pool| {
            pool.freeString(str);
        }
    }

    fn deinit(self: *ServerContext) void {
        if (self.pool) |*pool| {
            pool.deinit();
        }
        if (self.driver) |*drv| {
            drv.deinit();
        }
    }
};

/// Unranked task - waiting to be classified
const UnrankedTask = struct {
    id: []const u8,
    text: []const u8,
    callback: []const u8,
    model_id: ?u32, // null = load balancer picks, or specific model for sticky sessions
    max_tokens: u32, // default 256
};

/// Ranked task - ready for inference
const RankedTask = struct {
    id: []const u8,
    text: []const u8,
    callback: []const u8,
    priority: scheduler.Priority,
    model_id: ?u32, // null = load balancer picks, or specific model for sticky sessions
    max_tokens: u32, // default 256
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
    worker_id: u32, // identifies which worker this is
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
                .model_id = task.model_id,
                .max_tokens = task.max_tokens,
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
    std.debug.print("[worker-{d}] Started inference thread\n", .{ctx.worker_id});

    while (ctx.running.load(.acquire)) {
        if (ctx.ranked_queue.popHighestPriority()) |task| {
            std.debug.print("[worker-{d}] Processing task {s} (priority: {s}, requested_model: {?})\n", .{
                ctx.worker_id,
                task.id,
                task.priority.toString(),
                task.model_id,
            });

            // Run inference with routing (uses requested model_id or least-busy)
            const result = ctx.server_ctx.generateWithRouting(task.model_id, task.text, task.max_tokens) catch |err| {
                std.debug.print("[worker-{d}] Inference failed: {}\n", .{ ctx.worker_id, err });
                sendCallbackError(ctx.allocator, task.callback, task.id, "inference_failed", .internal_error) catch {};
                continue;
            };
            defer ctx.server_ctx.freeString(result.response);

            std.debug.print("[worker-{d}] Generated {d} chars for {s} (model: {d})\n", .{ ctx.worker_id, result.response.len, task.id, result.model_id });

            // Format response as JSON array
            var json_buf: [32768]u8 = undefined;
            const json_response = std.fmt.bufPrint(&json_buf, "[\"{s}\"]", .{result.response}) catch {
                sendCallbackError(ctx.allocator, task.callback, task.id, "response_too_long", .internal_error) catch {};
                continue;
            };

            // Send result to callback (includes model_id for sticky routing)
            sendCallbackResult(ctx.allocator, task.callback, task.id, result.model_id, "__chat__", json_response, task.priority.toString()) catch |err| {
                std.debug.print("[worker-{d}] Failed to send callback: {}\n", .{ ctx.worker_id, err });
            };
        } else {
            // No tasks, sleep briefly
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    std.debug.print("[worker-{d}] Stopped\n", .{ctx.worker_id});
}

pub fn start(allocator: std.mem.Allocator, config: cli.Config) !void {
    std.debug.print("Starting Granville server...\n", .{});
    std.debug.print("Models: {d} to load\n", .{config.model_specs.items.len});
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

    // Create model pool and load all models
    var pool = model_pool.ModelPool.init(allocator, &drv);

    std.debug.print("\nLoading {d} model(s)...\n", .{config.model_specs.items.len});
    for (config.model_specs.items) |spec| {
        _ = pool.loadModel(spec) catch |err| {
            std.debug.print("Failed to load model '{s}': {}\n", .{ spec.path, err });
            pool.deinit();
            drv.deinit();
            return err;
        };
    }
    std.debug.print("All models loaded successfully! ({d} total)\n", .{pool.count()});

    // Create server context
    var ctx = ServerContext{
        .allocator = allocator,
        .driver = drv,
        .pool = pool,
    };
    defer ctx.deinit();

    // Initialize queues
    var unranked_queue = UnrankedQueue.init(allocator);
    defer unranked_queue.deinit();

    var ranked_queue = RankedQueue.init(allocator);
    defer ranked_queue.deinit();

    // Determine number of worker threads
    // Default: min(num_models, 8) for bounded parallelism
    const max_default_workers: usize = 8;
    const num_workers = config.num_workers orelse @min(pool.count(), max_default_workers);
    std.debug.print("Starting {d} worker thread(s) for {d} model(s)\n", .{ num_workers, pool.count() });

    // Create thread contexts - one per worker
    const worker_contexts = try allocator.alloc(ThreadContext, num_workers);
    defer allocator.free(worker_contexts);

    // Initialize shared running flag
    var running = std.atomic.Value(bool).init(true);

    for (worker_contexts, 0..) |*wctx, i| {
        wctx.* = ThreadContext{
            .allocator = allocator,
            .server_ctx = &ctx,
            .unranked_queue = &unranked_queue,
            .ranked_queue = &ranked_queue,
            .running = running,
            .worker_id = @intCast(i + 1),
        };
    }

    // Create ranker context (shares running flag)
    var ranker_ctx = ThreadContext{
        .allocator = allocator,
        .server_ctx = &ctx,
        .unranked_queue = &unranked_queue,
        .ranked_queue = &ranked_queue,
        .running = running,
        .worker_id = 0, // ranker doesn't use this
    };

    // Start ranker thread (classifies tasks)
    const ranker = try std.Thread.spawn(.{}, rankerThread, .{&ranker_ctx});
    defer {
        running.store(false, .release);
        ranker.join();
    }

    // Start worker threads (bounded pool for parallel inference)
    var workers = try allocator.alloc(std.Thread, num_workers);
    defer allocator.free(workers);

    for (worker_contexts, 0..) |*wctx, i| {
        workers[i] = try std.Thread.spawn(.{}, workerThread, .{wctx});
    }
    defer {
        for (workers) |worker| {
            worker.join();
        }
    }

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

        // Handle connection (receives task, ACKs, enqueues)
        handleConnection(allocator, &connection, &unranked_queue, &ranked_queue) catch |err| {
            std.debug.print("Connection error: {}\n", .{err});
        };
    }
}

/// Handle incoming connection - ACK and enqueue (fast path)
/// If ranked=true, goes to unranked_queue for classification
/// If ranked=false, goes directly to ranked_queue with normal priority
fn handleConnection(
    allocator: std.mem.Allocator,
    connection: *ipc.Connection,
    unranked_queue: *UnrankedQueue,
    ranked_queue: *RankedQueue,
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
    // Duplicate strings so they outlive the request_payload (which gets freed below)
    const id_str = try allocator.dupe(u8, id.str.value());
    errdefer allocator.free(id_str);

    const text = (try request_payload.mapGet("text")) orelse {
        try sendErrorResponseConn(allocator, connection, id_str, "missing_text", .invalid_request);
        return;
    };
    const text_str = try allocator.dupe(u8, text.str.value());
    errdefer allocator.free(text_str);

    const callback = (try request_payload.mapGet("callback")) orelse {
        try sendErrorResponseConn(allocator, connection, id_str, "missing_callback", .invalid_request);
        return;
    };
    const callback_str = try allocator.dupe(u8, callback.str.value());
    errdefer allocator.free(callback_str);

    // Parse optional model_id (for sticky routing)
    const model_id: ?u32 = blk: {
        const model_id_val = try request_payload.mapGet("model_id");
        if (model_id_val) |val| {
            if (val == .uint) {
                break :blk @intCast(val.uint);
            }
        }
        break :blk null;
    };

    // Parse optional ranked flag (default: true for backward compatibility)
    const needs_ranking: bool = blk: {
        const ranked_val = try request_payload.mapGet("ranked");
        if (ranked_val) |val| {
            if (val == .bool) {
                break :blk val.bool;
            }
        }
        break :blk true; // default to ranking
    };

    // Parse optional max_tokens (default: 256)
    const max_tokens: u32 = blk: {
        const max_tokens_val = try request_payload.mapGet("max_tokens");
        if (max_tokens_val) |val| {
            if (val == .uint) {
                break :blk @intCast(val.uint);
            }
        }
        break :blk 256; // default
    };

    std.debug.print("Request: id={s}, text='{s}', callback={s}, model_id={?}, ranked={}\n", .{
        id_str,
        text_str[0..@min(text_str.len, 40)],
        callback_str,
        model_id,
        needs_ranking,
    });

    // Send immediate ACK response
    try sendAckResponseConn(allocator, connection, id_str);

    if (needs_ranking) {
        // Enqueue to unranked queue (will be ranked by ranker thread)
        const task = UnrankedTask{
            .id = id_str,
            .text = text_str,
            .callback = callback_str,
            .model_id = model_id,
            .max_tokens = max_tokens,
        };
        try unranked_queue.push(task);
        std.debug.print("Task {s} queued for ranking (max_tokens={d})\n", .{ id_str, max_tokens });
    } else {
        // Skip ranking - go directly to ranked queue with normal priority
        const task = RankedTask{
            .id = id_str,
            .text = text_str,
            .callback = callback_str,
            .priority = .normal,
            .model_id = model_id,
            .max_tokens = max_tokens,
        };
        try ranked_queue.push(task);
        std.debug.print("Task {s} queued directly (skip ranking, max_tokens={d})\n", .{ id_str, max_tokens });
    }
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
    model_id: u32,
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
    try response.mapPut("model_id", msgpack.Payload{ .uint = model_id });
    try response.mapPut("tool_id", try msgpack.Payload.strToPayload(tool_id, allocator));
    try response.mapPut("tool_input_json", try msgpack.Payload.strToPayload(tool_input_json, allocator));
    try response.mapPut("priority", try msgpack.Payload.strToPayload(priority, allocator));

    try packer.write(response);

    const written = writer.end;
    _ = try conn.write(write_buf[0..written]);

    std.debug.print("Sent result to callback {s} (model_id: {d})\n", .{ callback_path, model_id });
}

// ============================================================================
// TESTS
// ============================================================================

test "server config defaults" {
    var config = cli.Config.init(std.testing.allocator);
    defer config.deinit();
    config.command = .serve;
    try std.testing.expectEqualStrings("/tmp/granville.sock", config.socket_path);
    try std.testing.expectEqual(@as(usize, 1000), config.queue_size);
    try std.testing.expectEqual(@as(u16, 8080), config.port);
}

test "server config custom values" {
    var config = cli.Config.init(std.testing.allocator);
    defer config.deinit();
    config.command = .serve;
    config.socket_path = "/tmp/custom.sock";
    config.queue_size = 500;
    config.port = 9000;
    try std.testing.expectEqualStrings("/tmp/custom.sock", config.socket_path);
    try std.testing.expectEqual(@as(usize, 500), config.queue_size);
    try std.testing.expectEqual(@as(u16, 9000), config.port);
}
