//! Fault injection system for deterministic simulation testing.

const std = @import("std");
const assert = std.debug.assert;
const config = @import("tau").config;
const PRNG = @import("prng.zig").PRNG;

const log = std.log.scoped(.faults);

// Fault Configuration

/// Fault configuration with probabilities in parts-per-million.
pub const FaultConfig = struct {
    /// Storage fault probabilities.
    storage_read_error_ppm: u32 = 0,
    storage_write_error_ppm: u32 = 0,
    storage_bitflip_ppm: u32 = 0,
    storage_lost_write_ppm: u32 = 0,
    storage_gray_failure_ppm: u32 = 0,

    /// Network fault probabilities.
    network_drop_ppm: u32 = 0,
    network_reorder_ppm: u32 = 0,
    network_duplicate_ppm: u32 = 0,
    network_corrupt_ppm: u32 = 0,
    network_delay_ppm: u32 = 0,

    /// Memory fault probabilities.
    memory_corrupt_ppm: u32 = 0,
    memory_alloc_fail_ppm: u32 = 0,

    /// Time fault probabilities.
    clock_skew_ppm: u32 = 0,

    /// Bounded fault parameters.
    max_network_delay_ticks: u32 = config.faults.max_network_delay_ticks,
    max_clock_skew_ns: i64 = config.faults.max_clock_skew_ns,

    /// Parts per million constant.
    pub const ppm: u32 = 1_000_000;

    // Preset Configurations

    /// Create a fault-free configuration.
    pub fn none() FaultConfig {
        return fromConfigRates(config.faults.none);
    }

    /// Create a mild fault configuration.
    pub fn mild() FaultConfig {
        return fromConfigRates(config.faults.mild);
    }

    /// Create an aggressive fault configuration.
    pub fn aggressive() FaultConfig {
        return fromConfigRates(config.faults.aggressive);
    }

    /// Create a chaos fault configuration.
    pub fn chaos() FaultConfig {
        return fromConfigRates(config.faults.chaos);
    }

    /// Convert config.faults.FaultRates to FaultConfig.
    fn fromConfigRates(rates: config.faults.FaultRates) FaultConfig {
        return .{
            .storage_read_error_ppm = rates.storage_read_error_ppm,
            .storage_write_error_ppm = rates.storage_write_error_ppm,
            .storage_bitflip_ppm = rates.storage_bitflip_ppm,
            .storage_lost_write_ppm = rates.storage_lost_write_ppm,
            .storage_gray_failure_ppm = rates.storage_gray_failure_ppm,
            .network_drop_ppm = rates.network_drop_ppm,
            .network_reorder_ppm = rates.network_reorder_ppm,
            .network_duplicate_ppm = rates.network_duplicate_ppm,
            .network_corrupt_ppm = rates.network_corrupt_ppm,
            .network_delay_ppm = rates.network_delay_ppm,
            .memory_corrupt_ppm = rates.memory_corrupt_ppm,
            .memory_alloc_fail_ppm = rates.memory_alloc_fail_ppm,
            .clock_skew_ppm = rates.clock_skew_ppm,
        };
    }
};

// Fault Types

/// Fault result for storage operations.
pub const StorageFault = enum {
    none,
    read_error,
    write_error,
    bitflip,
    lost_write,
    gray_failure,
};

/// Fault result for network operations.
pub const NetworkFault = enum {
    none,
    drop,
    reorder,
    duplicate,
    corrupt,
    delay,
};

// Fault Injector

