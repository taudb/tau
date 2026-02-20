//! Actor-based series registry.
//!
//! The catalog maps series labels to their SeriesActor instances.
//! Each actor has its own mailbox, enabling parallel operations
//! across different series without locks on series data.
//!
//! The storage backend is selected at compile time via
//! config.storage.default_backend.

const std = @import("std");
const tau = @import("tau");
const tau_entities = tau.entities;
const tau_config = tau.config;
const file_backend_mod = tau.file_backend;
const actor_mod = @import("actor");

const Timestamp = tau_entities.Timestamp;

pub const label_length: u32 = tau_config.storage.label_length;
pub const series_count_max: u32 = tau_config.server.catalog_capacity;
pub const segment_capacity_default: u32 = tau_config.storage.segment_capacity_default;
pub const backend = tau_config.storage.default_backend;

const Series = tau_entities.Series(f64);
const FileBackend = file_backend_mod.FileBackedSegment(f64);
const SeriesActor = actor_mod.SeriesActor;
const Message = actor_mod.Message;
const ResponseSlot = actor_mod.ResponseSlot;
const ActorPool = actor_mod.ActorPool;
const log = std.log.scoped(.catalog);

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    data_dir: ?std.fs.Dir,
    actor_map: std.AutoArrayHashMapUnmanaged(
        [label_length]u8,
        *SeriesActor,
    ),
    actor_pool: ?ActorPool,
    lock: std.Thread.RwLock, // Protects only the routing table (create/drop)

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
            .actor_map = .{},
            .actor_pool = null,
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

                    const actor = allocator.create(SeriesActor) catch continue;
                    actor.* = SeriesActor.init(allocator, label_buf, dir) catch {
                        allocator.destroy(actor);
                        continue;
                    };
                    self.actor_map.put(allocator, label_buf, actor) catch {
                        actor.deinit();
                        allocator.destroy(actor);
                        continue;
                    };
                }
            }
        }

        // Initialize actor pool
        self.actor_pool = ActorPool.init(
            allocator,
            &self.actor_map,
            &self.lock,
        );
        if (self.actor_pool.?.start()) |_| {} else |err| {
            log.warn("actor pool start failed: {s}", .{@errorName(err)});
            self.actor_pool = null;
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.actor_pool) |*pool| {
            pool.deinit();
        }

        var iterator = self.actor_map.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.actor_map.deinit(self.allocator);
        if (self.data_dir) |*dir| dir.close();
    }

    pub fn create_series(
        self: *Self,
        label: [label_length]u8,
    ) CreateError!void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.actor_map.count() >= series_count_max) {
            return error.CatalogFull;
        }

        const result = self.actor_map.getOrPut(
            self.allocator,
            label,
        ) catch return error.OutOfMemory;

        if (result.found_existing) {
            return error.SeriesAlreadyExists;
        }

        const dir = if (backend == .file) self.data_dir else null;
        const actor = self.allocator.create(SeriesActor) catch
            return error.OutOfMemory;

        actor.* = SeriesActor.init(
            self.allocator,
            label,
            dir,
        ) catch {
            self.allocator.destroy(actor);
            _ = self.actor_map.swapRemove(label);
            return error.OutOfMemory;
        };

        result.value_ptr.* = actor;
    }

    pub fn drop_series(
        self: *Self,
        label: [label_length]u8,
    ) DropError!void {
        self.lock.lock();
        defer self.lock.unlock();

        const entry = self.actor_map.fetchSwapRemove(label) orelse
            return error.SeriesNotFound;

        entry.value.stop();
        entry.value.deinit();
        self.allocator.destroy(entry.value);

        if (backend == .file) {
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
        // Lookup actor (read-only under shared lock).
        self.lock.lockShared();
        defer self.lock.unlockShared();
        const actor = self.actor_map.get(label) orelse {
            return error.SeriesNotFound;
        };

        // Send message to actor
        var response_slot = ResponseSlot.init();
        const message = Message{ .append = .{
            .timestamp = timestamp,
            .value = value,
            .response = &response_slot,
        } };

        // Try to send (non-blocking)
        if (!actor.mailbox.try_send(message)) {
            return error.OutOfMemory; // Mailbox full
        }

        // Process message immediately if actor pool not ready.
        if (self.actor_pool == null) {
            while (!response_slot.is_ready()) {
                _ = actor.process_one();
                std.Thread.yield() catch {};
            }
        }

        // Wait for response
        const result = response_slot.wait() catch |err| {
            return switch (err) {
                error.OutOfOrder => error.OutOfOrder,
                else => error.OutOfMemory,
            };
        };
        _ = result; // Append returns void on success
    }

    pub fn query_point(
        self: *Self,
        label: [label_length]u8,
        timestamp: Timestamp,
    ) QueryError!?f64 {
        // Lookup actor (read-only under shared lock).
        self.lock.lockShared();
        defer self.lock.unlockShared();
        const actor = self.actor_map.get(label) orelse {
            return error.SeriesNotFound;
        };

        // Send message to actor
        var response_slot = ResponseSlot.init();
        const message = Message{ .query_point = .{
            .timestamp = timestamp,
            .response = &response_slot,
        } };

        // Try to send (non-blocking)
        if (!actor.mailbox.try_send(message)) {
            return error.OutOfMemory; // Mailbox full
        }

        // Process message immediately if actor pool not ready.
        if (self.actor_pool == null) {
            while (!response_slot.is_ready()) {
                _ = actor.process_one();
                std.Thread.yield() catch {};
            }
        }

        // Wait for response
        return response_slot.wait() catch |err| {
            return switch (err) {
                error.SeriesNotFound => error.SeriesNotFound,
                else => error.OutOfMemory,
            };
        };
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
        OutOfMemory,
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
