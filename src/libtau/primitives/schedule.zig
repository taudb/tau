//! A module defining a Schedule struct that manages a collection of Tau structs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const primitives = @import("mod.zig");
const Tau = primitives.Tau;
const ULID = @import("ulid").ULID;

/// A schedule represents a collection of taus identified by a unique id.
pub const Schedule = struct {
    id: []const u8,
    name: []const u8,
    taus: []Tau,
    pub fn deinit(self: Schedule, allocator: std.mem.Allocator) void {
        // First, deinit each tau (if they have allocated memory)
        for (self.taus) |*t| {
            t.deinit(allocator);
        }

        // Then free the array holding them
        allocator.free(self.taus);
        allocator.free(self.name);
        allocator.free(self.id);
    }

    /// Creates a new Schedule with auto-generated ULID and copies of the provided taus
    pub fn create(allocator: Allocator, name: []const u8, taus: []const Tau) !Schedule {
        assert(name.len > 0); // Name should not be empty
        assert(taus.len > 0); // There should be at least one tau

        const ulid = try ULID.create();
        const id = try allocator.dupe(u8, ulid.toString());
        const schedule_name = try allocator.dupe(u8, name);

        var schedule_taus = try allocator.alloc(Tau, taus.len);
        errdefer allocator.free(schedule_taus);

        for (taus, 0..) |tau, i| {
            const tau_copy = try Tau.create(allocator, tau.diff, tau.valid_ns, tau.expiry_ns);
            schedule_taus[i] = tau_copy;
        }

        const schedule = Schedule{
            .id = id,
            .name = schedule_name,
            .taus = schedule_taus,
        };

        assert(schedule.name.len > 0);
        assert(schedule.taus.len > 0);
        return schedule;
    }

    /// Add new taus to the schedule (append-only)
    pub fn addTaus(self: *Schedule, allocator: Allocator, new_taus: []const Tau) !void {
        assert(new_taus.len > 0); // There should be at least one new tau to add

        // Create new array with expanded capacity
        const old_len = self.taus.len;
        const new_len = old_len + new_taus.len;
        var expanded_taus = try allocator.realloc(self.taus, new_len);

        // Copy new taus with deep copy
        for (new_taus, 0..) |new_tau, i| {
            const tau_copy = try Tau.create(allocator, new_tau.diff, new_tau.valid_ns, new_tau.expiry_ns);
            expanded_taus[old_len + i] = tau_copy;
        }

        self.taus = expanded_taus;

        assert(self.taus.len == new_len);
        assert(self.taus.len > old_len);
    }

    /// Serializes a Schedule into a binary format.
    pub fn serialize(self: Schedule, allocator: std.mem.Allocator) ![]u8 {
        var buffer: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        var bw = stream.writer();

        // Write id length and id bytes (ULID is 26 chars)
        try bw.writeInt(u32, @intCast(self.id.len), .big);
        try bw.writeAll(self.id);

        // Write name length and name bytes
        try bw.writeInt(u32, @intCast(self.name.len), .big);
        try bw.writeAll(self.name);

        // Write taus count
        try bw.writeInt(u32, @intCast(self.taus.len), .big);

        // Serialize each tau
        for (self.taus) |tau| {
            const tau_bytes = try tau.serialize(allocator);
            defer allocator.free(tau_bytes);
            try bw.writeInt(u32, @intCast(tau_bytes.len), .big);
            try bw.writeAll(tau_bytes);
        }

        const written = stream.getWritten();
        const result = try allocator.dupe(u8, written);
        return result;
    }

    /// Deserializes a Schedule from a binary format.
    pub fn deserialize(self: *Schedule, allocator: std.mem.Allocator, data: []const u8) !void {
        assert(data.len >= 4 + 4); // Minimum size check

        // Make a mutable copy since reader() needs *Self
        const mutable_data = try allocator.dupe(u8, data);
        defer allocator.free(mutable_data);

        var stream = std.io.fixedBufferStream(mutable_data);
        var br = stream.reader();

        // Read id length and id bytes
        const id_len = try br.readInt(u32, .big);
        const id = try allocator.alloc(u8, id_len);
        errdefer allocator.free(id);
        try br.readNoEof(id);

        // Read name length and name bytes
        const name_len = try br.readInt(u32, .big);
        const name = try allocator.alloc(u8, name_len);
        errdefer allocator.free(name);
        try br.readNoEof(name);

        // Read taus count
        const taus_count = try br.readInt(u32, .big);

        // Read and deserialize each tau
        var taus = try allocator.alloc(Tau, taus_count);
        var num_initialized: usize = 0;
        errdefer {
            for (taus[0..num_initialized]) |*t| t.deinit(allocator);
            allocator.free(taus);
        }

        for (0..taus_count) |i| {
            const tau_bytes_len = try br.readInt(u32, .big);
            const tau_bytes = try allocator.alloc(u8, tau_bytes_len);
            defer allocator.free(tau_bytes);
            try br.readNoEof(tau_bytes);

            taus[i] = .{
                .id = undefined,
                .diff = undefined,
                .valid_ns = undefined,
                .expiry_ns = undefined,
            };
            try taus[i].deserialize(allocator, tau_bytes);
            num_initialized += 1;
        }

        self.* = Schedule{
            .id = id,
            .name = name,
            .taus = taus,
        };

        assert(self.name.len > 0);
        assert(self.taus.len > 0);
    }
};

