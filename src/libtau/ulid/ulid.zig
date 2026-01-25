//! ULID (Universally Unique Lexicographically Sortable Identifier) implementation based on https://github.com/ulid/spec

const std = @import("std");
const assert = std.debug.assert;

/// A ULID is a 128-bit identifier consisting of a 48-bit timestamp and an 80-bit randomness component.
pub const ULID = struct {
    timestamp: u64, // 48-bit timestamp (in milliseconds since Unix epoch)
    randomness: [10]u8, // 80-bit random component

    /// Creates a new ULID with the current timestamp and randomness component.
    pub fn create() !ULID {
        const now = std.time.milliTimestamp();

        const ulid = ULID{
            .timestamp = @as(u64, @intCast(now & 0x0000FFFFFFFFFFFF)), // Keep only the lower 48 bits
            .randomness = generateRandom(),
        };

        assert(ulid.randomness.len == 10);
        assert(ulid.timestamp <= now);
        assert(ulid.timestamp & 0xFFFF000000000000 == 0); // Ensure upper 16 bits are zero

        return ulid;
    }

    // Generates 10 bytes of randomness for the ULID.
    fn generateRandom() [10]u8 {
        var randomBytes: [10]u8 = undefined;
        std.crypto.random.bytes(&randomBytes);
        assert(randomBytes.len == 10);
        return randomBytes;
    }

    /// Encodes the ULID to a 26-character Crockford's Base32 string.
    /// Caller must free the returned slice with the provided allocator.
    pub fn toString(self: ULID, allocator: std.mem.Allocator) ![]const u8 {
        // Preconditions
        assert(self.timestamp & 0xFFFF000000000000 == 0); // Ensure upper 16 bits are zero
        assert(self.randomness.len == 10);

        const result = try allocator.alloc(u8, 26);

        const base32Chars = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
        var value: u128 = (@as(u128, self.timestamp) << 80) | @as(u128, readU80Little(self.randomness));

        for (0..26) |i| {
            const index: u8 = @intCast(value & 0x1F);
            result[25 - i] = base32Chars[index];
            value >>= 5;
        }

        // Postconditions
        assert(result.len == 26);
        assert(std.mem.indexOfScalar(u8, base32Chars, result[0]) != null); // Check first char is valid

        return result;
    }
};

fn readU80Little(bytes: [10]u8) u80 {
    // Preconditions
    assert(bytes.len == 10);

    const result = @as(u80, bytes[0]) |
        (@as(u80, bytes[1]) << 8) |
        (@as(u80, bytes[2]) << 16) |
        (@as(u80, bytes[3]) << 24) |
        (@as(u80, bytes[4]) << 32) |
        (@as(u80, bytes[5]) << 40) |
        (@as(u80, bytes[6]) << 48) |
        (@as(u80, bytes[7]) << 56) |
        (@as(u80, bytes[8]) << 64) |
        (@as(u80, bytes[9]) << 72);

    // Postconditions
    assert(result <= std.math.maxInt(u80));

    return result;
}

test "ULID creation and encoding" {
    const ulid = try ULID.create();
    const testing_allocator = std.testing.allocator;
    const ulidString = try ulid.toString(testing_allocator);
    defer testing_allocator.free(ulidString);

    std.debug.print("Generated ULID: {s}\n", .{ulidString});
    assert(ulidString.len == 26);
}

test "ULID uniqueness" {
    const testing_allocator = std.testing.allocator;
    const ulid1 = try ULID.create();
    const ulid2 = try ULID.create();

    const str1 = try ulid1.toString(testing_allocator);
    defer testing_allocator.free(str1);
    const str2 = try ulid2.toString(testing_allocator);
    defer testing_allocator.free(str2);

    assert(!std.mem.eql(u8, str1, str2));
}

test "ULID timestamp correctness" {
    const ulid = try ULID.create();
    const now = std.time.milliTimestamp() & 0x0000FFFFFFFFFFFF;
    assert(ulid.timestamp <= now);
}
