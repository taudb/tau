//! Simulation Harness for deterministic testing.

const std = @import("std");
const assert = std.debug.assert;

const tau = @import("tau");
const config = tau.config;

const Clock = @import("clock.zig").Clock;
const ns_per_day = @import("clock.zig").ns_per_day;

const FaultInjector = @import("faults.zig").FaultInjector;
const FaultConfig = @import("faults.zig").FaultConfig;
const FaultStats = @import("faults.zig").FaultStats;

const PRNG = @import("prng.zig").PRNG;

const StateMachine = @import("state_machine.zig").StateMachine;
const Operation = @import("state_machine.zig").Operation;
const OpResult = @import("state_machine.zig").OpResult;

const log = std.log.scoped(.harness);

// Scenario Configuration

pub const ScenarioConfig = struct {
    seed: u64,
    duration_years: u32,
    ops_per_day: u32,
    fault_config: FaultConfig,
    invariant_check_interval: u32,
    max_operations: u64,

    /// Quick scenario.
    pub fn quick(seed: u64) ScenarioConfig {
        return .{
            .seed = seed,
            .duration_years = config.simulation.quick.duration_years,
            .ops_per_day = config.simulation.quick.ops_per_day,
            .fault_config = FaultConfig.none(),
            .invariant_check_interval = config.simulation.quick.invariant_check_interval,
            .max_operations = config.simulation.quick.max_operations,
        };
    }

    /// Standard scenario.
    pub fn standard(seed: u64) ScenarioConfig {
        return .{
            .seed = seed,
            .duration_years = config.simulation.standard.duration_years,
            .ops_per_day = config.simulation.standard.ops_per_day,
            .fault_config = FaultConfig.mild(),
            .invariant_check_interval = config.simulation.standard.invariant_check_interval,
            .max_operations = config.simulation.standard.max_operations,
        };
    }

    /// Century scenario.
    pub fn century(seed: u64) ScenarioConfig {
        return .{
            .seed = seed,
            .duration_years = config.simulation.century.duration_years,
            .ops_per_day = config.simulation.century.ops_per_day,
            .fault_config = FaultConfig.aggressive(),
            .invariant_check_interval = config.simulation.century.invariant_check_interval,
            .max_operations = config.simulation.century.max_operations,
        };
    }

    /// Chaos scenario.
    pub fn chaos(seed: u64) ScenarioConfig {
        return .{
            .seed = seed,
            .duration_years = config.simulation.chaos.duration_years,
            .ops_per_day = config.simulation.chaos.ops_per_day,
            .fault_config = FaultConfig.chaos(),
            .invariant_check_interval = config.simulation.chaos.invariant_check_interval,
            .max_operations = config.simulation.chaos.max_operations,
        };
    }
};

// Scenario Result

pub const ScenarioResult = struct {
    seed: u64,
    passed: bool,
    operations_executed: u64,
    simulated_years: u32,
    final_count: u32,
    invariant_violations: u64,
    faults_injected: u64,
    faults: FaultStats,
    failure_reason: ?FailureReason,
    duration_ns: u64,
    pub const FailureReason = enum {
        invariant_violated,
        operation_limit_exceeded,
        shadow_state_full,
        unexpected_error,
    };
};

