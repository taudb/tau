//! A module defining the Frame structure, which encapsulates a collection of schedules.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const primitives = @import("mod.zig");
const Schedule = primitives.Schedule;
const ULID = @import("ulid").ULID;

/// A frame represents a collection of schedules identified by a unique id.
pub const Frame = struct {
    id: []const u8, // Unique identifier (ULID string)
    schedules: []Schedule,

    pub fn deinit(self: Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        for (self.schedules) |s| {
            s.deinit(allocator);
        }
        allocator.free(self.schedules);
    }

    /// Creates a new Frame with auto-generated ID and copies of the provided schedules
    pub fn create(allocator: Allocator, schedules: []const Schedule) !Frame {
        assert(schedules.len > 0); // There should be at least one schedule

        const ulid = try ULID.create();
        const id = try allocator.dupe(u8, ulid.toString());
        var frame_schedules = try allocator.alloc(Schedule, schedules.len);
        errdefer allocator.free(frame_schedules);

        for (schedules, 0..) |schedule, i| {
            const schedule_copy = try Schedule.create(allocator, schedule.name, schedule.taus);
            frame_schedules[i] = schedule_copy;
        }

        const frame = Frame{
            .id = id,
            .schedules = frame_schedules,
        };

        assert(frame.schedules.len > 0);
        return frame;
    }

    /// Append-only: Add new schedules to the frame
    pub fn addSchedules(self: *Frame, allocator: Allocator, new_schedules: []const Schedule) !void {
        assert(new_schedules.len > 0); // There should be at least one new schedule to add
        assert(self.schedules.len > 0); // Frame must have existing schedules

        // Create new array with expanded capacity
        const old_len = self.schedules.len;
        const new_len = old_len + new_schedules.len;
        var expanded_schedules = try allocator.realloc(self.schedules, new_len);

        // Copy new schedules with deep copy
        for (new_schedules, 0..) |new_schedule, i| {
            const schedule_copy = try Schedule.create(allocator, new_schedule.name, new_schedule.taus);
            expanded_schedules[old_len + i] = schedule_copy;
        }

        self.schedules = expanded_schedules;
        assert(self.schedules.len == new_len);
        assert(self.schedules.len > old_len);
        assert(self.schedules.len > 0);
    }

    /// Serializes a Frame into a binary format.
    pub fn serialize(self: Frame, allocator: std.mem.Allocator) ![]u8 {
        var buffer: [8192]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        var bw = stream.writer();

        // Write ID as length-prefixed string (same as Schedule)
        try bw.writeInt(u32, @intCast(self.id.len), .big);
        try bw.writeAll(self.id);

        // Write schedules count
        try bw.writeInt(u32, @intCast(self.schedules.len), .big);

        // Serialize each schedule
        for (self.schedules) |schedule| {
            const schedule_bytes = try schedule.serialize(allocator);
            defer allocator.free(schedule_bytes);
            try bw.writeInt(u32, @intCast(schedule_bytes.len), .big);
            try bw.writeAll(schedule_bytes);
        }

        const written = stream.getWritten();
        const result = try allocator.dupe(u8, written);
        return result;
    }

    /// Deserializes a Frame from a binary format.
    pub fn deserialize(self: *Frame, allocator: std.mem.Allocator, data: []const u8) !void {
        assert(data.len >= 16 + 4); // Minimum size check

        const mutable_data = try allocator.dupe(u8, data);
        defer allocator.free(mutable_data);

        var stream = std.io.fixedBufferStream(mutable_data);
        var br = stream.reader();

        // Read ID as length-prefixed string (same as Schedule)
        const id_len = try br.readInt(u32, .big);
        const id = try allocator.alloc(u8, id_len);
        errdefer allocator.free(id);
        try br.readNoEof(id);

        // Read schedules count
        const schedules_count = try br.readInt(u32, .big);

        // Read and deserialize each schedule
        var schedules = try allocator.alloc(Schedule, schedules_count);
        errdefer {
            for (schedules) |s| s.deinit(allocator);
            allocator.free(schedules);
        }

        for (0..schedules_count) |i| {
            const schedule_bytes_len = try br.readInt(u32, .big);
            const schedule_bytes = try allocator.alloc(u8, schedule_bytes_len);
            defer allocator.free(schedule_bytes);
            try br.readNoEof(schedule_bytes);
            schedules[i] = .{
                .id = undefined,
                .name = undefined,
                .taus = undefined,
            };
            try schedules[i].deserialize(allocator, schedule_bytes);
        }

        self.* = Frame{
            .id = id,
            .schedules = schedules,
        };

        assert(self.schedules.len > 0);
    }
};

