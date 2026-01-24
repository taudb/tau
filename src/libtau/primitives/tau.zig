//! Defines the tau primitive representing a change in value over an interval of time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const primitives = @import("mod.zig");
const ULID = @import("ulid").ULID;

/// A tau represents the update of a value during a time interval.
pub const Tau = struct {
    id: []const u8, // Unique identifier (ULID string)
    diff: f64, // The delta/change (numeric value)
    valid_ns: u64, // Start time (since epoch)
    expiry_ns: u64, // End time (since epoch)

    /// isValid checks if the tau is valid at the given time.
    pub fn isValid(self: Tau, time_ns: u64) bool {
        assert(self.valid_ns < self.expiry_ns); // Invariant: Negative interval not allowed
        return time_ns >= self.valid_ns and time_ns < self.expiry_ns;
    }

    /// Frees heap-allocated id.
    pub fn deinit(self: *Tau, allocator: std.mem.Allocator) void {
        if (self.id.len > 0) allocator.free(self.id);
        self.id = &[_]u8{};
        self.diff = 0.0;
    }

    /// Creates a new Tau with auto-generated ULID
    pub fn create(allocator: Allocator, diff: f64, valid_ns: u64, expiry_ns: u64) !Tau {
        assert(expiry_ns > valid_ns); // Invariant: Negative interval not allowed

        const ulid = try ULID.create();
        const id = try allocator.dupe(u8, ulid.toString());
        const result = Tau{
            .id = id,
            .diff = diff,
            .valid_ns = valid_ns,
            .expiry_ns = expiry_ns,
        };

        assert(result.isValid(valid_ns)); // Newly created tau should be valid at valid_ns
        assert(!result.isValid(expiry_ns)); // Newly created tau should be invalid at expiry_ns
        return result;
    }

    /// Creates multiple Taus with the same time range
    pub fn createBatch(allocator: Allocator, diffs: []const f64, valid_ns: u64, expiry_ns: u64) ![]Tau {
        assert(diffs.len > 0); // At least one diff required
        assert(expiry_ns > valid_ns); // Invariant: Negative interval not allowed

        const result = try allocator.alloc(Tau, diffs.len);

        for (diffs, 0..) |diff, i| {
            const tau = try Tau.create(allocator, diff, valid_ns, expiry_ns);
            // Transfer ownership to the batch
            result[i] = tau;
        }

        return result;
    }

    /// Serializes a Tau into a binary format.
    pub fn serialize(self: Tau, allocator: std.mem.Allocator) ![]u8 {
        var buffer: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        var bw = stream.writer();

        // Write id length and id bytes (ULID is 26 chars)
        try bw.writeInt(u32, @intCast(self.id.len), .big);
        try bw.writeAll(self.id);

        // Write diff as f64
        try bw.writeInt(f64, self.diff, .big);

        // Write valid_ns and expiry_ns
        try bw.writeInt(u64, self.valid_ns, .big);
        try bw.writeInt(u64, self.expiry_ns, .big);

        const written = stream.getWritten();
        const result = try allocator.dupe(u8, written);
        return result;
    }

    /// Deserializes a Tau from a binary format.
    pub fn deserialize(self: *Tau, allocator: std.mem.Allocator, data: []const u8) !void {
        assert(data.len >= 4 + 8 + 8 + 8); // Minimum size check

        const mutable_data = try allocator.dupe(u8, data);
        defer allocator.free(mutable_data);

        var stream = std.io.fixedBufferStream(mutable_data);
        var br = stream.reader();

        // Read id length and id bytes
        const id_len = try br.readInt(u32, .big);
        const id = try allocator.alloc(u8, id_len);
        errdefer allocator.free(id);
        try br.readNoEof(id);

        // Read diff as f64
        const diff = try br.readInt(f64, .big);

        // Read valid_ns and expiry_ns
        const valid_ns = try br.readInt(u64, .big);
        const expiry_ns = try br.readInt(u64, .big);

        assert(valid_ns < expiry_ns); // Invariant: Negative interval not allowed

        self.* = Tau{
            .id = id,
            .diff = diff,
            .valid_ns = valid_ns,
            .expiry_ns = expiry_ns,
        };
    }
};

test "Serialize & Deserialize Tau" {
    const allocator = std.testing.allocator;
    const id = try allocator.dupe(u8, "01ARYZ6S4100000000000000000");
    const original_tau = Tau{
        .id = id,
        .diff = 1.5,
        .valid_ns = 1000,
        .expiry_ns = 2000,
    };
    defer allocator.free(id);

    const serialized = try original_tau.serialize(allocator);

    var deserialized_tau: Tau = undefined;
    try deserialized_tau.deserialize(allocator, serialized);
    defer deserialized_tau.deinit(&deserialized_tau, allocator);

    assert(deserialized_tau.diff == original_tau.diff);
    assert(std.mem.eql(u8, deserialized_tau.id, original_tau.id));
    assert(deserialized_tau.valid_ns == original_tau.valid_ns);
    assert(deserialized_tau.expiry_ns == original_tau.expiry_ns);

    allocator.free(serialized);
    deserialized_tau.deinit(&deserialized_tau, allocator);
}

test "Deserialize invalid data" {
    const allocator = std.testing.allocator;
    const invalid_data: [5]u8 = [_]u8{ 0, 1, 2, 3, 4 }; // Too short to be valid

    try std.testing.expectError(error.AssertFailed, {
        var tau: Tau = undefined;
        tau.deserialize(allocator, invalid_data[0..]);
    });
}