pub const Harness = struct {
    const max_tracked_failures: u32 = config.simulation.max_tracked_failures;

    allocator: std.mem.Allocator,
    prng: PRNG,

    total_scenarios: u64,
    passed_scenarios: u64,
    failed_scenarios: u64,
    total_operations: u64,
    total_simulated_years: u64,

    failed_seeds: [max_tracked_failures]u64,
    failed_count: u32,

    // Lifecycle

    pub fn init(allocator: std.mem.Allocator, master_seed: u64) Harness {
        // Assert precondition.
        assert(master_seed >= 1);

        const self = Harness{
            .allocator = allocator,
            .prng = PRNG.init(master_seed),
            .total_scenarios = 0,
            .passed_scenarios = 0,
            .failed_scenarios = 0,
            .total_operations = 0,
            .total_simulated_years = 0,
            .failed_seeds = undefined,
            .failed_count = 0,
        };

        // Assert postconditions.
        assert(self.total_scenarios == 0);
        assert(self.failed_count == 0);

        return self;
    }

    // Scenario Execution

    pub fn run_scenario(self: *Harness, scenario_config: ScenarioConfig) ScenarioResult {
        // Assert preconditions.
        assert(scenario_config.seed >= 1);
        assert(scenario_config.duration_years > 0);
        assert(scenario_config.duration_years <= 10_000);
        assert(scenario_config.ops_per_day > 0);
        assert(scenario_config.ops_per_day <= 1_000_000);
        assert(scenario_config.invariant_check_interval > 0);

        const start_time = std.time.nanoTimestamp();

        // Initialize components.
        var clock = Clock.init_year(2000);
        var faults_injector = FaultInjector.init(scenario_config.seed, scenario_config.fault_config);
        var prng = PRNG.init(scenario_config.seed);

        var sm = StateMachine.init(self.allocator, &clock, &faults_injector) catch {
            return ScenarioResult{
                .seed = scenario_config.seed,
                .passed = false,
                .operations_executed = 0,
                .simulated_years = 0,
                .final_count = 0,
                .invariant_violations = 0,
                .faults_injected = 0,
                .faults = FaultStats{},
                .failure_reason = .unexpected_error,
                .duration_ns = 0,
            };
        };
        defer sm.deinit();

        var next_timestamp: i64 = clock.now();
        var ops_executed: u64 = 0;
        var years_completed: u32 = 0;
        var failure_reason: ?ScenarioResult.FailureReason = null;

        outer: while (years_completed < scenario_config.duration_years) {
            var day: u32 = 0;
            while (day < 365) : (day += 1) {
                var ops_today: u32 = 0;
                while (ops_today < scenario_config.ops_per_day) : (ops_today += 1) {
                    if (ops_executed >= scenario_config.max_operations) {
                        failure_reason = .operation_limit_exceeded;
                        break :outer;
                    }

                    if (sm.is_shadow_full()) {
                        failure_reason = .shadow_state_full;
                        break :outer;
                    }

                    const op = self.choose_operation(&prng, &sm);
                    const result = self.apply_operation(&sm, op, &prng, &next_timestamp);

                    ops_executed += 1;

                    if (result == .error_invariant_violated) {
                        failure_reason = .invariant_violated;
                        break :outer;
                    }

                    if (ops_executed % scenario_config.invariant_check_interval == 0) {
                        if (sm.verify_invariants() == .error_invariant_violated) {
                            failure_reason = .invariant_violated;
                            break :outer;
                        }
                    }
                }

                _ = clock.advance_ns(ns_per_day);
            }

            years_completed += 1;
        }

        if (failure_reason == null) {
            if (sm.verify_invariants() == .error_invariant_violated) {
                failure_reason = .invariant_violated;
            }
        }

        const end_time = std.time.nanoTimestamp();
        const duration = @as(u64, @intCast(end_time - start_time));

        const passed = (failure_reason == null) or
            (failure_reason == .shadow_state_full and sm.stats.invariant_violations == 0);

        self.total_scenarios += 1;
        self.total_operations += ops_executed;
        self.total_simulated_years += years_completed;

        if (passed) {
            self.passed_scenarios += 1;
        } else {
            self.failed_scenarios += 1;
            if (self.failed_count < max_tracked_failures) {
                self.failed_seeds[self.failed_count] = scenario_config.seed;
                self.failed_count += 1;
            }
        }

        // Assert statistics consistency.
        assert(self.passed_scenarios + self.failed_scenarios == self.total_scenarios);

        const sm_stats = sm.get_stats();
        const fault_stats = faults_injector.get_stats();

        return ScenarioResult{
            .seed = scenario_config.seed,
            .passed = passed,
            .operations_executed = ops_executed,
            .simulated_years = years_completed,
            .final_count = sm.count(),
            .invariant_violations = sm_stats.invariant_violations,
            .faults_injected = fault_stats.total_injections,
            .faults = fault_stats,
            .failure_reason = failure_reason,
            .duration_ns = duration,
        };
    }

    // Batch Execution

    pub fn run_scenarios(self: *Harness, count: u32, base_config: ScenarioConfig) void {
        // Assert precondition.
        assert(count > 0);
        assert(count <= 1_000_000);

        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const seed = self.prng.next();

            // Assert seed is valid.
            assert(seed > 0);

            var scenario_config = base_config;
            scenario_config.seed = seed;

            const result = self.run_scenario(scenario_config);

            if ((i + 1) % 100 == 0) {
                log.info("progress: {d}/{d} scenarios, {d} passed, {d} failed", .{
                    i + 1,
                    count,
                    self.passed_scenarios,
                    self.failed_scenarios,
                });
            }

            if (!result.passed) {
                log.err("failed: seed={d}, reason={?}, ops={d}, years={d}", .{
                    result.seed,
                    result.failure_reason,
                    result.operations_executed,
                    result.simulated_years,
                });
            }
        }
    }

    // Helpers

    fn choose_operation(self: *Harness, prng: *PRNG, sm: *const StateMachine) Operation {
        _ = self;

        const item_count = sm.count();

        if (item_count < 100) {
            if (prng.chance(9, 10)) return .append;
            return .lookup;
        }

        const roll = prng.range_u32(100);

        if (roll < 60) return .append;
        if (roll < 95) return .lookup;
        return .verify_invariants;
    }

    fn apply_operation(
        self: *Harness,
        sm: *StateMachine,
        op: Operation,
        prng: *PRNG,
        next_timestamp: *i64,
    ) OpResult {
        _ = self;

        switch (op) {
            .append => {
                const delta = prng.range_u32(1000) + 1;
                next_timestamp.* += delta;

                const value: i64 = @bitCast(prng.next());

                return sm.apply_append(next_timestamp.*, value);
            },
            .lookup => {
                const domain = sm.storageDomain();

                if (domain.is_empty()) {
                    return sm.apply_lookup(0);
                }

                if (prng.chance(70, 100)) {
                    const span = domain.end - domain.start;
                    if (span <= 0) {
                        return sm.apply_lookup(domain.start);
                    }
                    const offset: i64 = @intCast(prng.range_u64(@intCast(span)));
                    return sm.apply_lookup(domain.start + offset);
                } else {
                    if (prng.coin_flip()) {
                        return sm.apply_lookup(domain.start - @as(i64, prng.range_u32(1000)) - 1);
                    } else {
                        return sm.apply_lookup(domain.end + @as(i64, prng.range_u32(1000)) + 1);
                    }
                }
            },
            .verify_invariants => {
                return sm.verify_invariants();
            },
            .verify_domain, .verify_count, .noop => {
                return .skipped;
            },
        }
    }

    // Reporting

    pub fn log_summary(self: *const Harness) void {
        log.info("simulation complete: {d} scenarios, {d} passed, {d} failed", .{
            self.total_scenarios,
            self.passed_scenarios,
            self.failed_scenarios,
        });
        log.info("total operations: {d}, simulated years: {d}", .{
            self.total_operations,
            self.total_simulated_years,
        });

        if (self.failed_count > 0) {
            log.warn("failed seeds for replay:", .{});
            var i: u32 = 0;
            while (i < self.failed_count) : (i += 1) {
                log.warn("  seed={d}", .{self.failed_seeds[i]});
            }
        }
    }

    pub fn get_failed_seeds(self: *const Harness) []const u64 {
        return self.failed_seeds[0..self.failed_count];
    }
};