test "Frame creation with valid parameters" {
    const allocator = std.testing.allocator;

    const tau = try primitives.Tau.create(allocator, "diff1", 1000, 2000);
    defer tau.deinit(allocator);

    const schedule = try Schedule.create(allocator, "Test Schedule", &[_]primitives.Tau{tau});
    defer schedule.deinit(allocator);

    const frame = try Frame.create(allocator, &[_]Schedule{schedule});
    defer frame.deinit(allocator);

    try std.testing.expect(frame.schedules.len == 1);
    try std.testing.expect(frame.id.len == 26); // ULID is 26 chars
}

test "Frame creation with invalid parameters" {
    const allocator = std.testing.allocator;

    // Test empty schedules array
    try std.testing.expectError(error.AssertFailed, Frame.create(allocator, &[_]Schedule{}));
}

test "Frame deep copy behavior" {
    const allocator = std.testing.allocator;

    const tau = try primitives.Tau.create(allocator, "diff", 1000, 2000);
    defer tau.deinit(allocator);

    const original_schedule = try Schedule.create(allocator, "Original", &[_]primitives.Tau{tau});
    defer original_schedule.deinit(allocator);

    const frame = try Frame.create(allocator, &[_]Schedule{original_schedule});
    defer frame.deinit(allocator);

    // Verify deep copy - different schedule IDs
    try std.testing.expect(frame.schedules[0].id != original_schedule.id);

    // Verify deep copy - same name content
    try std.testing.expect(std.mem.eql(u8, frame.schedules[0].name, original_schedule.name));

    // Verify deep copy - different tau IDs
    try std.testing.expect(frame.schedules[0].taus[0].id != original_schedule.taus[0].id);
}

test "Frame addSchedules functionality" {
    const allocator = std.testing.allocator;

    const tau1 = try primitives.Tau.create(allocator, "diff1", 1000, 2000);
    const tau2 = try primitives.Tau.create(allocator, "diff2", 2000, 3000);
    defer tau1.deinit(allocator);
    defer tau2.deinit(allocator);

    const schedule1 = try Schedule.create(allocator, "Schedule1", &[_]primitives.Tau{tau1});
    defer schedule1.deinit(allocator);

    var frame = try Frame.create(allocator, &[_]Schedule{schedule1});
    defer frame.deinit(allocator);

    const schedule2 = try Schedule.create(allocator, "Schedule2", &[_]primitives.Tau{tau2});
    defer schedule2.deinit(allocator);

    const old_len = frame.schedules.len;
    try frame.addSchedules(allocator, &[_]Schedule{schedule2});

    try std.testing.expect(frame.schedules.len == old_len + 1);

    // Verify deep copy of added schedule
    try std.testing.expect(frame.schedules[frame.schedules.len - 1].id != schedule2.id);
    try std.testing.expect(std.mem.eql(u8, frame.schedules[frame.schedules.len - 1].name, schedule2.name));
}

test "Frame addSchedules with invalid parameters" {
    const allocator = std.testing.allocator;

    const tau = try primitives.Tau.create(allocator, "diff", 1000, 2000);
    defer tau.deinit(allocator);

    var frame = try Frame.create(allocator, &[_]Schedule{try Schedule.create(allocator, "Test", &[_]primitives.Tau{tau})});
    defer frame.deinit(allocator);

    // Test empty new schedules array
    try std.testing.expectError(error.AssertFailed, frame.addSchedules(allocator, &[_]Schedule{}));
}

test "Frame deinitialization" {
    const allocator = std.testing.allocator;

    const tau1 = try primitives.Tau.create(allocator, "diff1", 1000, 2000);
    const tau2 = try primitives.Tau.create(allocator, "diff2", 2000, 3000);
    defer tau1.deinit(allocator);
    defer tau2.deinit(allocator);

    const schedule1 = try Schedule.create(allocator, "Schedule1", &[_]primitives.Tau{tau1});
    const schedule2 = try Schedule.create(allocator, "Schedule2", &[_]primitives.Tau{tau2});
    defer schedule1.deinit(allocator);
    defer schedule2.deinit(allocator);

    var frame = try Frame.create(allocator, &[_]Schedule{ schedule1, schedule2 });

    // Test that deinit doesn't crash
    frame.deinit(allocator);
}