/// Fault injector with deterministic PRNG.
pub const FaultInjector = struct {
    prng: PRNG,
    cfg: FaultConfig,
    stats: FaultStats,

    /// Maximum consecutive faults (safety bound).
    const max_consecutive_faults: u32 = 10;

    // Initialization

    /// Create a fault injector.
    pub fn init(seed: u64, cfg: FaultConfig) FaultInjector {
        // Assert precondition: seed is valid.
        assert(seed >= 1);

        // Assert config invariants.
        assert(cfg.storage_read_error_ppm <= FaultConfig.ppm);
        assert(cfg.storage_write_error_ppm <= FaultConfig.ppm);
        assert(cfg.storage_bitflip_ppm <= FaultConfig.ppm);
        assert(cfg.network_drop_ppm <= FaultConfig.ppm);
        assert(cfg.network_reorder_ppm <= FaultConfig.ppm);
        assert(cfg.max_network_delay_ticks > 0);
        assert(cfg.max_clock_skew_ns > 0);

        const self = FaultInjector{
            .prng = PRNG.init(seed),
            .cfg = cfg,
            .stats = FaultStats{},
        };

        // Assert postconditions.
        assert(self.stats.total_injections == 0);

        return self;
    }

    // Storage Faults

    /// Maybe inject a storage read fault.
    pub fn maybe_storage_read_fault(self: *FaultInjector) StorageFault {
        // Assert invariant.
        assert(self.stats.storage_read_errors <= self.stats.total_injections);

        if (self.roll(self.cfg.storage_read_error_ppm)) {
            self.stats.storage_read_errors += 1;
            self.stats.total_injections += 1;
            return .read_error;
        }

        if (self.roll(self.cfg.storage_bitflip_ppm)) {
            self.stats.storage_bitflips += 1;
            self.stats.total_injections += 1;
            return .bitflip;
        }

        if (self.roll(self.cfg.storage_gray_failure_ppm)) {
            self.stats.storage_gray_failures += 1;
            self.stats.total_injections += 1;
            return .gray_failure;
        }

        return .none;
    }

    /// Maybe inject a storage write fault.
    pub fn maybe_storage_write_fault(self: *FaultInjector) StorageFault {
        // Assert invariant.
        assert(self.stats.storage_write_errors <= self.stats.total_injections);

        if (self.roll(self.cfg.storage_write_error_ppm)) {
            self.stats.storage_write_errors += 1;
            self.stats.total_injections += 1;
            return .write_error;
        }

        if (self.roll(self.cfg.storage_lost_write_ppm)) {
            self.stats.storage_lost_writes += 1;
            self.stats.total_injections += 1;
            return .lost_write;
        }

        if (self.roll(self.cfg.storage_gray_failure_ppm)) {
            self.stats.storage_gray_failures += 1;
            self.stats.total_injections += 1;
            return .gray_failure;
        }

        return .none;
    }

    // Network Faults

    /// Maybe inject a network fault.
    pub fn maybe_network_fault(self: *FaultInjector) NetworkFault {
        // Assert invariant.
        assert(self.stats.network_drops <= self.stats.total_injections);

        if (self.roll(self.cfg.network_drop_ppm)) {
            self.stats.network_drops += 1;
            self.stats.total_injections += 1;
            return .drop;
        }

        if (self.roll(self.cfg.network_reorder_ppm)) {
            self.stats.network_reorders += 1;
            self.stats.total_injections += 1;
            return .reorder;
        }

        if (self.roll(self.cfg.network_duplicate_ppm)) {
            self.stats.network_duplicates += 1;
            self.stats.total_injections += 1;
            return .duplicate;
        }

        if (self.roll(self.cfg.network_corrupt_ppm)) {
            self.stats.network_corruptions += 1;
            self.stats.total_injections += 1;
            return .corrupt;
        }

        if (self.roll(self.cfg.network_delay_ppm)) {
            self.stats.network_delays += 1;
            self.stats.total_injections += 1;
            return .delay;
        }

        return .none;
    }

    /// Get a random delay tick count.
    pub fn delay_ticks(self: *FaultInjector) u32 {
        // Assert precondition.
        assert(self.cfg.max_network_delay_ticks > 0);

        const ticks = self.prng.range_u32(self.cfg.max_network_delay_ticks) + 1;

        // Assert postcondition.
        assert(ticks >= 1);
        assert(ticks <= self.cfg.max_network_delay_ticks);

        return ticks;
    }

    // Data Corruption

    /// Maybe corrupt a byte buffer.
    pub fn maybe_corrupt_bytes(self: *FaultInjector, buffer: []u8, fault_type: StorageFault) void {
        // Assert preconditions.
        assert(buffer.len > 0);
        assert(buffer.len <= 1 << 20);

        if (fault_type != .bitflip) return;

        // Flip 1-8 bits.
        const flip_count = self.prng.range_u32(8) + 1;

        var i: u32 = 0;
        while (i < flip_count) : (i += 1) {
            const byte_index = self.prng.range_u32(@intCast(buffer.len));
            const bit_index = self.prng.range_u32(8);

            // Assert indices.
            assert(byte_index < buffer.len);
            assert(bit_index < 8);

            buffer[byte_index] ^= @as(u8, 1) << @intCast(bit_index);
        }
    }

    /// Maybe corrupt network packet data.
    pub fn maybe_corrupt_packet(self: *FaultInjector, buffer: []u8, fault_type: NetworkFault) void {
        // Assert precondition.
        assert(buffer.len > 0);

        if (fault_type != .corrupt) return;

        // Corrupt 1-4 bytes.
        const corrupt_count = self.prng.range_u32(4) + 1;

        var i: u32 = 0;
        while (i < corrupt_count) : (i += 1) {
            const index = self.prng.range_u32(@intCast(buffer.len));

            // Assert index.
            assert(index < buffer.len);

            buffer[index] = @truncate(self.prng.next());
        }
    }

    // Time Faults

    /// Get clock skew value in nanoseconds.
    pub fn clock_skew_ns(self: *FaultInjector) i64 {
        if (!self.roll(self.cfg.clock_skew_ppm)) return 0;

        const max = self.cfg.max_clock_skew_ns;

        // Assert precondition.
        assert(max > 0);

        const magnitude = self.prng.range_u64(@intCast(max));
        const sign: i64 = if (self.prng.coin_flip()) 1 else -1;

        const skew = sign * @as(i64, @intCast(magnitude));

        // Assert postcondition.
        assert(skew >= -max);
        assert(skew <= max);

        self.stats.clock_skews += 1;
        self.stats.total_injections += 1;

        return skew;
    }

    // Memory Faults

    /// Maybe fail a memory allocation.
    pub fn maybe_alloc_fail(self: *FaultInjector) bool {
        if (self.roll(self.cfg.memory_alloc_fail_ppm)) {
            self.stats.memory_alloc_failures += 1;
            self.stats.total_injections += 1;
            return true;
        }
        return false;
    }

    // Helpers

    /// Roll the dice for a fault.
    fn roll(self: *FaultInjector, ppm_chance: u32) bool {
        // Assert precondition.
        assert(ppm_chance <= FaultConfig.ppm);

        if (ppm_chance == 0) return false;
        if (ppm_chance >= FaultConfig.ppm) return true;

        return self.prng.range_u32(FaultConfig.ppm) < ppm_chance;
    }

    /// Get current fault statistics.
    pub fn get_stats(self: *const FaultInjector) FaultStats {
        return self.stats;
    }

    /// Reset statistics.
    pub fn reset_stats(self: *FaultInjector) void {
        self.stats = FaultStats{};

        // Assert postcondition.
        assert(self.stats.total_injections == 0);
    }
};

