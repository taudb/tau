//! Core entities: TimeDomain, Series (partial function), Lens (morphism).

const std = @import("std");
const storage = @import("storage.zig");

pub const Timestamp = i64;

pub const TimeDomain = struct {
    start: Timestamp,
    end: Timestamp,

    pub fn empty() TimeDomain {
        return .{ .start = 1, .end = 0 };
    }

    pub fn is_empty(self: TimeDomain) bool {
        return self.start > self.end;
    }

    pub fn span(self: TimeDomain) ?i64 {
        if (self.is_empty()) return null;
        return self.end - self.start;
    }
};

pub fn Series(comptime T: type) type {
    return struct {
        label: [32]u8,
        domain: TimeDomain,
        allocator: std.mem.Allocator,
        segment_capacity: u32,
        segments: std.ArrayListUnmanaged(SegmentType),

        const Self = @This();
        const SegmentType = storage.Segment(T);

        pub fn init(
            allocator: std.mem.Allocator,
            label: [32]u8,
            segment_capacity: u32,
        ) Self {
            std.debug.assert(segment_capacity > 0);
            std.debug.assert(
                segment_capacity <= storage.segment_capacity_max,
            );

            return .{
                .label = label,
                .domain = TimeDomain.empty(),
                .allocator = allocator,
                .segment_capacity = segment_capacity,
                .segments = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.segments.items) |*segment| {
                segment.deinit();
            }
            self.segments.deinit(self.allocator);
        }

        /// Append a timestamp-value pair. Timestamps must be strictly
        /// monotonically increasing across the entire series.
        pub fn append(
            self: *Self,
            timestamp: Timestamp,
            value: T,
        ) !void {
            const need_new_segment =
                self.segments.items.len == 0 or
                self.last_segment().is_full();

            if (need_new_segment) {
                const segment = try SegmentType.init(
                    self.allocator,
                    self.segment_capacity,
                );
                try self.segments.append(self.allocator, segment);
            }

            const last = self.last_segment_mut();
            try last.append(timestamp, value);

            if (self.domain.is_empty()) {
                self.domain = .{
                    .start = timestamp,
                    .end = timestamp,
                };
            } else {
                if (timestamp > self.domain.end) {
                    self.domain.end = timestamp;
                }
            }

            std.debug.assert(!self.domain.is_empty());
        }

        /// Point lookup: returns the value at the given timestamp,
        /// or null if no observation exists there.
        pub fn at(self: *const Self, timestamp: Timestamp) ?T {
            if (self.domain.is_empty()) return null;

            if (timestamp < self.domain.start) return null;
            if (timestamp > self.domain.end) return null;

            for (self.segments.items) |*segment| {
                if (!segment.contains(timestamp)) continue;
                if (segment.at(timestamp)) |value| return value;
            }
            return null;
        }

        pub fn count(self: *const Self) u32 {
            var total: u32 = 0;
            for (self.segments.items) |*segment| {
                total += segment.count;
            }
            return total;
        }

        pub fn segment_count(self: *const Self) u32 {
            return @intCast(self.segments.items.len);
        }

        fn last_segment(self: *const Self) *const SegmentType {
            std.debug.assert(self.segments.items.len > 0);
            return &self.segments.items[
                self.segments.items.len - 1
            ];
        }

        fn last_segment_mut(self: *Self) *SegmentType {
            std.debug.assert(self.segments.items.len > 0);
            return &self.segments.items[
                self.segments.items.len - 1
            ];
        }
    };
}

pub fn Lens(comptime Out: type) type {
    return struct {
        context: *const anyopaque,
        at_function: *const fn (
            *const anyopaque,
            Timestamp,
        ) ?Out,

        const Self = @This();

        pub fn init(
            comptime In: type,
            source: *const Series(In),
            comptime transform: *const fn (In) Out,
        ) Self {
            const Adapter = struct {
                fn at(
                    context: *const anyopaque,
                    timestamp: Timestamp,
                ) ?Out {
                    const series: *const Series(In) =
                        @ptrCast(@alignCast(context));
                    const value = series.at(timestamp) orelse
                        return null;
                    return transform(value);
                }
            };
            return Self{
                .context = @ptrCast(source),
                .at_function = Adapter.at,
            };
        }

        pub fn at(self: Self, timestamp: Timestamp) ?Out {
            return self.at_function(self.context, timestamp);
        }

        /// Compose this lens with a second transform, producing
        /// a new lens from the original source type to NewOut.
        pub fn compose(
            self: *const Self,
            comptime NewOut: type,
            comptime new_transform: *const fn (Out) NewOut,
        ) Lens(NewOut) {
            const Adapter = struct {
                fn at(
                    context: *const anyopaque,
                    timestamp: Timestamp,
                ) ?NewOut {
                    const parent: *const Self =
                        @ptrCast(@alignCast(context));
                    const intermediate =
                        parent.at(timestamp) orelse return null;
                    return new_transform(intermediate);
                }
            };
            return Lens(NewOut){
                .context = @ptrCast(self),
                .at_function = Adapter.at,
            };
        }
    };
}

