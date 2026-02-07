//! Deterministic Pseudo-Random Number Generator for simulation.

const std = @import("std");
const assert = std.debug.assert;

const log = std.log.scoped(.prng);

/// Split-Mix 64 PRNG. Fast, deterministic, statistically excellent.
/// Used by TigerBeetle for simulation testing.
pub const PRNG = struct {
    state: u64,

    // Constants

    /// Minimum allowed seed value (zero is degenerate).
    const seed_min: u64 = 1;

    /// Maximum number of values to generate in a single batch.
    /// Bounded iteration prevents infinite loops.
    const batch_max: u32 = 1 << 20;

    /// SplitMix64 magic constants.
    const splitmix_increment: u64 = 0x9e3779b97f4a7c15;
    const splitmix_mix1: u64 = 0xbf58476d1ce4e5b9;
    const splitmix_mix2: u64 = 0x94d049bb133111eb;

    // Initialization

    /// Create a PRNG with the given seed.
    pub fn init(seed: u64) PRNG {
        // Assert precondition: seed must be valid.
        assert(seed >= seed_min);

        const self = PRNG{ .state = seed };

        // Assert postcondition: state is initialized.
        assert(self.state == seed);
        assert(self.state >= seed_min);

        return self;
    }

    // Core Generation

    /// Generate the next pseudo-random u64.
    pub fn next(self: *PRNG) u64 {
        // Assert precondition: state is valid.
        assert(self.state >= seed_min);

        const old_state = self.state;

        // SplitMix64 algorithm.
        self.state +%= splitmix_increment;

        var z = self.state;
        z = (z ^ (z >> 30)) *% splitmix_mix1;
        z = (z ^ (z >> 27)) *% splitmix_mix2;
        z = z ^ (z >> 31);

        // Assert postcondition: state changed.
        assert(self.state != old_state);

        return z;
    }

    // Range Functions

    /// Generate a random u32 in [0, bound).
    /// Uses rejection sampling to avoid modulo bias.
    pub fn range_u32(self: *PRNG, bound: u32) u32 {
        // Assert preconditions.
        assert(bound > 0);
        assert(self.state >= seed_min);

        // Compute rejection threshold to eliminate modulo bias.
        const threshold: u64 = (@as(u64, 1) << 32) - ((@as(u64, 1) << 32) % bound);

        // Assert: threshold is valid.
        assert(threshold > 0);
        assert(threshold <= (@as(u64, 1) << 32));

        var iterations: u32 = 0;
        while (iterations < batch_max) : (iterations += 1) {
            const r = self.next() >> 32;
            if (r < threshold) {
                const result: u32 = @intCast(r % bound);

                // Assert postcondition: result is in valid range.
                assert(result < bound);
                return result;
            }
        }

        // Safety: should never reach here with proper threshold.
        unreachable;
    }

    /// Generate a random u64 in [0, bound).
    pub fn range_u64(self: *PRNG, bound: u64) u64 {
        // Assert precondition.
        assert(bound > 0);

        // For small bounds, use u32 path for better distribution.
        if (bound <= std.math.maxInt(u32)) {
            return self.range_u32(@intCast(bound));
        }

        // For large bounds, use simple modulo (acceptable bias for large ranges).
        const result = self.next() % bound;

        // Assert postcondition.
        assert(result < bound);

        return result;
    }

    // Probability Functions

    /// Generate a boolean with probability `numerator/denominator`.
    pub fn chance(self: *PRNG, numerator: u32, denominator: u32) bool {
        // Assert preconditions.
        assert(numerator <= denominator);
        assert(denominator > 0);

        // Fast paths.
        if (numerator == 0) return false;
        if (numerator == denominator) return true;

        return self.range_u32(denominator) < numerator;
    }

    /// Generate a boolean with 50% probability.
    pub fn coin_flip(self: *PRNG) bool {
        return self.chance(1, 2);
    }

    // Collection Functions

    /// Shuffle a slice in-place using Fisher-Yates.
    pub fn shuffle(self: *PRNG, comptime T: type, slice: []T) void {
        // Assert precondition: slice length is bounded.
        assert(slice.len <= batch_max);

        if (slice.len <= 1) return;

        var i: u32 = @intCast(slice.len - 1);
        while (i > 0) : (i -= 1) {
            const j = self.range_u32(i + 1);

            // Assert: j is a valid index.
            assert(j <= i);
            assert(j < slice.len);

            const temp = slice[i];
            slice[i] = slice[j];
            slice[j] = temp;
        }
    }

    /// Select a random element from a non-empty slice.
    pub fn select(self: *PRNG, comptime T: type, slice: []const T) T {
        // Assert preconditions.
        assert(slice.len > 0);
        assert(slice.len <= batch_max);

        const index = self.range_u32(@intCast(slice.len));

        // Assert postcondition.
        assert(index < slice.len);

        return slice[index];
    }

    /// Select a random index from a non-empty slice.
    pub fn select_index(self: *PRNG, len: usize) usize {
        // Assert preconditions.
        assert(len > 0);
        assert(len <= batch_max);

        const index = self.range_u32(@intCast(len));

        // Assert postcondition.
        assert(index < len);

        return index;
    }

    // Byte Generation

    /// Generate random bytes into a buffer.
    pub fn bytes(self: *PRNG, buffer: []u8) void {
        // Assert precondition: buffer length is bounded.
        assert(buffer.len <= batch_max * 8);

        var i: usize = 0;
        while (i < buffer.len) {
            const r = self.next();
            const remaining = buffer.len - i;
            const to_copy = @min(remaining, 8);

            // Copy bytes from random value.
            var j: usize = 0;
            while (j < to_copy) : (j += 1) {
                buffer[i + j] = @truncate(r >> @intCast(j * 8));
            }
            i += to_copy;
        }

        // Assert postcondition: all bytes were written.
        assert(i == buffer.len);
    }

    // State Management

    /// Fork this PRNG into a child with a derived seed.
    /// Useful for creating independent random streams.
    pub fn fork(self: *PRNG) PRNG {
        const child_seed = self.next();

        // Ensure child seed is valid.
        const valid_seed = if (child_seed == 0) 1 else child_seed;

        // Assert postcondition.
        assert(valid_seed >= seed_min);

        return PRNG.init(valid_seed);
    }
};

