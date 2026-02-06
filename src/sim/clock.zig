//! Virtual Clock for deterministic simulation.

const std = @import("std");
const assert = std.debug.assert;
const config = @import("tau").config;

const log = std.log.scoped(.clock);

// Re-export time constants from config for convenience.
pub const ns_per_us = config.time.ns_per_us;
pub const ns_per_ms = config.time.ns_per_ms;
pub const ns_per_sec = config.time.ns_per_sec;
pub const ns_per_min = config.time.ns_per_min;
pub const ns_per_hour = config.time.ns_per_hour;
pub const ns_per_day = config.time.ns_per_day;
pub const ns_per_year = config.time.ns_per_year;
pub const ns_per_century = config.time.ns_per_century;

/// Virtual clock for simulation. Time only advances explicitly.
pub const Clock = struct {
    /// Current simulated time in nanoseconds since epoch.
    now_ns: i64,

    /// Monotonic tick counter. Never decreases.
    tick_count: u64,

    /// Maximum time jump allowed in a single advance (safety bound).
    max_advance_ns: i64,

    // Constants

    /// Minimum time value (epoch start).
    const epoch_min: i64 = 0;

    /// Maximum time value (prevent overflow).
    const epoch_max: i64 = std.math.maxInt(i64) - ns_per_century;

    /// Maximum tick count.
    const tick_max: u64 = std.math.maxInt(u64) - 1;

    /// Default maximum advance (1 year).
    const default_max_advance: i64 = ns_per_year;

    // Initialization

    /// Create a clock starting at the given epoch time.
    pub fn init(start_ns: i64) Clock {
        // Assert precondition: start time is within valid range.
        assert(start_ns >= epoch_min);
        assert(start_ns <= epoch_max);

        const self = Clock{
            .now_ns = start_ns,
            .tick_count = 0,
            .max_advance_ns = default_max_advance,
        };

        // Assert postconditions.
        assert(self.now_ns == start_ns);
        assert(self.tick_count == 0);
        assert(self.max_advance_ns > 0);

        return self;
    }

    /// Create a clock starting at epoch zero.
    pub fn init_zero() Clock {
        return init(0);
    }

    /// Create a clock starting at a specific year.
    pub fn init_year(year: i32) Clock {
        // Assert precondition: year is reasonable.
        assert(year >= 1970);
        assert(year <= 3000);

        const years_since_epoch: i64 = @as(i64, year) - 1970;

        // Assert: no overflow.
        assert(years_since_epoch >= 0);
        assert(years_since_epoch < 1100);

        const start_ns = years_since_epoch * ns_per_year;

        // Assert: computed time is valid.
        assert(start_ns >= epoch_min);
        assert(start_ns <= epoch_max);

        return init(start_ns);
    }

    // Accessors

    /// Get current simulated time in nanoseconds.
    pub fn now(self: *const Clock) i64 {
        // Assert invariant: time is always valid.
        assert(self.now_ns >= epoch_min);
        assert(self.now_ns <= epoch_max);

        return self.now_ns;
    }

    /// Get current tick count.
    pub fn ticks(self: *const Clock) u64 {
        // Assert invariant: tick count is bounded.
        assert(self.tick_count <= tick_max);

        return self.tick_count;
    }

    // Time Advancement

    /// Advance time by the given number of nanoseconds.
    pub fn advance_ns(self: *Clock, delta_ns: i64) i64 {
        // Assert preconditions.
        assert(delta_ns >= 0);
        assert(delta_ns <= self.max_advance_ns);
        assert(self.now_ns <= epoch_max - delta_ns);
        assert(self.tick_count < tick_max);

        const old_time = self.now_ns;
        const old_ticks = self.tick_count;

        self.now_ns += delta_ns;
        self.tick_count += 1;

        // Assert postconditions: time moved forward.
        assert(self.now_ns >= old_time);
        assert(self.now_ns == old_time + delta_ns);
        assert(self.tick_count == old_ticks + 1);

        return self.now_ns;
    }

    /// Advance time by microseconds.
    pub fn advance_us(self: *Clock, delta_us: i64) i64 {
        // Assert precondition.
        assert(delta_us >= 0);
        assert(delta_us <= @divFloor(self.max_advance_ns, ns_per_us));

        return self.advance_ns(delta_us * ns_per_us);
    }

    /// Advance time by milliseconds.
    pub fn advance_ms(self: *Clock, delta_ms: i64) i64 {
        // Assert precondition.
        assert(delta_ms >= 0);
        assert(delta_ms <= @divFloor(self.max_advance_ns, ns_per_ms));

        return self.advance_ns(delta_ms * ns_per_ms);
    }

    /// Advance time by seconds.
    pub fn advance_sec(self: *Clock, delta_sec: i64) i64 {
        // Assert precondition.
        assert(delta_sec >= 0);
        assert(delta_sec <= @divFloor(self.max_advance_ns, ns_per_sec));

        return self.advance_ns(delta_sec * ns_per_sec);
    }

    /// Advance time by days.
    pub fn advance_days(self: *Clock, delta_days: i32) i64 {
        // Assert precondition.
        assert(delta_days >= 0);
        assert(delta_days <= 365);

        return self.advance_ns(@as(i64, delta_days) * ns_per_day);
    }

    /// Advance time by years (for long-running simulations).
    pub fn advance_years(self: *Clock, delta_years: i32) i64 {
        // Assert precondition: reasonable year range.
        assert(delta_years >= 0);
        assert(delta_years <= 100);

        // Temporarily increase max advance for century-scale jumps.
        const old_max = self.max_advance_ns;
        self.max_advance_ns = ns_per_century;

        const delta_ns = @as(i64, delta_years) * ns_per_year;

        // Assert: no overflow.
        assert(delta_ns >= 0);
        assert(self.now_ns <= epoch_max - delta_ns);

        const result = self.advance_ns(delta_ns);

        // Restore max advance.
        self.max_advance_ns = old_max;

        return result;
    }

    // Configuration

    /// Set the maximum allowed time advance (for safety tuning).
    pub fn set_max_advance(self: *Clock, max_ns: i64) void {
        // Assert preconditions.
        assert(max_ns > 0);
        assert(max_ns <= ns_per_century);

        self.max_advance_ns = max_ns;

        // Assert postcondition.
        assert(self.max_advance_ns == max_ns);
    }

    // Elapsed Time

    /// Get elapsed time since a previous timestamp.
    pub fn elapsed_since(self: *const Clock, previous_ns: i64) i64 {
        // Assert preconditions.
        assert(previous_ns >= epoch_min);
        assert(previous_ns <= self.now_ns);

        const elapsed = self.now_ns - previous_ns;

        // Assert postcondition.
        assert(elapsed >= 0);

        return elapsed;
    }

    /// Check if a duration has passed since a timestamp.
    pub fn has_elapsed(self: *const Clock, since_ns: i64, duration_ns: i64) bool {
        // Assert preconditions.
        assert(since_ns >= epoch_min);
        assert(duration_ns >= 0);

        if (since_ns > self.now_ns) return false;

        return self.elapsed_since(since_ns) >= duration_ns;
    }

    // Formatting

    /// Format current time as a human-readable string.
    pub fn format_time(self: *const Clock, buffer: *[32]u8) []const u8 {
        const time_ns = self.now_ns;

        // Assert precondition.
        assert(time_ns >= epoch_min);

        const years = @divFloor(time_ns, ns_per_year);
        const days = @divFloor(@mod(time_ns, ns_per_year), ns_per_day);
        const hours = @divFloor(@mod(time_ns, ns_per_day), ns_per_hour);
        const mins = @divFloor(@mod(time_ns, ns_per_hour), ns_per_min);
        const secs = @divFloor(@mod(time_ns, ns_per_min), ns_per_sec);

        return std.fmt.bufPrint(buffer, "Y{d}:D{d}:{d:0>2}:{d:0>2}:{d:0>2}", .{
            years + 1970,
            days,
            hours,
            mins,
            secs,
        }) catch "FORMAT_ERR";
    }
};

