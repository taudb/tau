//! Observability simulation scenario.
//!
//! Verifies that the metrics subsystem correctly tracks all
//! server operations under deterministic simulated load.
//! Exercises atomic counters, Prometheus text formatting,
//! and invariant checking between counters and catalog state.

const std = @import("std");
const assert = std.debug.assert;

const tau = @import("tau");
const config = tau.config;

const PRNG = @import("../prng.zig").PRNG;
const Clock = @import("../clock.zig").Clock;
const ns_per_day = @import("../clock.zig").ns_per_day;
const FaultInjector = @import("../faults.zig").FaultInjector;
const FaultConfig = @import("../faults.zig").FaultConfig;

const catalog_mod = @import("catalog");
const metrics_mod = @import("metrics");
const protocol = @import("protocol");

const log = std.log.scoped(.o11y);

pub const O11yResult = struct {
    seed: u64,
    passed: bool,
    simulated_days: u32,
    total_requests: u64,
    total_errors: u64,
    total_connections: u64,
    scrapes: u32,
    invariant_violations: u32,
    failure_reason: ?FailureReason,

    pub const FailureReason = enum {
        counter_mismatch,
        format_error,
        series_count_mismatch,
        monotonicity_violated,
    };
};

pub fn run(allocator: std.mem.Allocator, seed: u64, simulated_days: u32) O11yResult {
    assert(seed >= 1);
    assert(simulated_days > 0);
    assert(simulated_days <= 365 * 10);

    var prng = PRNG.init(seed);
    var counters = metrics_mod.Counters.init();
    var catalog = catalog_mod.Catalog.init(allocator);
    defer catalog.deinit();

    var expected_requests = std.mem.zeroes([std.meta.fields(protocol.Opcode).len]u64);
    var expected_errors = std.mem.zeroes([std.meta.fields(protocol.StatusCode).len]u64);
    var expected_connections_total: u64 = 0;
    var expected_connections_active: u64 = 0;
    var series_created: u32 = 0;
    var violations: u32 = 0;
    var scrapes: u32 = 0;

    var day: u32 = 0;
    while (day < simulated_days) : (day += 1) {
        const ops_today = prng.range_u32(50) + 10;
        var op: u32 = 0;
        while (op < ops_today) : (op += 1) {
            const roll = prng.range_u32(100);

            if (roll < 10) {
                counters.connection_opened();
                expected_connections_total += 1;
                expected_connections_active += 1;
            } else if (roll < 15 and expected_connections_active > 0) {
                counters.connection_closed();
                expected_connections_active -= 1;
            } else if (roll < 40) {
                counters.inc_request(.append);
                expected_requests[@intFromEnum(protocol.Opcode.append)] += 1;
            } else if (roll < 55) {
                counters.inc_request(.query_point);
                expected_requests[@intFromEnum(protocol.Opcode.query_point)] += 1;
            } else if (roll < 65) {
                counters.inc_request(.ping);
                expected_requests[@intFromEnum(protocol.Opcode.ping)] += 1;
            } else if (roll < 75) {
                counters.inc_request(.create_series);
                expected_requests[@intFromEnum(protocol.Opcode.create_series)] += 1;

                var label = [_]u8{0} ** catalog_mod.label_length;
                const name = std.fmt.bufPrint(&label, "sim_{d}", .{series_created}) catch unreachable;
                _ = name;
                catalog.create_series(label) catch {};
                series_created += 1;
            } else if (roll < 80) {
                counters.inc_error(.auth_failed);
                expected_errors[@intFromEnum(protocol.StatusCode.auth_failed)] += 1;
            } else if (roll < 85) {
                counters.inc_error(.series_not_found);
                expected_errors[@intFromEnum(protocol.StatusCode.series_not_found)] += 1;
            } else if (roll < 90) {
                counters.inc_error(.invalid_payload);
                expected_errors[@intFromEnum(protocol.StatusCode.invalid_payload)] += 1;
            } else if (roll < 95) {
                counters.inc_request(.connect);
                expected_requests[@intFromEnum(protocol.Opcode.connect)] += 1;
            } else {
                counters.inc_error(.bad_magic);
                expected_errors[@intFromEnum(protocol.StatusCode.bad_magic)] += 1;
            }
        }

        // Scrape metrics periodically (every 15 simulated days).
        if (day % 15 == 0) {
            var buf: [16384]u8 = undefined;
            const output = metrics_mod.format_metrics(
                &counters,
                &catalog,
                &buf,
            ) catch {
                return .{
                    .seed = seed,
                    .passed = false,
                    .simulated_days = day,
                    .total_requests = sum_array(&expected_requests),
                    .total_errors = sum_array(&expected_errors),
                    .total_connections = expected_connections_total,
                    .scrapes = scrapes,
                    .invariant_violations = violations,
                    .failure_reason = .format_error,
                };
            };
            scrapes += 1;

            // Invariant: output contains required metric families.
            if (std.mem.indexOf(u8, output, "tau_connections_active") == null or
                std.mem.indexOf(u8, output, "tau_connections_total") == null or
                std.mem.indexOf(u8, output, "tau_requests_total") == null or
                std.mem.indexOf(u8, output, "tau_errors_total") == null or
                std.mem.indexOf(u8, output, "tau_series_count") == null or
                std.mem.indexOf(u8, output, "tau_uptime_seconds") == null)
            {
                violations += 1;
            }
        }
    }

    // Final invariant checks.

    // 1. Connection counters.
    if (counters.connections_total.load(.monotonic) != expected_connections_total) {
        violations += 1;
        return result_from(seed, simulated_days, &expected_requests, &expected_errors, expected_connections_total, scrapes, violations, .counter_mismatch);
    }
    if (counters.connections_active.load(.monotonic) != expected_connections_active) {
        violations += 1;
        return result_from(seed, simulated_days, &expected_requests, &expected_errors, expected_connections_total, scrapes, violations, .counter_mismatch);
    }

    // 2. Request counters.
    if (counters.requests_append.load(.monotonic) != expected_requests[@intFromEnum(protocol.Opcode.append)]) {
        violations += 1;
        return result_from(seed, simulated_days, &expected_requests, &expected_errors, expected_connections_total, scrapes, violations, .counter_mismatch);
    }
    if (counters.requests_query_point.load(.monotonic) != expected_requests[@intFromEnum(protocol.Opcode.query_point)]) {
        violations += 1;
        return result_from(seed, simulated_days, &expected_requests, &expected_errors, expected_connections_total, scrapes, violations, .counter_mismatch);
    }
    if (counters.requests_ping.load(.monotonic) != expected_requests[@intFromEnum(protocol.Opcode.ping)]) {
        violations += 1;
        return result_from(seed, simulated_days, &expected_requests, &expected_errors, expected_connections_total, scrapes, violations, .counter_mismatch);
    }
    if (counters.requests_connect.load(.monotonic) != expected_requests[@intFromEnum(protocol.Opcode.connect)]) {
        violations += 1;
        return result_from(seed, simulated_days, &expected_requests, &expected_errors, expected_connections_total, scrapes, violations, .counter_mismatch);
    }

    // 3. Error counters.
    if (counters.errors_auth_failed.load(.monotonic) != expected_errors[@intFromEnum(protocol.StatusCode.auth_failed)]) {
        violations += 1;
        return result_from(seed, simulated_days, &expected_requests, &expected_errors, expected_connections_total, scrapes, violations, .counter_mismatch);
    }
    if (counters.errors_series_not_found.load(.monotonic) != expected_errors[@intFromEnum(protocol.StatusCode.series_not_found)]) {
        violations += 1;
        return result_from(seed, simulated_days, &expected_requests, &expected_errors, expected_connections_total, scrapes, violations, .counter_mismatch);
    }

    // 4. Series count matches catalog.
    catalog.lock.lockShared();
    const catalog_count = catalog.actor_map.count();
    catalog.lock.unlockShared();

    var buf: [16384]u8 = undefined;
    const final_output = metrics_mod.format_metrics(&counters, &catalog, &buf) catch {
        return result_from(seed, simulated_days, &expected_requests, &expected_errors, expected_connections_total, scrapes, violations + 1, .format_error);
    };

    var expected_series_str: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&expected_series_str, "tau_series_count {d}\n", .{catalog_count}) catch unreachable;
    if (std.mem.indexOf(u8, final_output, needle) == null) {
        violations += 1;
        return result_from(seed, simulated_days, &expected_requests, &expected_errors, expected_connections_total, scrapes, violations, .series_count_mismatch);
    }

    return result_from(seed, simulated_days, &expected_requests, &expected_errors, expected_connections_total, scrapes, violations, null);
}

