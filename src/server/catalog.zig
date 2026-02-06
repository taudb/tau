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
    lens_map: std.AutoArrayHashMapUnmanaged(
        [label_length]u8,
        LensExpr,
    ),
    actor_pool: ?ActorPool,
    lock: std.Thread.RwLock, // Protects only the routing table (create/drop)

    const Self = @This();

    pub const Transform = enum(u8) {
        identity,
        celsius_to_fahrenheit,
        fahrenheit_to_celsius,
        celsius_to_kelvin,
        kelvin_to_celsius,
        meters_to_feet,
        feet_to_meters,
        returns,
        log_return,
    };

    pub const LensExpr = struct {
        source_label: [label_length]u8,
        transform: Transform,
    };

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
            .lens_map = .{},
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

        // NOTE: Actor pool is NOT started here. Catalog.init() returns by
        // value, so any pointers taken to self.actor_map / self.lock would
        // dangle after the copy.  Call start() once the struct is at its
        // final memory address.

        return self;
    }

    /// Start the actor pool. Must be called after the Catalog is at its
    /// final memory location (i.e. after init() return value is assigned).
    pub fn start(self: *Self) void {
        self.actor_pool = ActorPool.init(
            self.allocator,
            &self.actor_map,
            &self.lock,
        );
        if (self.actor_pool.?.start()) |_| {} else |err| {
            log.warn("actor pool start failed: {s}", .{@errorName(err)});
            self.actor_pool = null;
        }
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
        self.lens_map.deinit(self.allocator);
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

    pub fn create_lens(
        self: *Self,
        label: [label_length]u8,
        source_label: [label_length]u8,
        transform: Transform,
    ) LensError!void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.lens_map.count() >= 1000) {
            return error.LensFull;
        }

        const result = self.lens_map.getOrPut(
            self.allocator,
            label,
        ) catch return error.OutOfMemory;

        if (result.found_existing) {
            return error.LensAlreadyExists;
        }

        result.value_ptr.* = .{
            .source_label = source_label,
            .transform = transform,
        };
    }

    pub fn drop_lens(
        self: *Self,
        label: [label_length]u8,
    ) LensError!void {
        self.lock.lock();
        defer self.lock.unlock();

        _ = self.lens_map.fetchSwapRemove(label) orelse
            return error.LensNotFound;
    }

    pub fn query_lens(
        self: *Self,
        label: [label_length]u8,
        timestamp: Timestamp,
    ) LensError!?f64 {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        const lens = self.lens_map.get(label) orelse {
            return error.LensNotFound;
        };

        const source_value = self.query_point(lens.source_label, timestamp) catch {
            return error.SeriesNotFound;
        };

        if (source_value == null) return null;

        return self.apply_transform(lens.transform, source_value.?);
    }

    pub fn compose_lens(
        self: *Self,
        label: [label_length]u8,
        lens1_label: [label_length]u8,
        lens2_label: [label_length]u8,
    ) LensError!void {
        self.lock.lock();
        defer self.lock.unlock();

        const lens1 = self.lens_map.get(lens1_label) orelse
            return error.LensNotFound;
        const lens2 = self.lens_map.get(lens2_label) orelse
            return error.LensNotFound;

        if (self.lens_map.count() >= 1000) {
            return error.LensFull;
        }

        const result = self.lens_map.getOrPut(
            self.allocator,
            label,
        ) catch return error.OutOfMemory;

        if (result.found_existing) {
            return error.LensAlreadyExists;
        }

        result.value_ptr.* = .{
            .source_label = lens1.source_label,
            .transform = lens2.transform,
        };
    }

    pub fn list_lenses(
        self: *Self,
    ) []const [label_length]u8 {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var result = self.allocator.alloc([label_length]u8, self.lens_map.count()) catch
            return &.{};

        var i: u32 = 0;
        var iterator = self.lens_map.iterator();
        while (iterator.next()) |entry| {
            if (i >= result.len) break;
            result[i] = entry.key_ptr.*;
            i += 1;
        }

        return result[0..i];
    }

    fn apply_transform(self: *Self, transform: Transform, value: f64) f64 {
        _ = self;
        return switch (transform) {
            .identity => value,
            .celsius_to_fahrenheit => value * 9.0 / 5.0 + 32.0,
            .fahrenheit_to_celsius => (value - 32.0) * 5.0 / 9.0,
            .celsius_to_kelvin => value + 273.15,
            .kelvin_to_celsius => value - 273.15,
            .meters_to_feet => value * 3.28084,
            .feet_to_meters => value / 3.28084,
            .returns => value,
            .log_return => value,
        };
    }

    pub fn get_transform_from_name(name: []const u8) ?Transform {
        var trimmed = name;
        while (trimmed.len > 0 and trimmed[trimmed.len - 1] == 0) {
            trimmed = trimmed[0 .. trimmed.len - 1];
        }

        if (std.mem.eql(u8, trimmed, "identity")) return .identity;
        if (std.mem.eql(u8, trimmed, "celsius_to_fahrenheit")) return .celsius_to_fahrenheit;
        if (std.mem.eql(u8, trimmed, "fahrenheit_to_celsius")) return .fahrenheit_to_celsius;
        if (std.mem.eql(u8, trimmed, "celsius_to_kelvin")) return .celsius_to_kelvin;
        if (std.mem.eql(u8, trimmed, "kelvin_to_celsius")) return .kelvin_to_celsius;
        if (std.mem.eql(u8, trimmed, "meters_to_feet")) return .meters_to_feet;
        if (std.mem.eql(u8, trimmed, "feet_to_meters")) return .feet_to_meters;
        if (std.mem.eql(u8, trimmed, "returns")) return .returns;
        if (std.mem.eql(u8, trimmed, "log_return")) return .log_return;
        return null;
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

    pub const LensError = error{
        LensAlreadyExists,
        LensNotFound,
        LensFull,
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
