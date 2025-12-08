const std = @import("std");
const driver_mod = @import("driver.zig");

/// Model type - defaults to "unassigned" if not specified
/// Future: "stt", "tts", "embedding", etc.
pub const ModelType = enum {
    inference,
    stt,
    tts,
    embedding,
    unassigned, // default when user doesn't specify

    pub fn fromString(s: []const u8) ModelType {
        if (std.mem.eql(u8, s, "inference")) return .inference;
        if (std.mem.eql(u8, s, "stt")) return .stt;
        if (std.mem.eql(u8, s, "tts")) return .tts;
        if (std.mem.eql(u8, s, "embedding")) return .embedding;
        return .unassigned;
    }

    pub fn toString(self: ModelType) []const u8 {
        return switch (self) {
            .inference => "inference",
            .stt => "stt",
            .tts => "tts",
            .embedding => "embedding",
            .unassigned => "unassigned",
        };
    }
};

/// A loaded model in the pool
pub const Model = struct {
    id: u32, // 1, 2, 3... assigned at load time
    model_type: ModelType,
    path: []const u8,
    handle: *anyopaque, // driver's model handle
    active_requests: u32, // for least-busy routing
};

/// Specification for loading a model (parsed from CLI)
pub const ModelSpec = struct {
    model_type: ModelType,
    id: ?u32, // null = auto-assign
    path: []const u8,

    /// Parse a model spec string
    /// Formats:
    ///   "path.gguf" -> type=unassigned, id=auto, path=path.gguf
    ///   "inference:path.gguf" -> type=inference, id=auto, path=path.gguf
    ///   "inference:1:path.gguf" -> type=inference, id=1, path=path.gguf
    pub fn parse(spec: []const u8) ModelSpec {
        var parts_iter = std.mem.splitScalar(u8, spec, ':');

        const first = parts_iter.next() orelse return .{
            .model_type = .unassigned,
            .id = null,
            .path = spec,
        };

        const second = parts_iter.next();
        const third = parts_iter.next();

        if (third) |path| {
            // Format: type:id:path
            return .{
                .model_type = ModelType.fromString(first),
                .id = std.fmt.parseInt(u32, second.?, 10) catch null,
                .path = path,
            };
        } else if (second) |path_or_id| {
            // Could be type:path or type:id (unlikely without path)
            // Assume type:path
            return .{
                .model_type = ModelType.fromString(first),
                .id = null,
                .path = path_or_id,
            };
        } else {
            // Just a path
            return .{
                .model_type = .unassigned,
                .id = null,
                .path = first,
            };
        }
    }
};

/// Pool of loaded models with least-busy routing
pub const ModelPool = struct {
    allocator: std.mem.Allocator,
    driver: *driver_mod.Driver,
    models: std.ArrayList(Model),
    mutex: std.Thread.Mutex,
    next_id: u32,

    pub fn init(allocator: std.mem.Allocator, driver: *driver_mod.Driver) ModelPool {
        return .{
            .allocator = allocator,
            .driver = driver,
            .models = .empty,
            .mutex = .{},
            .next_id = 1,
        };
    }

    pub fn deinit(self: *ModelPool) void {
        // Unload all models
        for (self.models.items) |model| {
            self.driver.unloadModel(@ptrCast(model.handle));
        }
        self.models.deinit(self.allocator);
    }

    /// Load a model from spec and add to pool
    pub fn loadModel(self: *ModelPool, spec: ModelSpec) !*Model {
        std.debug.print("Loading model: {s} (type={s})\n", .{ spec.path, spec.model_type.toString() });

        const handle = try self.driver.loadModel(spec.path);

        const id = spec.id orelse blk: {
            const assigned = self.next_id;
            self.next_id += 1;
            break :blk assigned;
        };

        // If user specified an ID, make sure next_id is higher
        if (spec.id) |specified_id| {
            if (specified_id >= self.next_id) {
                self.next_id = specified_id + 1;
            }
        }

        const path_copy = try self.allocator.dupe(u8, spec.path);

        try self.models.append(self.allocator, .{
            .id = id,
            .model_type = spec.model_type,
            .path = path_copy,
            .handle = handle,
            .active_requests = 0,
        });

        std.debug.print("Model loaded: id={d}, type={s}, path={s}\n", .{
            id,
            spec.model_type.toString(),
            spec.path,
        });

        return &self.models.items[self.models.items.len - 1];
    }

    /// Get model by ID
    pub fn getById(self: *ModelPool, id: u32) ?*Model {
        for (self.models.items) |*model| {
            if (model.id == id) {
                return model;
            }
        }
        return null;
    }

    /// Pick least-busy model and atomically mark it busy
    /// Returns null if no models available
    pub fn acquireLeastBusy(self: *ModelPool, model_type: ?ModelType) ?*Model {
        self.mutex.lock();
        defer self.mutex.unlock();

        var best: ?*Model = null;
        var min_active: u32 = std.math.maxInt(u32);

        for (self.models.items) |*model| {
            // Filter by type if specified (unassigned matches anything)
            if (model_type) |mt| {
                if (model.model_type != mt and model.model_type != .unassigned) {
                    continue;
                }
            }

            if (model.active_requests < min_active) {
                min_active = model.active_requests;
                best = model;
            }
        }

        // Atomically mark as busy before releasing lock
        if (best) |model| {
            model.active_requests += 1;
        }

        return best;
    }

    /// Mark model as idle (decrement active count)
    pub fn markIdle(self: *ModelPool, model: *Model) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (model.active_requests > 0) {
            model.active_requests -= 1;
        }
    }

    /// Get number of loaded models
    pub fn count(self: *ModelPool) usize {
        return self.models.items.len;
    }

    /// Generate text using a specific model
    pub fn generate(self: *ModelPool, model: *Model, prompt: []const u8, max_tokens: u32) ![]const u8 {
        return self.driver.generate(model.handle, prompt, max_tokens);
    }

    /// Free a string returned by generate
    pub fn freeString(self: *ModelPool, str: []const u8) void {
        self.driver.freeString(str);
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "ModelSpec.parse - simple path" {
    const spec = ModelSpec.parse("model.gguf");
    try std.testing.expectEqual(ModelType.unassigned, spec.model_type);
    try std.testing.expect(spec.id == null);
    try std.testing.expectEqualStrings("model.gguf", spec.path);
}

test "ModelSpec.parse - type:path" {
    const spec = ModelSpec.parse("inference:model.gguf");
    try std.testing.expectEqual(ModelType.inference, spec.model_type);
    try std.testing.expect(spec.id == null);
    try std.testing.expectEqualStrings("model.gguf", spec.path);
}

test "ModelSpec.parse - type:id:path" {
    const spec = ModelSpec.parse("stt:5:whisper.gguf");
    try std.testing.expectEqual(ModelType.stt, spec.model_type);
    try std.testing.expectEqual(@as(u32, 5), spec.id.?);
    try std.testing.expectEqualStrings("whisper.gguf", spec.path);
}

test "ModelType.fromString" {
    try std.testing.expectEqual(ModelType.inference, ModelType.fromString("inference"));
    try std.testing.expectEqual(ModelType.stt, ModelType.fromString("stt"));
    try std.testing.expectEqual(ModelType.unassigned, ModelType.fromString("unknown"));
}