// Fault Statistics

/// Statistics tracking for fault injection.
pub const FaultStats = struct {
    total_injections: u64 = 0,

    // Storage faults.
    storage_read_errors: u64 = 0,
    storage_write_errors: u64 = 0,
    storage_bitflips: u64 = 0,
    storage_lost_writes: u64 = 0,
    storage_gray_failures: u64 = 0,

    // Network faults.
    network_drops: u64 = 0,
    network_reorders: u64 = 0,
    network_duplicates: u64 = 0,
    network_corruptions: u64 = 0,
    network_delays: u64 = 0,

    // Memory faults.
    memory_corruptions: u64 = 0,
    memory_alloc_failures: u64 = 0,

    // Time faults.
    clock_skews: u64 = 0,

    /// Validate statistics consistency.
    pub fn validate(self: *const FaultStats) bool {
        const storage_total = self.storage_read_errors +
            self.storage_write_errors +
            self.storage_bitflips +
            self.storage_lost_writes +
            self.storage_gray_failures;

        const network_total = self.network_drops +
            self.network_reorders +
            self.network_duplicates +
            self.network_corruptions +
            self.network_delays;

        const memory_total = self.memory_corruptions +
            self.memory_alloc_failures;

        const computed_total = storage_total + network_total + memory_total + self.clock_skews;

        return computed_total == self.total_injections;
    }
};

// Tests

test "FaultInjector.init creates valid injector" {
    const injector = FaultInjector.init(12345, FaultConfig.none());
    try std.testing.expectEqual(@as(u64, 0), injector.stats.total_injections);
}

test "FaultConfig.none injects no faults" {
    var injector = FaultInjector.init(99999, FaultConfig.none());

    var i: u32 = 0;
    while (i < 10000) : (i += 1) {
        try std.testing.expectEqual(StorageFault.none, injector.maybe_storage_read_fault());
        try std.testing.expectEqual(StorageFault.none, injector.maybe_storage_write_fault());
        try std.testing.expectEqual(NetworkFault.none, injector.maybe_network_fault());
    }

    try std.testing.expectEqual(@as(u64, 0), injector.stats.total_injections);
}