test "Tau creation with valid parameters" {
    const allocator = std.testing.allocator;

    const tau = try Tau.create(allocator, 1.5, 1000, 2000);
    defer tau.deinit(&tau, allocator);

    try std.testing.expect(tau.diff == 1.5);
    try std.testing.expect(tau.valid_ns == 1000);
    try std.testing.expect(tau.expiry_ns == 2000);
    try std.testing.expect(tau.isValid(1000));
    try std.testing.expect(tau.isValid(1500));
    try std.testing.expect(!tau.isValid(2000));
    try std.testing.expect(!tau.isValid(999));
    try std.testing.expect(!tau.isValid(2001));
}

test "Tau creation with invalid parameters" {
    const allocator = std.testing.allocator;

    // Test invalid time range (expiry <= valid)
    try std.testing.expectError(error.AssertFailed, Tau.create(allocator, 1.0, 2000, 1000));
    try std.testing.expectError(error.AssertFailed, Tau.create(allocator, 1.0, 1000, 1000));
}

test "Tau isValid edge cases" {
    const allocator = std.testing.allocator;

    const tau = try Tau.create(allocator, -0.5, 1000, 2000);
    defer tau.deinit(&tau, allocator);

    // Test boundary conditions
    try std.testing.expect(tau.isValid(1000)); // Valid at start
    try std.testing.expect(tau.isValid(1999)); // Valid just before end
    try std.testing.expect(!tau.isValid(2000)); // Invalid at end
    try std.testing.expect(!tau.isValid(999)); // Invalid before start
    try std.testing.expect(!tau.isValid(2001)); // Invalid after end

    // Test extreme values
    try std.testing.expect(!tau.isValid(0));
    try std.testing.expect(!tau.isValid(std.math.maxInt(u64)));
}

test "Tau batch creation" {
    const allocator = std.testing.allocator;

    const diffs = [_]f64{ 1.0, -0.5, 2.5 };
    const taus = try Tau.createBatch(allocator, &diffs, 1000, 2000);
    defer {
        for (taus) |tau| tau.deinit(&tau, allocator);
        allocator.free(taus);
    }

    try std.testing.expect(taus.len == 3);

    for (taus, 0..) |tau, i| {
        try std.testing.expect(tau.diff == diffs[i]);
        try std.testing.expect(tau.valid_ns == 1000);
        try std.testing.expect(tau.expiry_ns == 2000);
        try std.testing.expect(tau.isValid(1500));
    }
}

test "Tau batch creation with invalid input" {
    const allocator = std.testing.allocator;

    // Test empty diffs array
    const empty_diffs: []const f64 = &[_]f64{};
    try std.testing.expectError(error.AssertFailed, Tau.createBatch(allocator, empty_diffs, 1000, 2000));

    // Test invalid time range
    const valid_diffs = [_]f64{1.0};
    try std.testing.expectError(error.AssertFailed, Tau.createBatch(allocator, &valid_diffs, 2000, 1000));
}

test "Tau memory management" {
    const allocator = std.testing.allocator;

    var tau = try Tau.create(allocator, 3.14159, 1000, 2000);

    // Test that diff is properly set
    try std.testing.expect(tau.diff == 3.14159);

    // Test deinit doesn't crash
    tau.deinit(&tau, allocator);
}

test "Tau diff numeric handling" {
    const allocator = std.testing.allocator;

    // Test various diff values
    const test_diffs = [_]f64{
        1.5,
        -0.25,
        0.0,
        123.456,
        -999.999,
        std.math.f64_max,
        std.math.f64_min,
    };

    for (test_diffs) |diff| {
        const tau = try Tau.create(allocator, diff, 1000, 2000);
        defer tau.deinit(&tau, allocator);

        try std.testing.expect(tau.diff == diff);
        try std.testing.expect(tau.isValid(1500));
    }
}

test "Tau time range validation" {
    const allocator = std.testing.allocator;

    // Test various time ranges
    const test_cases = [_]struct { valid: u64, expiry: u64, expected_valid: bool }{
        .{ .valid = 1000, .expiry = 2000, .expected_valid = true },
        .{ .valid = 0, .expiry = 1, .expected_valid = true },
        .{ .valid = std.math.maxInt(u64) - 1, .expiry = std.math.maxInt(u64), .expected_valid = true },
    };

    for (test_cases) |case| {
        if (case.expected_valid) {
            const tau = try Tau.create(allocator, 1.0, case.valid, case.expiry);
            defer tau.deinit(&tau, allocator);

            try std.testing.expect(tau.isValid(case.valid));
            try std.testing.expect(!tau.isValid(case.expiry));
        }
    }
}

test "Tau invariants and assertions" {
    const allocator = std.testing.allocator;

    const tau = try Tau.create(allocator, 1.0, 1000, 2000);
    defer tau.deinit(&tau, allocator);

    // Test core invariant: valid_ns < expiry_ns
    try std.testing.expect(tau.valid_ns < tau.expiry_ns);

    // Test that isValid maintains the invariant
    try std.testing.expect(tau.isValid(1000));
    try std.testing.expect(tau.isValid(1500));
    try std.testing.expect(!tau.isValid(2000));
}