const testing = std.testing;

const blank_label: [32]u8 = [_]u8{0} ** 32;

// TimeDomain tests.

test "TimeDomain.empty is empty" {
    const domain = TimeDomain.empty();
    try testing.expect(domain.is_empty());
    try testing.expectEqual(@as(?i64, null), domain.span());
}

test "TimeDomain stores start and end" {
    const domain = TimeDomain{
        .start = -1000,
        .end = 1000,
    };
    try testing.expectEqual(@as(Timestamp, -1000), domain.start);
    try testing.expectEqual(@as(Timestamp, 1000), domain.end);
    try testing.expect(!domain.is_empty());
    try testing.expectEqual(@as(?i64, 2000), domain.span());
}

// Series tests.

test "Series.at returns value for stored timestamp" {
    var series = Series(u16).init(
        testing.allocator,
        blank_label,
        64,
    );
    defer series.deinit();

    try series.append(1, 10);
    try series.append(5, 20);
    try series.append(9, 30);

    try testing.expectEqual(@as(?u16, 10), series.at(1));
    try testing.expectEqual(@as(?u16, 20), series.at(5));
    try testing.expectEqual(@as(?u16, 30), series.at(9));
}

test "Series.at returns null for unstored timestamp" {
    var series = Series(u16).init(
        testing.allocator,
        blank_label,
        64,
    );
    defer series.deinit();

    try series.append(5, 42);

    try testing.expectEqual(@as(?u16, null), series.at(0));
    try testing.expectEqual(@as(?u16, null), series.at(3));
    try testing.expectEqual(@as(?u16, null), series.at(99));
}

test "Series.at returns null on empty series" {
    var series = Series(u16).init(
        testing.allocator,
        blank_label,
        64,
    );
    defer series.deinit();

    try testing.expectEqual(@as(?u16, null), series.at(0));
}

test "Series.at with negative timestamps" {
    var series = Series(u16).init(
        testing.allocator,
        blank_label,
        64,
    );
    defer series.deinit();

    try series.append(-100, 1);
    try series.append(-1, 2);

    try testing.expectEqual(@as(?u16, 1), series.at(-100));
    try testing.expectEqual(@as(?u16, 2), series.at(-1));
    try testing.expectEqual(@as(?u16, null), series.at(0));
}

test "Series works with f64 values" {
    var series = Series(f64).init(
        testing.allocator,
        blank_label,
        64,
    );
    defer series.deinit();

    try series.append(10, 3.14);
    try series.append(20, 2.71);

    try testing.expectApproxEqAbs(
        @as(f64, 3.14),
        series.at(10).?,
        1e-10,
    );
    try testing.expectEqual(@as(?f64, null), series.at(15));
}

test "Series domain updates on append" {
    var series = Series(u16).init(
        testing.allocator,
        blank_label,
        64,
    );
    defer series.deinit();

    try testing.expect(series.domain.is_empty());

    try series.append(5, 50);
    try testing.expectEqual(@as(Timestamp, 5), series.domain.start);
    try testing.expectEqual(@as(Timestamp, 5), series.domain.end);

    try series.append(10, 100);
    try testing.expectEqual(@as(Timestamp, 5), series.domain.start);
    try testing.expectEqual(@as(Timestamp, 10), series.domain.end);
}

test "Series spans multiple segments" {
    var series = Series(u16).init(
        testing.allocator,
        blank_label,
        2,
    );
    defer series.deinit();

    try series.append(1, 10);
    try series.append(2, 20);
    try series.append(3, 30);
    try series.append(4, 40);

    try testing.expectEqual(@as(u32, 2), series.segment_count());
    try testing.expectEqual(@as(u32, 4), series.count());
    try testing.expectEqual(@as(?u16, 10), series.at(1));
    try testing.expectEqual(@as(?u16, 30), series.at(3));
    try testing.expectEqual(@as(?u16, 40), series.at(4));
}

