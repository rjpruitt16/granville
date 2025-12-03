const std = @import("std");

// ============================================================================
// REQUEST TYPES (from client)
// ============================================================================

/// Task request from any client (Python, Go, Rust, etc.)
pub const TaskRequest = struct {
    id: []const u8,
    text: []const u8,
    ranked: bool = false,
    priority: ?[]const u8 = null,
    callback: []const u8, // Unix socket path to send result
};

// ============================================================================
// RESPONSE TYPES (to client)
// ============================================================================

/// Immediate acknowledgment when task is accepted
pub const AckResponse = struct {
    id: []const u8,
    status: []const u8 = "accepted",
};

/// Tool call parsed from model output
/// tool_input is JSON string - keeps it simple, client parses
pub const ToolCall = struct {
    tool_id: []const u8, // "__chat__", "search", "read_file", etc.
    tool_input_json: []const u8, // JSON array: "[\"query\", 10]"
};

/// Final result sent to callback
pub const TaskResult = struct {
    id: []const u8,
    tool_id: ?[]const u8 = null,
    tool_input_json: ?[]const u8 = null,
    priority: []const u8 = "normal",
    raw_output: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    code: ?u16 = null,
};

/// Error codes
pub const ErrorCode = enum(u16) {
    queue_full = 429,
    invalid_request = 400,
    parse_error = 422,
    internal_error = 500,
    callback_failed = 502,
};

// ============================================================================
// JSON PARSING (model output → tool call)
// ============================================================================

/// Parse model JSON output into a ToolCall
/// Expected: {"tool_id": "search", "tool_input": ["query", 10]}
pub fn parseModelOutput(allocator: std.mem.Allocator, json_str: []const u8) !ToolCall {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidJson;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidFormat;

    const obj = root.object;

    // Get tool_id
    const tool_id_json = obj.get("tool_id") orelse return error.MissingToolId;
    const tool_id: []const u8 = switch (tool_id_json) {
        .string => |s| try allocator.dupe(u8, s),
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        else => return error.InvalidToolId,
    };

    // Get tool_input and serialize back to JSON
    const tool_input_val = obj.get("tool_input") orelse return error.MissingToolInput;
    const tool_input_json = std.json.Stringify.valueAlloc(allocator, tool_input_val, .{}) catch {
        return error.OutOfMemory;
    };

    return ToolCall{
        .tool_id = tool_id,
        .tool_input_json = tool_input_json,
    };
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

pub fn errorResult(id: []const u8, err: []const u8, code: ErrorCode) TaskResult {
    return TaskResult{
        .id = id,
        .@"error" = err,
        .code = @intFromEnum(code),
    };
}

pub fn successResult(id: []const u8, tool_id: []const u8, tool_input_json: []const u8, priority: []const u8, raw: ?[]const u8) TaskResult {
    return TaskResult{
        .id = id,
        .tool_id = tool_id,
        .tool_input_json = tool_input_json,
        .priority = priority,
        .raw_output = raw,
    };
}

// ============================================================================
// TESTS
// ============================================================================

test "error result creation" {
    const result = errorResult("test-id", "queue_full", .queue_full);
    try std.testing.expectEqualStrings("test-id", result.id);
    try std.testing.expectEqualStrings("queue_full", result.@"error".?);
    try std.testing.expectEqual(@as(u16, 429), result.code.?);
    try std.testing.expect(result.tool_id == null);
}

test "task request default values" {
    const req = TaskRequest{
        .id = "123",
        .text = "hello",
        .callback = "/tmp/test.sock",
    };
    try std.testing.expectEqual(false, req.ranked);
    try std.testing.expect(req.priority == null);
}

test "ack response default status" {
    const ack = AckResponse{
        .id = "123",
    };
    try std.testing.expectEqualStrings("accepted", ack.status);
}

test "parse model output - chat" {
    const allocator = std.testing.allocator;
    const json =
        \\{"tool_id": "__chat__", "tool_input": ["Hello there!"]}
    ;

    const result = try parseModelOutput(allocator, json);
    defer allocator.free(result.tool_id);
    defer allocator.free(result.tool_input_json);

    try std.testing.expectEqualStrings("__chat__", result.tool_id);
    try std.testing.expectEqualStrings("[\"Hello there!\"]", result.tool_input_json);
}

test "parse model output - tool with mixed types" {
    const allocator = std.testing.allocator;
    const json =
        \\{"tool_id": "search", "tool_input": ["weather", 5, true]}
    ;

    const result = try parseModelOutput(allocator, json);
    defer allocator.free(result.tool_id);
    defer allocator.free(result.tool_input_json);

    try std.testing.expectEqualStrings("search", result.tool_id);
    try std.testing.expectEqualStrings("[\"weather\",5,true]", result.tool_input_json);
}

test "parse model output - integer tool_id" {
    const allocator = std.testing.allocator;
    const json =
        \\{"tool_id": 42, "tool_input": ["arg1"]}
    ;

    const result = try parseModelOutput(allocator, json);
    defer allocator.free(result.tool_id);
    defer allocator.free(result.tool_input_json);

    try std.testing.expectEqualStrings("42", result.tool_id);
}

test "parse model output - invalid json" {
    const allocator = std.testing.allocator;
    const result = parseModelOutput(allocator, "not json");
    try std.testing.expectError(error.InvalidJson, result);
}

test "parse model output - missing tool_id" {
    const allocator = std.testing.allocator;
    const json =
        \\{"tool_input": ["arg"]}
    ;
    const result = parseModelOutput(allocator, json);
    try std.testing.expectError(error.MissingToolId, result);
}