fn sum_array(arr: []const u64) u64 {
    var total: u64 = 0;
    for (arr) |v| total += v;
    return total;
}

fn result_from(
    seed: u64,
    simulated_days: u32,
    expected_requests: []const u64,
    expected_errors: []const u64,
    expected_connections_total: u64,
    scrapes: u32,
    violations: u32,
    failure_reason: ?O11yResult.FailureReason,
) O11yResult {
    return .{
        .seed = seed,
        .passed = violations == 0 and failure_reason == null,
        .simulated_days = simulated_days,
        .total_requests = sum_array(expected_requests),
        .total_errors = sum_array(expected_errors),
        .total_connections = expected_connections_total,
        .scrapes = scrapes,
        .invariant_violations = violations,
        .failure_reason = failure_reason,
    };
}

// Tests

const testing = std.testing;

test "o11y scenario passes with deterministic seed" {
    const result = run(testing.allocator, 42, 30);
    try testing.expect(result.passed);
    try testing.expectEqual(@as(u32, 0), result.invariant_violations);
    try testing.expect(result.total_requests > 0);
    try testing.expect(result.total_connections > 0);
    try testing.expect(result.scrapes > 0);
}

test "o11y scenario is deterministic" {
    const result1 = run(testing.allocator, 12345, 60);
    const result2 = run(testing.allocator, 12345, 60);

    try testing.expectEqual(result1.passed, result2.passed);
    try testing.expectEqual(result1.total_requests, result2.total_requests);
    try testing.expectEqual(result1.total_errors, result2.total_errors);
    try testing.expectEqual(result1.total_connections, result2.total_connections);
    try testing.expectEqual(result1.invariant_violations, result2.invariant_violations);
}

test "o11y scenario passes with multiple seeds" {
    const seeds = [_]u64{ 1, 99, 777, 54321, 999999 };
    for (seeds) |seed| {
        const result = run(testing.allocator, seed, 30);
        try testing.expect(result.passed);
    }
}

test "o11y scenario passes with long duration" {
    const result = run(testing.allocator, 42, 365);
    try testing.expect(result.passed);
    try testing.expect(result.scrapes > 20);
}