// Tests

test "Clock.init creates valid clock" {
    const clock = Clock.init(1000);
    try std.testing.expectEqual(@as(i64, 1000), clock.now());
    try std.testing.expectEqual(@as(u64, 0), clock.ticks());
}

test "Clock.init_zero starts at epoch" {
    const clock = Clock.init_zero();
    try std.testing.expectEqual(@as(i64, 0), clock.now());
    try std.testing.expectEqual(@as(u64, 0), clock.ticks());
}

test "Clock.init_year computes correct start time" {
    const clock = Clock.init_year(2020);
    const expected = @as(i64, 50) * ns_per_year;
    try std.testing.expectEqual(expected, clock.now());
}

test "Clock.init_year 1970 is epoch" {
    const clock = Clock.init_year(1970);
    try std.testing.expectEqual(@as(i64, 0), clock.now());
}

test "Clock.advance_ns moves time forward" {
    var clock = Clock.init_zero();

    const new_time = clock.advance_ns(1000);

    try std.testing.expectEqual(@as(i64, 1000), new_time);
    try std.testing.expectEqual(@as(i64, 1000), clock.now());
    try std.testing.expectEqual(@as(u64, 1), clock.ticks());
}

test "Clock.advance_ns is cumulative" {
    var clock = Clock.init_zero();

    _ = clock.advance_ns(100);
    _ = clock.advance_ns(200);
    _ = clock.advance_ns(300);

    try std.testing.expectEqual(@as(i64, 600), clock.now());
    try std.testing.expectEqual(@as(u64, 3), clock.ticks());
}

