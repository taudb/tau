//! Columnar segment storage backing for Series.

const std = @import("std");
const entities = @import("entities.zig");
const Timestamp = entities.Timestamp;

/// Maximum number of points a single segment may hold.
pub const segment_capacity_max: u32 = 1 << 20;

pub fn Segment(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        times: []Timestamp,
        values: []T,
        count: u32,

        const Self = @This();

        pub fn init(
            allocator: std.mem.Allocator,
            point_count_max: u32,
        ) !Self {
            std.debug.assert(point_count_max > 0);
            std.debug.assert(point_count_max <= segment_capacity_max);

            const length: usize = @intCast(point_count_max);

            return .{
                .allocator = allocator,
                .times = try allocator.alloc(Timestamp, length),
                .values = try allocator.alloc(T, length),
                .count = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(self.count <= self.capacity());

            self.allocator.free(self.times);
            self.allocator.free(self.values);
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) u32 {
            return @intCast(self.times.len);
        }

        pub fn is_full(self: *const Self) bool {
            return self.count >= self.capacity();
        }

        /// Append a timestamp-value pair. Timestamps must be strictly
        /// monotonically increasing within a segment.
        pub fn append(self: *Self, timestamp: Timestamp, value: T) !void {
            std.debug.assert(self.count <= self.capacity());

            if (self.count >= self.capacity()) {
                return error.SegmentFull;
            }

            if (self.count > 0) {
                if (timestamp <= self.times[self.count - 1]) {
                    return error.OutOfOrder;
                }
            }

            const index: usize = @intCast(self.count);
            self.times[index] = timestamp;
            self.values[index] = value;
            self.count += 1;

            std.debug.assert(self.count <= self.capacity());
        }

        pub fn min_timestamp(self: *const Self) ?Timestamp {
            if (self.count == 0) return null;
            return self.times[0];
        }

        pub fn max_timestamp(self: *const Self) ?Timestamp {
            if (self.count == 0) return null;
            return self.times[self.count - 1];
        }

        pub fn contains(self: *const Self, timestamp: Timestamp) bool {
            const lower = self.min_timestamp() orelse return false;
            const upper = self.max_timestamp() orelse return false;
            return timestamp >= lower and timestamp <= upper;
        }

        /// Point lookup via binary search over the timestamp column.
        pub fn at(self: *const Self, timestamp: Timestamp) ?T {
            std.debug.assert(self.count <= self.capacity());

            if (!self.contains(timestamp)) return null;

            var lower: u32 = 0;
            var upper: u32 = self.count;
            while (lower < upper) {
                const middle = lower + (upper - lower) / 2;
                const middle_timestamp = self.times[middle];
                if (middle_timestamp == timestamp) {
                    return self.values[middle];
                }
                if (middle_timestamp < timestamp) {
                    lower = middle + 1;
                } else {
                    upper = middle;
                }
            }
            return null;
        }
    };
}

// --- Tests. ---

const testing = std.testing;

test "Segment.init creates empty segment" {
    var segment = try Segment(u16).init(testing.allocator, 8);
    defer segment.deinit();

    try testing.expectEqual(@as(u32, 0), segment.count);
    try testing.expectEqual(@as(u32, 8), segment.capacity());
    try testing.expect(!segment.is_full());
}

test "Segment.append stores timestamp-value pairs" {
    var segment = try Segment(u16).init(testing.allocator, 4);
    defer segment.deinit();

    try segment.append(10, 100);
    try segment.append(20, 200);

    try testing.expectEqual(@as(u32, 2), segment.count);
    try testing.expectEqual(@as(?u16, 100), segment.at(10));
    try testing.expectEqual(@as(?u16, 200), segment.at(20));
}

test "Segment.append rejects out-of-order timestamps" {
    var segment = try Segment(u16).init(testing.allocator, 4);
    defer segment.deinit();

    try segment.append(10, 100);
    try testing.expectError(error.OutOfOrder, segment.append(10, 200));
    try testing.expectError(error.OutOfOrder, segment.append(5, 50));
}

test "Segment.append rejects when full" {
    var segment = try Segment(u16).init(testing.allocator, 2);
    defer segment.deinit();

    try segment.append(1, 10);
    try segment.append(2, 20);
    try testing.expect(segment.is_full());
    try testing.expectError(
        error.SegmentFull,
        segment.append(3, 30),
    );
}

test "Segment.at returns null for missing timestamp" {
    var segment = try Segment(u16).init(testing.allocator, 4);
    defer segment.deinit();

    try segment.append(1, 10);
    try segment.append(5, 50);
    try segment.append(9, 90);

    try testing.expectEqual(@as(?u16, null), segment.at(0));
    try testing.expectEqual(@as(?u16, null), segment.at(3));
    try testing.expectEqual(@as(?u16, null), segment.at(10));
}

test "Segment.at returns null on empty segment" {
    var segment = try Segment(u16).init(testing.allocator, 4);
    defer segment.deinit();

    try testing.expectEqual(@as(?u16, null), segment.at(0));
}

test "Segment.contains checks timestamp range" {
    var segment = try Segment(u16).init(testing.allocator, 4);
    defer segment.deinit();

    try testing.expect(!segment.contains(0));

    try segment.append(5, 50);
    try segment.append(10, 100);

    try testing.expect(!segment.contains(4));
    try testing.expect(segment.contains(5));
    try testing.expect(segment.contains(7));
    try testing.expect(segment.contains(10));
    try testing.expect(!segment.contains(11));
}

test "Segment.min_timestamp and max_timestamp" {
    var segment = try Segment(u16).init(testing.allocator, 4);
    defer segment.deinit();

    try testing.expectEqual(
        @as(?Timestamp, null),
        segment.min_timestamp(),
    );
    try testing.expectEqual(
        @as(?Timestamp, null),
        segment.max_timestamp(),
    );

    try segment.append(3, 30);
    try segment.append(7, 70);

    try testing.expectEqual(
        @as(?Timestamp, 3),
        segment.min_timestamp(),
    );
    try testing.expectEqual(
        @as(?Timestamp, 7),
        segment.max_timestamp(),
    );
}

test "Segment works with f64 values" {
    var segment = try Segment(f64).init(testing.allocator, 4);
    defer segment.deinit();

    try segment.append(10, 3.14);
    try segment.append(20, 2.71);

    try testing.expectApproxEqAbs(
        @as(f64, 3.14),
        segment.at(10).?,
        1e-10,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 2.71),
        segment.at(20).?,
        1e-10,
    );
    try testing.expectEqual(@as(?f64, null), segment.at(15));
}

test "Segment binary search at boundaries" {
    var segment = try Segment(u16).init(testing.allocator, 8);
    defer segment.deinit();

    try segment.append(1, 10);
    try segment.append(3, 30);
    try segment.append(5, 50);
    try segment.append(7, 70);
    try segment.append(9, 90);

    try testing.expectEqual(@as(?u16, 10), segment.at(1));
    try testing.expectEqual(@as(?u16, 90), segment.at(9));
    try testing.expectEqual(@as(?u16, 50), segment.at(5));
    try testing.expectEqual(@as(?u16, null), segment.at(2));
    try testing.expectEqual(@as(?u16, null), segment.at(8));
}
