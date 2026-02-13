//! Tau Simulation Runner

const std = @import("std");
const assert = std.debug.assert;

const tau = @import("tau");
const config = tau.config;

const Harness = @import("harness.zig").Harness;
const ScenarioConfig = @import("harness.zig").ScenarioConfig;
const o11y = @import("scenarios/o11y.zig");

const log = std.log.scoped(.sim);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Generate master seed from system time if not configured.
    const master_seed = blk: {
        if (config.simulation.default_seed != 0) {
            break :blk config.simulation.default_seed;
        }
        const time: u64 = @intCast(std.time.timestamp());
        break :blk time ^ 0x517cc1b727220a95;
    };

    // Assert seed is valid.
    assert(master_seed >= 1);

    const scenarios = config.simulation.default_scenarios;
    const mode = config.simulation.default_mode;

    log.info("tau simulation: seed={d}, scenarios={d}, mode={s}", .{
        master_seed,
        scenarios,
        @tagName(mode),
    });

    var harness = Harness.init(allocator, master_seed);

    const start_time = std.time.nanoTimestamp();

    switch (mode) {
        .quick => run_mode(&harness, scenarios, .quick),
        .standard => run_mode(&harness, scenarios, .standard),
        .century => run_mode(&harness, scenarios, .century),
        .chaos => run_mode(&harness, scenarios, .chaos),
    }

    const end_time = std.time.nanoTimestamp();
    const elapsed_ms = @divFloor(@as(u64, @intCast(end_time - start_time)), 1_000_000);

    harness.log_summary();

    log.info("wall clock time: {d}ms", .{elapsed_ms});

    if (harness.failed_scenarios > 0) {
        log.err("simulation found {d} failures", .{harness.failed_scenarios});
        std.process.exit(1);
    }

    log.info("all scenarios passed", .{});
}

fn run_mode(harness: *Harness, count: u32, mode: config.simulation.Mode) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const seed = harness.prng.next();

        // Assert seed is valid.
        assert(seed > 0);

        const scenario_config = switch (mode) {
            .quick => ScenarioConfig.quick(seed),
            .standard => ScenarioConfig.standard(seed),
            .century => ScenarioConfig.century(seed),
            .chaos => ScenarioConfig.chaos(seed),
        };

        const result = harness.run_scenario(scenario_config);

        const ops_sec = if (result.duration_ns != 0) result.operations_executed * 1_000_000_000 / result.duration_ns else 0;
        const outcome = if (result.passed) "PASS" else "FAIL";
        // SI formatting
        var ops_si_buf: [32]u8 = undefined;
        const ops_si = if (ops_sec >= 1_000_000)
            std.fmt.bufPrint(&ops_si_buf, "{d} Mops/s", .{ops_sec / 1_000_000}) catch "???"
        else if (ops_sec >= 1_000)
            std.fmt.bufPrint(&ops_si_buf, "{d} kops/s", .{ops_sec / 1_000}) catch "???"
        else
            std.fmt.bufPrint(&ops_si_buf, "{d} ops/s", .{ops_sec}) catch "???";

        log.info("[{d}/{d}] seed={d}: {s}, {d} ops, {d} years, {s}, {d} faults, {d}ms", .{
            i + 1,
            count,
            result.seed,
            outcome,
            result.operations_executed,
            result.simulated_years,
            ops_si,
            result.faults_injected,
            result.duration_ns / 1_000_000,
        });
        log.info("Faults: storage_read={d}, storage_write={d}, bitflip={d}, lost_write={d}, gray_failure={d}, network_drop={d}, network_reorder={d}, network_duplicate={d}, network_corrupt={d}, network_delay={d}, mem_corruption={d}, alloc_fail={d}, clock_skew={d}", .{
            result.faults.storage_read_errors,
            result.faults.storage_write_errors,
            result.faults.storage_bitflips,
            result.faults.storage_lost_writes,
            result.faults.storage_gray_failures,
            result.faults.network_drops,
            result.faults.network_reorders,
            result.faults.network_duplicates,
            result.faults.network_corruptions,
            result.faults.network_delays,
            result.faults.memory_corruptions,
            result.faults.memory_alloc_failures,
            result.faults.clock_skews,
        });
        log.info("Outcome: {s}, invariant violations: {d}", .{
            outcome,
            result.invariant_violations,
        });

        if (!result.passed) {
            log.err("failure reason: {?}, violations: {d}", .{
                result.failure_reason,
                result.invariant_violations,
            });
        }
    }
}