test "Clock.advance_sec moves time by seconds" {
    var clock = Clock.init_zero();

    _ = clock.advance_sec(60);

    try std.testing.expectEqual(@as(i64, 60) * ns_per_sec, clock.now());
}

test "Clock.advance_ms moves time by milliseconds" {
    var clock = Clock.init_zero();

    _ = clock.advance_ms(500);

    try std.testing.expectEqual(@as(i64, 500) * ns_per_ms, clock.now());
}

test "Clock.advance_days moves time by days" {
    var clock = Clock.init_zero();

    _ = clock.advance_days(7);

    try std.testing.expectEqual(@as(i64, 7) * ns_per_day, clock.now());
}

test "Clock.advance_years handles long durations" {
    var clock = Clock.init_year(1970);

    _ = clock.advance_years(100);

    const expected = @as(i64, 100) * ns_per_year;
    try std.testing.expectEqual(expected, clock.now());
}

test "Clock.elapsed_since computes difference" {
    var clock = Clock.init_zero();
    const start = clock.now();

    _ = clock.advance_ms(500);

    try std.testing.expectEqual(@as(i64, 500) * ns_per_ms, clock.elapsed_since(start));
}

test "Clock.has_elapsed checks duration correctly" {
    var clock = Clock.init_zero();
    const start = clock.now();

    try std.testing.expect(!clock.has_elapsed(start, ns_per_sec));

    _ = clock.advance_sec(2);

    try std.testing.expect(clock.has_elapsed(start, ns_per_sec));
}

test "Clock.has_elapsed handles future timestamp" {
    var clock = Clock.init(1000);

    // Future timestamp should return false.
    try std.testing.expect(!clock.has_elapsed(2000, 0));
}

test "Clock.ticks increments on each advance" {
    var clock = Clock.init_zero();

    try std.testing.expectEqual(@as(u64, 0), clock.ticks());

    _ = clock.advance_ns(100);
    try std.testing.expectEqual(@as(u64, 1), clock.ticks());

    _ = clock.advance_ns(100);
    try std.testing.expectEqual(@as(u64, 2), clock.ticks());

    _ = clock.advance_ns(100);
    try std.testing.expectEqual(@as(u64, 3), clock.ticks());
}

test "Clock.format_time produces readable output" {
    var clock = Clock.init_year(2025);
    var buffer: [32]u8 = undefined;

    const formatted = clock.format_time(&buffer);

    // Should start with year 2025.
    try std.testing.expect(std.mem.startsWith(u8, formatted, "Y2025"));
}

test "Clock.set_max_advance changes limit" {
    var clock = Clock.init_zero();

    clock.set_max_advance(1000);
    try std.testing.expectEqual(@as(i64, 1000), clock.max_advance_ns);

    clock.set_max_advance(ns_per_day);
    try std.testing.expectEqual(ns_per_day, clock.max_advance_ns);
}

test "time constants are consistent" {
    try std.testing.expectEqual(@as(i64, 1000), ns_per_us);
    try std.testing.expectEqual(@as(i64, 1_000_000), ns_per_ms);
    try std.testing.expectEqual(@as(i64, 1_000_000_000), ns_per_sec);
    try std.testing.expectEqual(@as(i64, 60) * ns_per_sec, ns_per_min);
    try std.testing.expectEqual(@as(i64, 60) * ns_per_min, ns_per_hour);
    try std.testing.expectEqual(@as(i64, 24) * ns_per_hour, ns_per_day);
    try std.testing.expectEqual(@as(i64, 365) * ns_per_day, ns_per_year);
}