// Tests

test "Harness.init creates valid harness" {
    const harness = Harness.init(std.testing.allocator, 12345);
    try std.testing.expectEqual(@as(u64, 0), harness.total_scenarios);
    try std.testing.expectEqual(@as(u64, 0), harness.passed_scenarios);
}

test "Harness.run_scenario executes quick scenario" {
    var harness = Harness.init(std.testing.allocator, 99999);

    const scenario_config = ScenarioConfig.quick(42);
    const result = harness.run_scenario(scenario_config);

    try std.testing.expect(result.passed);
    try std.testing.expect(result.operations_executed > 0);
    try std.testing.expectEqual(@as(u64, 1), harness.total_scenarios);
}

test "Harness.run_scenario is deterministic" {
    var harness1 = Harness.init(std.testing.allocator, 11111);
    var harness2 = Harness.init(std.testing.allocator, 22222);

    const config1 = ScenarioConfig.quick(42);
    const config2 = ScenarioConfig.quick(42);

    const result1 = harness1.run_scenario(config1);
    const result2 = harness2.run_scenario(config2);

    try std.testing.expectEqual(result1.passed, result2.passed);
    try std.testing.expectEqual(result1.operations_executed, result2.operations_executed);
    try std.testing.expectEqual(result1.final_count, result2.final_count);
}

test "ScenarioConfig presets create valid configs" {
    const quick_cfg = ScenarioConfig.quick(1);
    try std.testing.expect(quick_cfg.duration_years > 0);
    try std.testing.expect(quick_cfg.ops_per_day > 0);

    const standard_cfg = ScenarioConfig.standard(1);
    try std.testing.expect(standard_cfg.duration_years > quick_cfg.duration_years);

    const century_cfg = ScenarioConfig.century(1);
    try std.testing.expectEqual(@as(u32, 100), century_cfg.duration_years);

    const chaos_cfg = ScenarioConfig.chaos(1);
    try std.testing.expect(chaos_cfg.fault_config.network_drop_ppm > 0);
}

test "Harness tracks failed seeds" {
    var harness = Harness.init(std.testing.allocator, 12345);

    // Run successful scenario.
    _ = harness.run_scenario(ScenarioConfig.quick(42));

    try std.testing.expectEqual(@as(u32, 0), harness.failed_count);
    try std.testing.expectEqual(@as(u64, 1), harness.passed_scenarios);
}
