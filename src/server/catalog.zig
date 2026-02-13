//! Thread-safe series registry.
//!
//! The catalog maps series labels to their Series instances.
//! It uses a RwLock so that multiple readers (point queries)
//! can proceed concurrently while writes (create, drop, append)
//! take exclusive access.
//!
//! The storage backend is selected at compile time via
//! config.storage.default_backend.

const std = @import("std");
const tau = @import("tau");
const tau_entities = tau.entities;
const tau_config = tau.config;
const file_backend_mod = tau.file_backend;

const Timestamp = tau_entities.Timestamp;

pub const label_length: u32 = tau_config.storage.label_length;
pub const series_count_max: u32 = tau_config.server.catalog_capacity;
pub const segment_capacity_default: u32 = tau_config.storage.segment_capacity_default;
pub const backend = tau_config.storage.default_backend;

const Series = tau_entities.Series(f64);
const FileBackend = file_backend_mod.FileBackedSegment(f64);

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    data_dir: ?std.fs.Dir,
    series_map: std.AutoArrayHashMapUnmanaged(
        [label_length]u8,
        *Series,
    ),
    file_backend_map: std.AutoArrayHashMapUnmanaged(
        [label_length]u8,
        *FileBackend,
    ),
    lock: std.Thread.RwLock,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        var data_dir: ?std.fs.Dir = null;
        if (backend == .file) {
            data_dir = std.fs.cwd().makeOpenPath(
                tau_config.storage.data_dir,
                .{ .iterate = true },
            ) catch null;
        }

        var self = Self{
            .allocator = allocator,
            .data_dir = data_dir,
            .series_map = .{},
            .file_backend_map = .{},
            .lock = .{},
        };

        // Load existing file backend files from data directory.
        if (backend == .file) {
            if (data_dir) |dir| {
                var iter = dir.iterate();
                while (iter.next() catch null) |entry| {
                    if (entry.kind != .file) continue;
                    const name = entry.name;
                    if (name.len <= 4) continue;
                    if (!std.mem.endsWith(u8, name, ".tau")) continue;

                    const base_len = name.len - 4;
                    var label_buf: [label_length]u8 = [_]u8{0} ** label_length;
                    const copy_len = @min(base_len, label_length);
                    @memcpy(label_buf[0..copy_len], name[0..copy_len]);

                    const fb = allocator.create(FileBackend) catch continue;
                    fb.* = FileBackend.init(allocator, dir, label_buf, segment_capacity_default) catch {
                        allocator.destroy(fb);
                        continue;
                    };
                    self.file_backend_map.put(allocator, label_buf, fb) catch {
                        fb.deinit();
                        allocator.destroy(fb);
                        continue;
                    };
                }
            }
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (backend == .segment) {
            var iterator = self.series_map.iterator();
            while (iterator.next()) |entry| {
                entry.value_ptr.*.deinit();
                self.allocator.destroy(entry.value_ptr.*);
            }
            self.series_map.deinit(self.allocator);
        }
        if (backend == .file) {
            var iterator = self.file_backend_map.iterator();
            while (iterator.next()) |entry| {
                entry.value_ptr.*.deinit();
                self.allocator.destroy(entry.value_ptr.*);
            }
            self.file_backend_map.deinit(self.allocator);
            if (self.data_dir) |*dir| dir.close();
        }
    }

    pub fn create_series(
        self: *Self,
        label: [label_length]u8,
    ) CreateError!void {
        self.lock.lock();
        defer self.lock.unlock();

        if (backend == .segment) {
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

            const series = self.allocator.create(
                Series,
            ) catch return error.OutOfMemory;

            series.* = Series.init(
                self.allocator,
                label,
                segment_capacity_default,
            );
            result.value_ptr.* = series;
        }
        if (backend == .file) {
            if (self.file_backend_map.count() >= series_count_max) {
                return error.CatalogFull;
            }

            const result = self.file_backend_map.getOrPut(
                self.allocator,
                label,
            ) catch return error.OutOfMemory;

            if (result.found_existing) {
                return error.SeriesAlreadyExists;
            }

            const dir = self.data_dir orelse
                return error.OutOfMemory;

            const fb = self.allocator.create(
                FileBackend,
            ) catch return error.OutOfMemory;

            fb.* = FileBackend.init(
                self.allocator,
                dir,
                label,
                segment_capacity_default,
            ) catch {
                self.allocator.destroy(fb);
                _ = self.file_backend_map.swapRemove(label);
                return error.OutOfMemory;
            };
            result.value_ptr.* = fb;
        }
    }

    pub fn drop_series(
        self: *Self,
        label: [label_length]u8,
    ) DropError!void {
        self.lock.lock();
        defer self.lock.unlock();

        if (backend == .segment) {
            const entry = self.series_map.fetchSwapRemove(
                label,
            ) orelse return error.SeriesNotFound;
            entry.value.deinit();
            self.allocator.destroy(entry.value);
        }
        if (backend == .file) {
            const entry = self.file_backend_map.fetchSwapRemove(
                label,
            ) orelse return error.SeriesNotFound;
            entry.value.deinit();
            self.allocator.destroy(entry.value);
            if (self.data_dir) |*dir| {
                const filename = FileBackend.derive_filename(label);
                dir.deleteFile(filename.slice()) catch {};
            }
        }
    }

    pub fn append(
        self: *Self,
        label: [label_length]u8,
        timestamp: Timestamp,
        value: f64,
    ) AppendError!void {
        self.lock.lock();
        defer self.lock.unlock();

        if (backend == .segment) {
            const series = self.series_map.get(label) orelse
                return error.SeriesNotFound;
            series.append(timestamp, value) catch |err| {
                return switch (err) {
                    error.OutOfOrder => error.OutOfOrder,
                    else => error.OutOfMemory,
                };
            };
        }
        if (backend == .file) {
            const fb = self.file_backend_map.get(label) orelse
                return error.SeriesNotFound;
            fb.append(timestamp, value) catch |err| {
                return switch (err) {
                    error.OutOfOrder => error.OutOfOrder,
                    error.SegmentFull => error.OutOfMemory,
                    else => error.OutOfMemory,
                };
            };
        }
    }

    pub fn query_point(
        self: *Self,
        label: [label_length]u8,
        timestamp: Timestamp,
    ) QueryError!?f64 {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        if (backend == .segment) {
            const series = self.series_map.get(label) orelse
                return error.SeriesNotFound;
            return series.at(timestamp);
        }
        if (backend == .file) {
            const fb = self.file_backend_map.get(label) orelse
                return error.SeriesNotFound;
            return fb.at(timestamp);
        }
        return error.SeriesNotFound;
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

test "Catalog uses configured backend" {
    try testing.expect(
        backend == .segment or backend == .file,
    );
}

test "Catalog persists and reloads file_backend data across restart" {
    if (backend != .file) return;

    // Use a unique test directory.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Test the file backend directly for restart safety.
    const label = make_label("restart_test");
    const FileBackendF64 = file_backend_mod.FileBackedSegment(f64);

    {
        var fb = try FileBackendF64.init(testing.allocator, tmp.dir, label, 1024);
        try fb.append(10, 1.5);
        try fb.append(20, 2.5);
        try fb.append(30, 3.5);
        fb.deinit();
    }

    {
        var fb = try FileBackendF64.init(testing.allocator, tmp.dir, label, 1024);
        defer fb.deinit();

        try testing.expectEqual(@as(u32, 3), fb.count);
        try testing.expectApproxEqAbs(@as(f64, 1.5), fb.at(10).?, 1e-10);
        try testing.expectApproxEqAbs(@as(f64, 2.5), fb.at(20).?, 1e-10);
        try testing.expectApproxEqAbs(@as(f64, 3.5), fb.at(30).?, 1e-10);
    }
}