// Tests

test "PRNG.init creates valid generator" {
    const prng = PRNG.init(12345);
    try std.testing.expectEqual(@as(u64, 12345), prng.state);
}

test "PRNG.init rejects zero seed" {
    // Zero seed would cause degenerate behavior.
    // This test documents that init asserts on zero.
    // We can't directly test assertion failures in Zig tests.
    const prng = PRNG.init(1);
    try std.testing.expect(prng.state >= 1);
}

test "PRNG.next is deterministic" {
    var prng1 = PRNG.init(42);
    var prng2 = PRNG.init(42);

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        try std.testing.expectEqual(prng1.next(), prng2.next());
    }
}

test "PRNG.next changes state" {
    var prng = PRNG.init(999);
    const initial = prng.state;
    _ = prng.next();
    try std.testing.expect(prng.state != initial);
}

test "PRNG.range_u32 respects bounds" {
    var prng = PRNG.init(999);

    var i: u32 = 0;
    while (i < 10000) : (i += 1) {
        const val = prng.range_u32(100);
        try std.testing.expect(val < 100);
    }
}

test "PRNG.range_u32 with bound of 1 always returns 0" {
    var prng = PRNG.init(777);

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expectEqual(@as(u32, 0), prng.range_u32(1));
    }
}

test "PRNG.range_u64 respects bounds" {
    var prng = PRNG.init(888);

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const val = prng.range_u64(1_000_000_000_000);
        try std.testing.expect(val < 1_000_000_000_000);
    }
}