test "Schedule creation with valid parameters" {
    const allocator = std.testing.allocator;

    const tau1 = try Tau.create(allocator, "diff1", 1000, 2000);
    const tau2 = try Tau.create(allocator, "diff2", 2000, 3000);
    defer tau1.deinit(allocator);
    defer tau2.deinit(allocator);

    var taus = [_]Tau{ tau1, tau2 };
    const schedule = try Schedule.create(allocator, "Test Schedule", taus[0..]);
    defer schedule.deinit(allocator);

    try std.testing.expect(schedule.taus.len == 2);
    try std.testing.expect(std.mem.eql(u8, schedule.name, "Test Schedule"));
    try std.testing.expect(schedule.id.len == 26); // ULID is 26 chars
}

test "Schedule creation with invalid parameters" {
    const allocator = std.testing.allocator;

    // Test empty name
    const tau = try Tau.create(allocator, "diff", 1000, 2000);
    defer tau.deinit(allocator);

    try std.testing.expectError(error.AssertFailed, Schedule.create(allocator, "", &[_]Tau{tau}));

    // Test empty taus array
    try std.testing.expectError(error.AssertFailed, Schedule.create(allocator, "Test", &[_]Tau{}));
}

test "Schedule deep copy behavior" {
    const allocator = std.testing.allocator;

    const original_tau = try Tau.create(allocator, "original", 1000, 2000);
    defer original_tau.deinit(allocator);

    const schedule = try Schedule.create(allocator, "Test", &[_]Tau{original_tau});
    defer schedule.deinit(allocator);

    // Verify deep copy - different IDs
    try std.testing.expect(schedule.taus[0].id != original_tau.id);

    // Verify deep copy - same diff content
    try std.testing.expect(std.mem.eql(u8, schedule.taus[0].diff, original_tau.diff));
}

test "Schedule addTaus functionality" {
    const allocator = std.testing.allocator;

    const tau1 = try Tau.create(allocator, "diff1", 1000, 2000);
    const tau2 = try Tau.create(allocator, "diff2", 2000, 3000);
    defer tau1.deinit(allocator);
    defer tau2.deinit(allocator);

    var schedule = try Schedule.create(allocator, "Test", &[_]Tau{tau1});
    defer schedule.deinit(allocator);

    const new_tau = try Tau.create(allocator, "new_diff", 3000, 4000);
    defer new_tau.deinit(allocator);

    const old_len = schedule.taus.len;
    try schedule.addTaus(allocator, &[_]Tau{new_tau});

    try std.testing.expect(schedule.taus.len == old_len + 1);

    // Verify deep copy of added tau
    try std.testing.expect(schedule.taus[schedule.taus.len - 1].id != new_tau.id);
    try std.testing.expect(std.mem.eql(u8, schedule.taus[schedule.taus.len - 1].diff, new_tau.diff));
}

test "Schedule addTaus with invalid parameters" {
    const allocator = std.testing.allocator;

    const tau = try Tau.create(allocator, "diff", 1000, 2000);
    defer tau.deinit(allocator);

    var schedule = try Schedule.create(allocator, "Test", &[_]Tau{tau});
    defer schedule.deinit(allocator);

    // Test empty new taus array
    try std.testing.expectError(error.AssertFailed, schedule.addTaus(allocator, &[_]Tau{}));
}

test "Schedule deinitialization" {
    const allocator = std.testing.allocator;

    const tau1 = try Tau.create(allocator, "diff1", 1000, 2000);
    const tau2 = try Tau.create(allocator, "diff2", 2000, 3000);
    defer tau1.deinit(allocator);
    defer tau2.deinit(allocator);

    var schedule = try Schedule.create(allocator, "Test Schedule", &[_]Tau{ tau1, tau2 });

    // Test that deinit doesn't crash (valgrind would catch memory leaks)
    schedule.deinit(allocator);
}