test "FaultInjector is deterministic" {
    var injector1 = FaultInjector.init(42, FaultConfig.aggressive());
    var injector2 = FaultInjector.init(42, FaultConfig.aggressive());

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        try std.testing.expectEqual(
            injector1.maybe_storage_read_fault(),
            injector2.maybe_storage_read_fault(),
        );
        try std.testing.expectEqual(
            injector1.maybe_network_fault(),
            injector2.maybe_network_fault(),
        );
    }
}

test "FaultConfig.aggressive injects some faults" {
    var injector = FaultInjector.init(777, FaultConfig.aggressive());

    var i: u32 = 0;
    while (i < 10000) : (i += 1) {
        _ = injector.maybe_storage_read_fault();
        _ = injector.maybe_network_fault();
    }

    try std.testing.expect(injector.stats.total_injections > 0);
}

test "FaultConfig.chaos injects many faults" {
    var injector = FaultInjector.init(888, FaultConfig.chaos());

    var i: u32 = 0;
    while (i < 10000) : (i += 1) {
        _ = injector.maybe_storage_read_fault();
        _ = injector.maybe_network_fault();
    }

    // Chaos should inject more faults than aggressive.
    try std.testing.expect(injector.stats.total_injections > 1000);
}

test "FaultStats.validate checks consistency" {
    var injector = FaultInjector.init(888, FaultConfig.mild());

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        _ = injector.maybe_storage_read_fault();
        _ = injector.maybe_network_fault();
    }

    try std.testing.expect(injector.stats.validate());
}

test "FaultInjector.maybe_corrupt_bytes flips bits" {
    var injector = FaultInjector.init(111, FaultConfig.aggressive());
    var buffer = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    const original = buffer;

    injector.maybe_corrupt_bytes(&buffer, .bitflip);

    // At least one byte should be different.
    var different = false;
    for (buffer, 0..) |byte, i| {
        if (byte != original[i]) different = true;
    }
    try std.testing.expect(different);
}

test "FaultInjector.maybe_corrupt_bytes does nothing for non-bitflip" {
    var injector = FaultInjector.init(222, FaultConfig.aggressive());
    var buffer = [_]u8{ 1, 2, 3, 4 };
    const original = buffer;

    injector.maybe_corrupt_bytes(&buffer, .none);
    try std.testing.expectEqualSlices(u8, &original, &buffer);

    injector.maybe_corrupt_bytes(&buffer, .read_error);
    try std.testing.expectEqualSlices(u8, &original, &buffer);
}

test "FaultInjector.delay_ticks returns bounded value" {
    var injector = FaultInjector.init(222, FaultConfig.aggressive());

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const ticks = injector.delay_ticks();
        try std.testing.expect(ticks >= 1);
        try std.testing.expect(ticks <= injector.cfg.max_network_delay_ticks);
    }
}

test "FaultInjector.reset_stats clears counters" {
    var injector = FaultInjector.init(333, FaultConfig.aggressive());

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        _ = injector.maybe_storage_read_fault();
    }

    try std.testing.expect(injector.stats.total_injections > 0);

    injector.reset_stats();

    try std.testing.expectEqual(@as(u64, 0), injector.stats.total_injections);
}

test "FaultConfig presets have correct relationship" {
    const none_cfg = FaultConfig.none();
    const mild_cfg = FaultConfig.mild();
    const aggressive_cfg = FaultConfig.aggressive();
    const chaos_cfg = FaultConfig.chaos();

    // None should have all zeros.
    try std.testing.expectEqual(@as(u32, 0), none_cfg.network_drop_ppm);

    // Mild < Aggressive < Chaos.
    try std.testing.expect(mild_cfg.network_drop_ppm < aggressive_cfg.network_drop_ppm);
    try std.testing.expect(aggressive_cfg.network_drop_ppm < chaos_cfg.network_drop_ppm);
}

test "FaultInjector.clock_skew_ns returns bounded values" {
    var injector = FaultInjector.init(444, FaultConfig.chaos());

    var non_zero_count: u32 = 0;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const skew = injector.clock_skew_ns();

        // Should be within bounds.
        try std.testing.expect(skew >= -injector.cfg.max_clock_skew_ns);
        try std.testing.expect(skew <= injector.cfg.max_clock_skew_ns);

        if (skew != 0) non_zero_count += 1;
    }

    // Should have some non-zero skews with chaos config.
    try std.testing.expect(non_zero_count > 0);
}
