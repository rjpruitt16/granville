const std = @import("std");

pub const Priority = enum(u8) {
    critical = 0,
    high = 1,
    normal = 2,
    low = 3,

    pub fn fromString(s: []const u8) Priority {
        if (std.mem.eql(u8, s, "critical")) return .critical;
        if (std.mem.eql(u8, s, "high")) return .high;
        if (std.mem.eql(u8, s, "low")) return .low;
        return .normal;
    }

    pub fn toString(self: Priority) []const u8 {
        return switch (self) {
            .critical => "critical",
            .high => "high",
            .normal => "normal",
            .low => "low",
        };
    }
};

pub const Task = struct {
    id: []const u8,
    text: []const u8,
    priority: Priority,
    ranked: bool,
    timestamp: i64,

    pub fn compare(_: void, a: Task, b: Task) std.math.Order {
        // First compare by priority (lower enum value = higher priority)
        const priority_cmp = std.math.order(@intFromEnum(a.priority), @intFromEnum(b.priority));
        if (priority_cmp != .eq) return priority_cmp;

        // Then by timestamp (earlier = higher priority)
        return std.math.order(a.timestamp, b.timestamp);
    }
};

pub const Scheduler = struct {
    queue: std.PriorityQueue(Task, void, Task.compare),
    max_size: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) !Scheduler {
        return Scheduler{
            .queue = std.PriorityQueue(Task, void, Task.compare).init(allocator, {}),
            .max_size = max_size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.queue.deinit();
    }

    pub fn enqueue(self: *Scheduler, task: Task) !void {
        if (self.queue.count() >= self.max_size) {
            return error.QueueFull;
        }
        try self.queue.add(task);
    }

    pub fn dequeue(self: *Scheduler) ?Task {
        return self.queue.removeOrNull();
    }

    pub fn count(self: *Scheduler) usize {
        return self.queue.count();
    }

    pub fn isFull(self: *Scheduler) bool {
        return self.queue.count() >= self.max_size;
    }

    pub fn isEmpty(self: *Scheduler) bool {
        return self.queue.count() == 0;
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "priority enum ordering" {
    try std.testing.expect(@intFromEnum(Priority.critical) < @intFromEnum(Priority.high));
    try std.testing.expect(@intFromEnum(Priority.high) < @intFromEnum(Priority.normal));
    try std.testing.expect(@intFromEnum(Priority.normal) < @intFromEnum(Priority.low));
}

test "priority from string" {
    try std.testing.expectEqual(Priority.critical, Priority.fromString("critical"));
    try std.testing.expectEqual(Priority.high, Priority.fromString("high"));
    try std.testing.expectEqual(Priority.normal, Priority.fromString("normal"));
    try std.testing.expectEqual(Priority.low, Priority.fromString("low"));
    try std.testing.expectEqual(Priority.normal, Priority.fromString("unknown"));
}

test "priority to string" {
    try std.testing.expectEqualStrings("critical", Priority.critical.toString());
    try std.testing.expectEqualStrings("high", Priority.high.toString());
    try std.testing.expectEqualStrings("normal", Priority.normal.toString());
    try std.testing.expectEqualStrings("low", Priority.low.toString());
}

test "scheduler enqueue and dequeue by priority" {
    const allocator = std.testing.allocator;
    var sched = try Scheduler.init(allocator, 10);
    defer sched.deinit();

    // Add tasks with different priorities (out of order)
    try sched.enqueue(.{
        .id = "1",
        .text = "low priority task",
        .priority = .low,
        .ranked = true,
        .timestamp = 100,
    });

    try sched.enqueue(.{
        .id = "2",
        .text = "critical task",
        .priority = .critical,
        .ranked = true,
        .timestamp = 200,
    });

    try sched.enqueue(.{
        .id = "3",
        .text = "normal task",
        .priority = .normal,
        .ranked = true,
        .timestamp = 150,
    });

    // Should dequeue in priority order: critical, normal, low
    const first = sched.dequeue().?;
    try std.testing.expectEqualStrings("2", first.id);
    try std.testing.expectEqual(Priority.critical, first.priority);

    const second = sched.dequeue().?;
    try std.testing.expectEqualStrings("3", second.id);
    try std.testing.expectEqual(Priority.normal, second.priority);

    const third = sched.dequeue().?;
    try std.testing.expectEqualStrings("1", third.id);
    try std.testing.expectEqual(Priority.low, third.priority);

    try std.testing.expect(sched.dequeue() == null);
}

test "scheduler queue full returns error" {
    const allocator = std.testing.allocator;
    var sched = try Scheduler.init(allocator, 2);
    defer sched.deinit();

    try sched.enqueue(.{ .id = "1", .text = "a", .priority = .normal, .ranked = true, .timestamp = 1 });
    try sched.enqueue(.{ .id = "2", .text = "b", .priority = .normal, .ranked = true, .timestamp = 2 });

    // Third should fail
    const result = sched.enqueue(.{ .id = "3", .text = "c", .priority = .normal, .ranked = true, .timestamp = 3 });
    try std.testing.expectError(error.QueueFull, result);

    try std.testing.expect(sched.isFull());
}

test "same priority ordered by timestamp (FIFO)" {
    const allocator = std.testing.allocator;
    var sched = try Scheduler.init(allocator, 10);
    defer sched.deinit();

    try sched.enqueue(.{ .id = "late", .text = "a", .priority = .normal, .ranked = true, .timestamp = 300 });
    try sched.enqueue(.{ .id = "early", .text = "b", .priority = .normal, .ranked = true, .timestamp = 100 });
    try sched.enqueue(.{ .id = "middle", .text = "c", .priority = .normal, .ranked = true, .timestamp = 200 });

    // Should come out in timestamp order (earliest first)
    try std.testing.expectEqualStrings("early", sched.dequeue().?.id);
    try std.testing.expectEqualStrings("middle", sched.dequeue().?.id);
    try std.testing.expectEqualStrings("late", sched.dequeue().?.id);
}

test "scheduler count and isEmpty" {
    const allocator = std.testing.allocator;
    var sched = try Scheduler.init(allocator, 10);
    defer sched.deinit();

    try std.testing.expect(sched.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), sched.count());

    try sched.enqueue(.{ .id = "1", .text = "a", .priority = .normal, .ranked = true, .timestamp = 1 });
    try std.testing.expect(!sched.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), sched.count());

    _ = sched.dequeue();
    try std.testing.expect(sched.isEmpty());
}

test "task compare function" {
    const high_early = Task{ .id = "1", .text = "", .priority = .high, .ranked = true, .timestamp = 100 };
    const high_late = Task{ .id = "2", .text = "", .priority = .high, .ranked = true, .timestamp = 200 };
    const low_early = Task{ .id = "3", .text = "", .priority = .low, .ranked = true, .timestamp = 50 };

    // High priority comes before low priority regardless of timestamp
    try std.testing.expectEqual(std.math.Order.lt, Task.compare({}, high_early, low_early));

    // Same priority: earlier timestamp comes first
    try std.testing.expectEqual(std.math.Order.lt, Task.compare({}, high_early, high_late));
}