test "Frame with multiple addSchedules calls" {
    const allocator = std.testing.allocator;

    const tau = try primitives.Tau.create(allocator, "diff", 1000, 2000);
    defer tau.deinit(allocator);

    var frame = try Frame.create(allocator, &[_]Schedule{try Schedule.create(allocator, "Initial", &[_]primitives.Tau{tau})});
    defer frame.deinit(allocator);

    // Add multiple schedules
    for (0..5) |i| {
        const new_schedule = try Schedule.create(allocator, "Added", &[_]primitives.Tau{tau});
        defer new_schedule.deinit(allocator);

        try frame.addSchedules(allocator, &[_]Schedule{new_schedule});
        try std.testing.expect(frame.schedules.len == 1 + i + 1);
    }
}

test "Frame schedule order preservation" {
    const allocator = std.testing.allocator;

    const tau = try primitives.Tau.create(allocator, "diff", 1000, 2000);
    defer tau.deinit(allocator);

    const schedule1 = try Schedule.create(allocator, "First", &[_]primitives.Tau{tau});
    defer schedule1.deinit(allocator);

    const schedule2 = try Schedule.create(allocator, "Second", &[_]primitives.Tau{tau});
    defer schedule2.deinit(allocator);

    var frame = try Frame.create(allocator, &[_]Schedule{schedule1});
    defer frame.deinit(allocator);

    try frame.addSchedules(allocator, &[_]Schedule{schedule2});

    // Verify order is preserved
    try std.testing.expect(std.mem.eql(u8, frame.schedules[0].name, "First"));
    try std.testing.expect(std.mem.eql(u8, frame.schedules[1].name, "Second"));
}

test "Frame hierarchical structure validation" {
    const allocator = std.testing.allocator;

    const tau = try primitives.Tau.create(allocator, "diff", 1000, 2000);
    defer tau.deinit(allocator);

    const schedule = try Schedule.create(allocator, "Parent Schedule", &[_]primitives.Tau{tau});
    defer schedule.deinit(allocator);

    const frame = try Frame.create(allocator, &[_]Schedule{schedule});
    defer frame.deinit(allocator);

    // Verify hierarchical structure: Frame -> Schedule -> Tau
    try std.testing.expect(frame.schedules.len == 1);
    try std.testing.expect(frame.schedules[0].taus.len == 1);
    try std.testing.expect(std.mem.eql(u8, frame.schedules[0].taus[0].diff, "diff"));
}

test "Serialize & Deserialize Frame" {
    const allocator = std.testing.allocator;

    const tau1 = try primitives.Tau.create(allocator, "diff1", 1000, 2000);
    const tau2 = try primitives.Tau.create(allocator, "diff2", 2000, 3000);
    defer tau1.deinit(allocator);
    defer tau2.deinit(allocator);

    const schedule1 = try Schedule.create(allocator, "Schedule1", &[_]primitives.Tau{tau1});
    const schedule2 = try Schedule.create(allocator, "Schedule2", &[_]primitives.Tau{tau2});
    defer schedule1.deinit(allocator);
    defer schedule2.deinit(allocator);

    const original_frame = try Frame.create(allocator, &[_]Schedule{ schedule1, schedule2 });
    defer original_frame.deinit(allocator);

    const serialized = try original_frame.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized_frame: Frame = undefined;
    try deserialized_frame.deserialize(allocator, serialized);
    defer deserialized_frame.deinit(allocator);

    try std.testing.expect(std.mem.eql(u8, deserialized_frame.id, original_frame.id));
    try std.testing.expect(deserialized_frame.schedules.len == original_frame.schedules.len);

    for (deserialized_frame.schedules, 0..) |deserialized_schedule, i| {
        try std.testing.expect(std.mem.eql(u8, deserialized_schedule.id, original_frame.schedules[i].id));
        try std.testing.expect(std.mem.eql(u8, deserialized_schedule.name, original_frame.schedules[i].name));
        try std.testing.expect(deserialized_schedule.taus.len == original_frame.schedules[i].taus.len);

        for (deserialized_schedule.taus, 0..) |deserialized_tau, j| {
            try std.testing.expect(std.mem.eql(u8, deserialized_tau.id, original_frame.schedules[i].taus[j].id));
            try std.testing.expect(std.mem.eql(u8, deserialized_tau.diff, original_frame.schedules[i].taus[j].diff));
            try std.testing.expect(deserialized_tau.valid_ns == original_frame.schedules[i].taus[j].valid_ns);
            try std.testing.expect(deserialized_tau.expiry_ns == original_frame.schedules[i].taus[j].expiry_ns);
        }
    }
}

test "Deserialize invalid data for Frame" {
    const allocator = std.testing.allocator;
    const invalid_data: [5]u8 = [_]u8{ 0, 1, 2, 3, 4 }; // Too short to be valid

    try std.testing.expectError(error.AssertFailed, {
        var frame: Frame = undefined;
        frame.deserialize(allocator, invalid_data[0..]);
    });
}
