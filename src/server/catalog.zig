//! Thread-safe series registry.
//!
//! The catalog maps series labels to their Series instances.
//! It uses a RwLock so that multiple readers (point queries)
//! can proceed concurrently while writes (create, drop, append)
//! take exclusive access.

const std = @import("std");
const tau_entities = @import("tau").entities;

const Series = tau_entities.Series(f64);
const Timestamp = tau_entities.Timestamp;

pub const label_length: u32 = 32;
pub const series_count_max: u32 = 4096;
pub const segment_capacity_default: u32 = 65536;

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    series_map: std.AutoArrayHashMapUnmanaged(
        [label_length]u8,
        *Series,
    ),
    lock: std.Thread.RwLock,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .series_map = .{},
            .lock = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.series_map.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.series_map.deinit(self.allocator);
    }

    pub fn create_series(
        self: *Self,
        label: [label_length]u8,
    ) CreateError!void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.series_map.count() >= series_count_max) {
            return error.CatalogFull;
        }

        const result = self.series_map.getOrPut(
            self.allocator,
            label,
        ) catch return error.OutOfMemory;

        if (result.found_existing) {
            return error.SeriesAlreadyExists;
        }

        const series = self.allocator.create(Series) catch
            return error.OutOfMemory;
        series.* = Series.init(
            self.allocator,
            label,
            segment_capacity_default,
        );
        result.value_ptr.* = series;
    }

    pub fn drop_series(
        self: *Self,
        label: [label_length]u8,
    ) DropError!void {
        self.lock.lock();
        defer self.lock.unlock();

        const entry = self.series_map.fetchSwapRemove(label) orelse
            return error.SeriesNotFound;

        entry.value.deinit();
        self.allocator.destroy(entry.value);
    }

    pub fn append(
        self: *Self,
        label: [label_length]u8,
        timestamp: Timestamp,
        value: f64,
    ) AppendError!void {
        self.lock.lock();
        defer self.lock.unlock();

        const series = self.series_map.get(label) orelse
            return error.SeriesNotFound;

        series.append(timestamp, value) catch |append_error| {
            return switch (append_error) {
                error.OutOfOrder => error.OutOfOrder,
                else => error.OutOfMemory,
            };
        };
    }

    pub fn query_point(
        self: *Self,
        label: [label_length]u8,
        timestamp: Timestamp,
    ) QueryError!?f64 {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        const series = self.series_map.get(label) orelse
            return error.SeriesNotFound;

        return series.at(timestamp);
    }

    pub const CreateError = error{
        SeriesAlreadyExists,
        CatalogFull,
        OutOfMemory,
    };

    pub const DropError = error{
        SeriesNotFound,
    };

    pub const AppendError = error{
        SeriesNotFound,
        OutOfOrder,
        OutOfMemory,
    };

    pub const QueryError = error{
        SeriesNotFound,
    };
};

const testing = std.testing;

fn make_label(name: []const u8) [label_length]u8 {
    var label = [_]u8{0} ** label_length;
    const length = @min(name.len, label_length);
    @memcpy(label[0..length], name[0..length]);
    return label;
}

test "Catalog.create_series and query_point" {
    var catalog = Catalog.init(testing.allocator);
    defer catalog.deinit();

    const label = make_label("temperature");
    try catalog.create_series(label);
    try catalog.append(label, 1, 22.5);

    const value = try catalog.query_point(label, 1);
    try testing.expectApproxEqAbs(
        @as(f64, 22.5),
        value.?,
        1e-10,
    );
}

test "Catalog.create_series rejects duplicate" {
    var catalog = Catalog.init(testing.allocator);
    defer catalog.deinit();

    const label = make_label("pressure");
    try catalog.create_series(label);
    try testing.expectError(
        error.SeriesAlreadyExists,
        catalog.create_series(label),
    );
}

test "Catalog.drop_series removes series" {
    var catalog = Catalog.init(testing.allocator);
    defer catalog.deinit();

    const label = make_label("humidity");
    try catalog.create_series(label);
    try catalog.drop_series(label);
    try testing.expectError(
        error.SeriesNotFound,
        catalog.query_point(label, 0),
    );
}

test "Catalog.drop_series rejects unknown label" {
    var catalog = Catalog.init(testing.allocator);
    defer catalog.deinit();

    try testing.expectError(
        error.SeriesNotFound,
        catalog.drop_series(make_label("nope")),
    );
}

test "Catalog.append rejects unknown label" {
    var catalog = Catalog.init(testing.allocator);
    defer catalog.deinit();

    try testing.expectError(
        error.SeriesNotFound,
        catalog.append(make_label("nope"), 1, 1.0),
    );
}

test "Catalog.query_point returns null for missing timestamp" {
    var catalog = Catalog.init(testing.allocator);
    defer catalog.deinit();

    const label = make_label("voltage");
    try catalog.create_series(label);
    try catalog.append(label, 10, 3.3);

    const value = try catalog.query_point(label, 99);
    try testing.expectEqual(@as(?f64, null), value);
}
