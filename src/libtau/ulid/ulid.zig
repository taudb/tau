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
    pub fn toString(self: ULID) []const u8 {
        const base32Chars = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
        var encoded: [26]u8 = undefined;

        var value: u128 = (@as(u128, self.timestamp) << 80) | @as(u128, readU80Little(self.randomness));

        for (0..26) |i| {
            const index: u8 = @intCast(value & 0x1F);
            encoded[25 - i] = base32Chars[index];
            value >>= 5;
        }

        return encoded[0..];
    }
};

fn readU80Little(bytes: [10]u8) u80 {
    return @as(u80, bytes[0]) |
        (@as(u80, bytes[1]) << 8) |
        (@as(u80, bytes[2]) << 16) |
        (@as(u80, bytes[3]) << 24) |
        (@as(u80, bytes[4]) << 32) |
        (@as(u80, bytes[5]) << 40) |
        (@as(u80, bytes[6]) << 48) |
        (@as(u80, bytes[7]) << 56) |
        (@as(u80, bytes[8]) << 64) |
        (@as(u80, bytes[9]) << 72);
}

test "ULID creation and encoding" {
    const ulid = try ULID.create();
    const ulidString = ulid.toString();
    std.debug.print("Generated ULID: {s}\n", .{ulidString});
    assert(ulidString.len == 26);
}

test "ULID uniqueness" {
    const ulid1 = try ULID.create();
    const ulid2 = try ULID.create();
    assert(ulid1.toString() != ulid2.toString());
}

test "ULID timestamp correctness" {
    const ulid = try ULID.create();
    const now = std.time.milliTimestamp() & 0x0000FFFFFFFFFFFF;
    assert(ulid.timestamp <= now);
}