test "Schedule name handling" {
    const allocator = std.testing.allocator;

    const tau = try Tau.create(allocator, "diff", 1000, 2000);
    defer tau.deinit(allocator);

    // Test various name formats
    const test_names = [_][]const u8{
        "Simple",
        "Name with spaces",
        "Name-with-dashes",
        "Name_with_underscores",
        "Name123",
        "A", // Single character
    };

    for (test_names) |name| {
        const schedule = try Schedule.create(allocator, name, &[_]Tau{tau});
        defer schedule.deinit(allocator);

        try std.testing.expect(std.mem.eql(u8, schedule.name, name));
    }
}

test "Schedule with multiple addTaus calls" {
    const allocator = std.testing.allocator;

    const tau = try Tau.create(allocator, "diff", 1000, 2000);
    defer tau.deinit(allocator);

    var schedule = try Schedule.create(allocator, "Test", &[_]Tau{tau});
    defer schedule.deinit(allocator);

    // Add multiple batches
    for (0..5) |i| {
        const new_tau = try Tau.create(allocator, "new_diff", 1000, 2000);
        defer new_tau.deinit(allocator);

        try schedule.addTaus(allocator, &[_]Tau{new_tau});
        try std.testing.expect(schedule.taus.len == 1 + i + 1);
    }
}

test "Schedule time range consistency" {
    const allocator = std.testing.allocator;

    const tau1 = try Tau.create(allocator, "diff1", 1000, 2000);
    const tau2 = try Tau.create(allocator, "diff2", 1500, 2500);
    const tau3 = try Tau.create(allocator, "diff3", 2000, 3000);
    defer tau1.deinit(allocator);
    defer tau2.deinit(allocator);
    defer tau3.deinit(allocator);

    const schedule = try Schedule.create(allocator, "Test", &[_]Tau{ tau1, tau2, tau3 });
    defer schedule.deinit(allocator);

    // Test that all taus maintain their original time ranges
    try std.testing.expect(schedule.taus[0].valid_ns == 1000);
    try std.testing.expect(schedule.taus[0].expiry_ns == 2000);
    try std.testing.expect(schedule.taus[1].valid_ns == 1500);
    try std.testing.expect(schedule.taus[1].expiry_ns == 2500);
    try std.testing.expect(schedule.taus[2].valid_ns == 2000);
    try std.testing.expect(schedule.taus[2].expiry_ns == 3000);
}

test "Serialize & Deserialize Schedule" {
    const allocator = std.testing.allocator;

    const tau1 = try Tau.create(allocator, "diff1", 1000, 2000);
    const tau2 = try Tau.create(allocator, "diff2", 2000, 3000);
    defer tau1.deinit(allocator);
    defer tau2.deinit(allocator);

    const original_schedule = try Schedule.create(allocator, "Test Schedule", &[_]Tau{ tau1, tau2 });
    defer original_schedule.deinit(allocator);

    const serialized = try original_schedule.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized_schedule: Schedule = undefined;
    try deserialized_schedule.deserialize(allocator, serialized);
    defer deserialized_schedule.deinit(allocator);

    try std.testing.expect(std.mem.eql(u8, deserialized_schedule.id, original_schedule.id));
    try std.testing.expect(std.mem.eql(u8, deserialized_schedule.name, original_schedule.name));
    try std.testing.expect(deserialized_schedule.taus.len == original_schedule.taus.len);

    for (deserialized_schedule.taus, 0..) |deserialized_tau, i| {
        try std.testing.expect(std.mem.eql(u8, deserialized_tau.id, original_schedule.taus[i].id));
        try std.testing.expect(std.mem.eql(u8, deserialized_tau.diff, original_schedule.taus[i].diff));
        try std.testing.expect(deserialized_tau.valid_ns == original_schedule.taus[i].valid_ns);
        try std.testing.expect(deserialized_tau.expiry_ns == original_schedule.taus[i].expiry_ns);
    }
}

test "Deserialize invalid data for Schedule" {
    const allocator = std.testing.allocator;
    const invalid_data: [5]u8 = [_]u8{ 0, 1, 2, 3, 4 }; // Too short to be valid

    try std.testing.expectError(error.AssertFailed, {
        var schedule: Schedule = undefined;
        schedule.deserialize(allocator, invalid_data[0..]);
    });
}