test "Series.append rejects out-of-order timestamps" {
    var series = Series(u16).init(
        testing.allocator,
        blank_label,
        64,
    );
    defer series.deinit();

    try series.append(10, 100);
    try testing.expectError(
        error.OutOfOrder,
        series.append(5, 50),
    );
    try testing.expectError(
        error.OutOfOrder,
        series.append(10, 200),
    );
}

// Lens tests.

fn double(input: u16) u32 {
    return @as(u32, input) * 2;
}

fn identity(input: u16) u16 {
    return input;
}

test "Lens.at applies transform to stored value" {
    var series = Series(u16).init(
        testing.allocator,
        blank_label,
        64,
    );
    defer series.deinit();

    try series.append(1, 5);
    try series.append(2, 10);

    const lens = Lens(u32).init(u16, &series, double);
    try testing.expectEqual(@as(u32, 10), lens.at(1).?);
    try testing.expectEqual(@as(u32, 20), lens.at(2).?);
}

test "Lens.at returns null for unstored timestamp" {
    var series = Series(u16).init(
        testing.allocator,
        blank_label,
        64,
    );
    defer series.deinit();

    try series.append(1, 5);

    const lens = Lens(u32).init(u16, &series, double);
    try testing.expectEqual(@as(?u32, null), lens.at(0));
    try testing.expectEqual(@as(?u32, null), lens.at(99));
}

test "Lens with identity returns original values" {
    var series = Series(u16).init(
        testing.allocator,
        blank_label,
        64,
    );
    defer series.deinit();

    try series.append(3, 7);
    try series.append(6, 42);

    const lens = Lens(u16).init(u16, &series, identity);
    try testing.expectEqual(series.at(3).?, lens.at(3).?);
    try testing.expectEqual(series.at(6).?, lens.at(6).?);
    try testing.expectEqual(@as(?u16, null), lens.at(0));
}

test "Lens reflects mutation in underlying data" {
    var series = Series(u16).init(
        testing.allocator,
        blank_label,
        64,
    );
    defer series.deinit();

    try series.append(1, 100);
    try series.append(2, 200);

    const lens = Lens(u32).init(u16, &series, double);
    try testing.expectEqual(@as(u32, 200), lens.at(1).?);

    series.segments.items[0].values[0] = 500;
    try testing.expectEqual(@as(u32, 1000), lens.at(1).?);
}

// Lens.compose tests.

fn increment_u64(input: u32) u64 {
    return @as(u64, input) + 1;
}

test "Lens.compose chains transforms" {
    var series = Series(u16).init(
        testing.allocator,
        blank_label,
        64,
    );
    defer series.deinit();

    try series.append(1, 5);
    try series.append(2, 10);

    const lens = Lens(u32).init(u16, &series, double);
    const composed = lens.compose(u64, increment_u64);

    // double(5) = 10, increment_u64(10) = 11.
    try testing.expectEqual(@as(u64, 11), composed.at(1).?);
    // double(10) = 20, increment_u64(20) = 21.
    try testing.expectEqual(@as(u64, 21), composed.at(2).?);
}

test "Lens.compose returns null for missing timestamp" {
    var series = Series(u16).init(
        testing.allocator,
        blank_label,
        64,
    );
    defer series.deinit();

    try series.append(1, 5);

    const lens = Lens(u32).init(u16, &series, double);
    const composed = lens.compose(u64, increment_u64);
    try testing.expectEqual(
        @as(?u64, null),
        composed.at(99),
    );
}

test "Lens.compose reflects mutation in underlying data" {
    var series = Series(u16).init(
        testing.allocator,
        blank_label,
        64,
    );
    defer series.deinit();

    try series.append(1, 5);

    const lens = Lens(u32).init(u16, &series, double);
    const composed = lens.compose(u64, increment_u64);

    // double(5) = 10, increment_u64(10) = 11.
    try testing.expectEqual(@as(u64, 11), composed.at(1).?);

    series.segments.items[0].values[0] = 100;

    // double(100) = 200, increment_u64(200) = 201.
    try testing.expectEqual(@as(u64, 201), composed.at(1).?);
}
