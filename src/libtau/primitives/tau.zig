//! Defines the tau primitive representing a change in value over an interval of time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const primitives = @import("mod.zig");
const ULID = @import("../ulid/mod.zig").ULID;

/// A tau represents the update of a value during a time interval.
pub const Tau = struct {
    id: []const u8, // Unique identifier (ULID string)
    diff: []const u8, // The delta/change
    valid_ns: u64, // Start time (since epoch)
    expiry_ns: u64, // End time (since epoch)

    /// isValid checks if the tau is valid at the given time.
    pub fn isValid(self: Tau, time_ns: u64) bool {
        assert(self.valid_ns < self.expiry_ns); // Invariant: Negative interval not allowed
        return time_ns >= self.valid_ns and time_ns < self.expiry_ns;
    }

    /// Frees the heap-allocated diff string and id.
    pub fn deinit(self: *Tau, allocator: std.mem.Allocator) void {
        if (self.id.len > 0) allocator.free(self.id);
        if (self.diff.len > 0) allocator.free(self.diff);
        self.id = &[_]u8{};
        self.diff = &[_]u8{};
    }

    /// Creates a new Tau with auto-generated ULID
    pub fn create(allocator: Allocator, diff: []const u8, valid_ns: u64, expiry_ns: u64) !Tau {
        assert(diff.len > 0); // Diff should not be empty
        assert(expiry_ns > valid_ns); // Invariant: Negative interval not allowed

        const ulid = try ULID.create();
        const id = try allocator.dupe(u8, ulid.toString());
        const tau_diff = try allocator.dupe(u8, diff);
        const result = Tau{
            .id = id,
            .diff = tau_diff,
            .valid_ns = valid_ns,
            .expiry_ns = expiry_ns,
        };

        assert(result.isValid(valid_ns)); // Newly created tau should be valid at valid_ns
        assert(!result.isValid(expiry_ns)); // Newly created tau should be invalid at expiry_ns
        assert(result.diff.len > 0); // Diff should not be empty
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

        // Write diff length and diff bytes
        try bw.writeInt(u32, @intCast(self.diff.len), .big);
        try bw.writeAll(self.diff);

        // Write valid_ns and expiry_ns
        try bw.writeInt(u64, self.valid_ns, .big);
        try bw.writeInt(u64, self.expiry_ns, .big);

        const written = stream.getWritten();
        const result = try allocator.dupe(u8, written);
        return result;
    }

    /// Deserializes a Tau from a binary format.
    pub fn deserialize(self: *Tau, allocator: std.mem.Allocator, data: []const u8) !void {
        assert(data.len >= 4 + 4 + 8 + 8); // Minimum size check

        const mutable_data = try allocator.dupe(u8, data);
        defer allocator.free(mutable_data);

        var stream = std.io.fixedBufferStream(mutable_data);
        var br = stream.reader();

        // Read id length and id bytes
        const id_len = try br.readInt(u32, .big);
        const id = try allocator.alloc(u8, id_len);
        errdefer allocator.free(id);
        try br.readNoEof(id);

        // Read diff length and diff bytes
        const diff_len = try br.readInt(u32, .big);
        const diff = try allocator.alloc(u8, diff_len);
        errdefer allocator.free(diff);
        try br.readNoEof(diff);

        // Read valid_ns and expiry_ns
        const valid_ns = try br.readInt(u64, .big);
        const expiry_ns = try br.readInt(u64, .big);

        assert(valid_ns < expiry_ns); // Invariant: Negative interval not allowed
        assert(diff.len > 0); // Diff should not be empty

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
    const original_diff = "example diff data";
    const id = try allocator.dupe(u8, "01ARYZ6S4100000000000000000");
    const diff = try allocator.dupe(u8, original_diff);
    const original_tau = Tau{
        .id = id,
        .diff = diff,
        .valid_ns = 1000,
        .expiry_ns = 2000,
    };
    defer allocator.free(id);
    defer allocator.free(diff);

    const serialized = try original_tau.serialize(allocator);

    var deserialized_tau: Tau = undefined;
    try deserialized_tau.deserialize(allocator, serialized);
    defer deserialized_tau.deinit(&deserialized_tau, allocator);

    assert(deserialized_tau.diff.len == original_tau.diff.len);
    assert(std.mem.eql(u8, deserialized_tau.id, original_tau.id));
    assert(std.mem.eql(u8, deserialized_tau.diff, original_tau.diff));
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

    const tau = try Tau.create(allocator, "+1.5", 1000, 2000);
    defer tau.deinit(&tau, allocator);

    try std.testing.expect(tau.diff.len > 0);
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

    // Test empty diff
    try std.testing.expectError(error.AssertFailed, Tau.create(allocator, "", 1000, 2000));

    // Test invalid time range (expiry <= valid)
    try std.testing.expectError(error.AssertFailed, Tau.create(allocator, "+1.0", 2000, 1000));
    try std.testing.expectError(error.AssertFailed, Tau.create(allocator, "+1.0", 1000, 1000));
}

test "Tau isValid edge cases" {
    const allocator = std.testing.allocator;

    const tau = try Tau.create(allocator, "-0.5", 1000, 2000);
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

    const diffs = [_][]const u8{ "+1.0", "-0.5", "+2.5" };
    const taus = try Tau.createBatch(allocator, &diffs, 1000, 2000);
    defer {
        for (taus) |tau| tau.deinit(&tau, allocator);
        allocator.free(taus);
    }

    try std.testing.expect(taus.len == 3);

    for (taus, 0..) |tau, i| {
        try std.testing.expect(std.mem.eql(u8, tau.diff, diffs[i]));
        try std.testing.expect(tau.valid_ns == 1000);
        try std.testing.expect(tau.expiry_ns == 2000);
        try std.testing.expect(tau.isValid(1500));
    }
}

test "Tau batch creation with invalid input" {
    const allocator = std.testing.allocator;

    // Test empty diffs array
    const empty_diffs: []const []const u8 = &[_][]const u8{};
    try std.testing.expectError(error.AssertFailed, Tau.createBatch(allocator, empty_diffs, 1000, 2000));

    // Test diffs array with empty string
    const diffs_with_empty = [_][]const u8{ "+1.0", "", "-0.5" };
    try std.testing.expectError(error.AssertFailed, Tau.createBatch(allocator, &diffs_with_empty, 1000, 2000));

    // Test invalid time range
    const valid_diffs = [_][]const u8{"+1.0"};
    try std.testing.expectError(error.AssertFailed, Tau.createBatch(allocator, &valid_diffs, 2000, 1000));
}

test "Tau memory management" {
    const allocator = std.testing.allocator;

    var tau = try Tau.create(allocator, "test_diff", 1000, 2000);

    // Test that diff is properly allocated and can be modified
    try std.testing.expect(std.mem.eql(u8, tau.diff, "test_diff"));

    // Test deinit doesn't crash
    tau.deinit(&tau, allocator);
}

test "Tau diff string handling" {
    const allocator = std.testing.allocator;

    // Test various diff formats
    const test_diffs = [_][]const u8{
        "+1.5",
        "-0.25",
        "+0.0",
        "+123.456",
        "-999.999",
        "0", // Note: this might be invalid depending on your domain rules
    };

    for (test_diffs) |diff| {
        const tau = try Tau.create(allocator, diff, 1000, 2000);
        defer tau.deinit(&tau, allocator);

        try std.testing.expect(std.mem.eql(u8, tau.diff, diff));
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
            const tau = try Tau.create(allocator, "+1.0", case.valid, case.expiry);
            defer tau.deinit(&tau, allocator);

            try std.testing.expect(tau.isValid(case.valid));
            try std.testing.expect(!tau.isValid(case.expiry));
        }
    }
}

test "Tau invariants and assertions" {
    const allocator = std.testing.allocator;

    const tau = try Tau.create(allocator, "+1.0", 1000, 2000);
    defer tau.deinit(&tau, allocator);

    // Test core invariant: valid_ns < expiry_ns
    try std.testing.expect(tau.valid_ns < tau.expiry_ns);

    // Test that isValid maintains the invariant
    try std.testing.expect(tau.isValid(1000));
    try std.testing.expect(tau.isValid(1500));
    try std.testing.expect(!tau.isValid(2000));
}