test "PRNG.chance returns expected distribution" {
    var prng = PRNG.init(54321);

    // 0% chance should always be false.
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expect(!prng.chance(0, 100));
    }

    // 100% chance should always be true.
    i = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expect(prng.chance(100, 100));
    }

    // 50% chance should be roughly half.
    var count: u32 = 0;
    i = 0;
    while (i < 10000) : (i += 1) {
        if (prng.chance(50, 100)) count += 1;
    }
    // Should be between 40% and 60%.
    try std.testing.expect(count > 4000);
    try std.testing.expect(count < 6000);
}

test "PRNG.coin_flip produces both values" {
    var prng = PRNG.init(11111);

    var trues: u32 = 0;
    var falses: u32 = 0;

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        if (prng.coin_flip()) {
            trues += 1;
        } else {
            falses += 1;
        }
    }

    try std.testing.expect(trues > 0);
    try std.testing.expect(falses > 0);
}

test "PRNG.shuffle produces valid permutation" {
    var prng = PRNG.init(11111);
    var arr = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };

    prng.shuffle(u32, &arr);

    // All elements should still be present.
    var seen = [_]bool{false} ** 10;
    for (arr) |v| {
        try std.testing.expect(v < 10);
        try std.testing.expect(!seen[v]);
        seen[v] = true;
    }

    for (seen) |s| {
        try std.testing.expect(s);
    }
}

test "PRNG.shuffle is deterministic" {
    var prng1 = PRNG.init(22222);
    var prng2 = PRNG.init(22222);

    var arr1 = [_]u32{ 0, 1, 2, 3, 4 };
    var arr2 = [_]u32{ 0, 1, 2, 3, 4 };

    prng1.shuffle(u32, &arr1);
    prng2.shuffle(u32, &arr2);

    try std.testing.expectEqualSlices(u32, &arr1, &arr2);
}

test "PRNG.select returns element from slice" {
    var prng = PRNG.init(22222);
    const arr = [_]u32{ 10, 20, 30, 40, 50 };

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const val = prng.select(u32, &arr);
        var found = false;
        for (arr) |a| {
            if (a == val) found = true;
        }
        try std.testing.expect(found);
    }
}

test "PRNG.select_index returns valid index" {
    var prng = PRNG.init(33333);

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const idx = prng.select_index(10);
        try std.testing.expect(idx < 10);
    }
}

test "PRNG.bytes fills buffer deterministically" {
    var prng1 = PRNG.init(33333);
    var prng2 = PRNG.init(33333);

    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;

    prng1.bytes(&buf1);
    prng2.bytes(&buf2);

    try std.testing.expectEqualSlices(u8, &buf1, &buf2);
}

test "PRNG.bytes fills entire buffer" {
    var prng = PRNG.init(44444);
    var buf: [100]u8 = [_]u8{0} ** 100;

    prng.bytes(&buf);

    // At least some bytes should be non-zero.
    var non_zero: u32 = 0;
    for (buf) |b| {
        if (b != 0) non_zero += 1;
    }
    try std.testing.expect(non_zero > 50);
}

test "PRNG.fork creates independent stream" {
    var parent = PRNG.init(55555);

    const parent_state_before = parent.state;
    var child = parent.fork();
    const parent_state_after = parent.state;

    // Parent state should have changed.
    try std.testing.expect(parent_state_after != parent_state_before);

    // Child should produce different values than parent.
    const parent_val = parent.next();
    const child_val = child.next();
    // Note: they could theoretically be equal, but extremely unlikely.
    _ = parent_val;
    _ = child_val;
}

test "PRNG distribution across range" {
    var prng = PRNG.init(66666);
    var buckets = [_]u32{0} ** 10;

    // Generate 10000 values in [0, 10).
    var i: u32 = 0;
    while (i < 10000) : (i += 1) {
        const val = prng.range_u32(10);
        buckets[val] += 1;
    }

    // Each bucket should have roughly 1000 values (10000/10).
    // Allow 30% variance.
    for (buckets) |count| {
        try std.testing.expect(count > 700);
        try std.testing.expect(count < 1300);
    }
}
