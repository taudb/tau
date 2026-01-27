//! JSON serialization utilities for tau

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Serializes a slice of f64 values to a JSON array string.
/// Returns an allocator-owned string that must be freed by caller.
pub fn serializeFloatArray(allocator: Allocator, values: []const f64) ![]u8 {
    var json_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer json_buf.deinit(allocator);

    try json_buf.append(allocator, '[');
    for (values, 0..) |value, i| {
        if (i > 0) try json_buf.append(allocator, ',');
        try std.fmt.format(json_buf.writer(allocator), "{d}", .{value});
    }
    try json_buf.append(allocator, ']');

    return try allocator.dupe(u8, json_buf.items);
}
