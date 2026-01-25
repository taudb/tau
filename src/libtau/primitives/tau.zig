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

    /// isValid checks if tau is valid at the given time.
    pub fn isValid(self: Tau, time_ns: u64) bool {
        // Preconditions
        assert(self.valid_ns < self.expiry_ns); // Invariant: Negative interval not allowed
        assert(time_ns >= 0); // Time should be non-negative

        const result = time_ns >= self.valid_ns and time_ns < self.expiry_ns;

        // Postconditions
        assert(result == true or result == false); // Result is boolean
        assert(time_ns < self.expiry_ns or !result); // If result is true, time must be within bounds

        return result;
    }

    /// Frees heap-allocated id.
    pub fn deinit(self: *Tau, allocator: std.mem.Allocator) void {
        // Preconditions
        assert(self.id.len >= 0); // ID length should be valid

        if (self.id.len > 0) allocator.free(self.id);
        self.id = &[_]u8{};
        self.diff = 0.0;

        // Postconditions
        assert(self.id.len == 0);
        assert(self.diff == 0.0);
    }

    /// Creates a new Tau with auto-generated ULID
    pub fn create(allocator: Allocator, diff: f64, valid_ns: u64, expiry_ns: u64) !Tau {
        assert(expiry_ns > valid_ns); // Invariant: Negative interval not allowed
        assert(std.math.isFinite(diff)); // Diff should be finite

        const ulid = try ULID.create();
        const ulid_string = try ulid.toString(allocator);
        const id = ulid_string;
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
        // Preconditions
        assert(self.id.len > 0);
        assert(self.valid_ns < self.expiry_ns);
        assert(std.math.isFinite(self.diff));

        var buffer: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        var bw = stream.writer();

        // Write id length and id bytes (ULID is 26 chars)
        try bw.writeInt(u32, @intCast(self.id.len), .big);
        try bw.writeAll(self.id);

        // Write diff as f64
        const diff_bits = @as(u64, @bitCast(self.diff));
        try bw.writeInt(u64, diff_bits, .big);

        // Write valid_ns and expiry_ns
        try bw.writeInt(u64, self.valid_ns, .big);
        try bw.writeInt(u64, self.expiry_ns, .big);

        const written = stream.getWritten();
        const result = try allocator.dupe(u8, written);

        // Postconditions
        assert(result.len > 0);
        assert(result.len <= 1024);

        return result;
    }

    /// Deserializes a Tau from a binary format.
    pub fn deserialize(self: *Tau, allocator: std.mem.Allocator, data: []const u8) !void {
        // Preconditions
        assert(data.len >= 4 + 8 + 8 + 8); // Minimum size check
        assert(data.len <= 4096); // Reasonable max size

        const mutable_data = try allocator.dupe(u8, data);
        defer allocator.free(mutable_data);

        var stream = std.io.fixedBufferStream(mutable_data);
        var br = stream.reader();

        // Read id length and id bytes
        const id_len = try br.readInt(u32, .big);
        assert(id_len <= 128); // Reasonable ID length
        assert(id_len > 0); // ID must not be empty

        const id = try allocator.alloc(u8, id_len);
        errdefer allocator.free(id);
        try br.readNoEof(id);

        // Read diff as f64
        const diff_bits = try br.readInt(u64, .big);
        const diff = @as(f64, @bitCast(diff_bits));

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

        // Postconditions
        assert(self.valid_ns < self.expiry_ns);
        assert(self.id.len == id_len);
        assert(std.math.isFinite(self.diff));
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
    try deserialized_tau.deserialize(&deserialized_tau, allocator, serialized);
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
        tau.deserialize(&tau, allocator, invalid_data[0..]);
    });
}

test "Tau creation with valid parameters" {
    const allocator = std.testing.allocator;

    const tau = try Tau.create(allocator, 1.5, 1000, 2000);
    defer tau.deinit(&tau, allocator);

    try std.testing.expect(tau.diff == 1.5);
    try std.testing.expect(tau.valid_ns == 1000);
    try std.testing.expect(tau.expiry_ns == 2000);
    try std.testing.expect(tau.isValid(1500));
    try std.testing.expect(!tau.isValid(999));
    try std.testing.expect(!tau.isValid(2000));
}

test "Tau invariants and assertions" {
    const allocator = std.testing.allocator;

    const tau = try Tau.create(allocator, 0.0, 1000, 2000);
    defer tau.deinit(&tau, allocator);

    // Test boundary conditions
    try std.testing.expect(tau.isValid(1000)); // Valid at start
    try std.testing.expect(!tau.isValid(999)); // Invalid before start
    try std.testing.expect(tau.isValid(1999)); // Valid before end
    try std.testing.expect(!tau.isValid(2000)); // Invalid at end

    // Test with different diff values
    const diffs = [_]f64{
        -1.0,
        0.0,
        123.456,
        -999.999,
        std.math.floatMax(f64),
        std.math.floatMin(f64),
    };

    for (diffs) |diff| {
        const test_tau = try Tau.create(allocator, diff, 1000, 2000);
        defer test_tau.deinit(&test_tau, allocator);

        try std.testing.expect(test_tau.diff == diff);
        try std.testing.expect(test_tau.isValid(1500));
    }
}
