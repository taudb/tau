//! Reusable benchmark harness for Tau.
//!
//! Provides a generic runner that accepts a slice of Scenario
//! descriptors, times each one, samples resource usage via
//! getrusage(2), and reports aggregate results.
//!
//! Resource metrics mirror those of time(1):
//!   - Wall clock time (elapsed real time).
//!   - User CPU time.
//!   - System CPU time.
//!   - Maximum resident set size (peak RSS).
//!   - Major page faults (required disk I/O).
//!   - Minor page faults (reclaimed without I/O).
//!   - Involuntary context switches.
//!   - Voluntary context switches (waits/yields).

const std = @import("std");
const linux = std.os.linux;

const log = std.log.scoped(.bench);

// --- Resource sampling via getrusage(2). ---

const ResourceSnapshot = struct {
    user_time_us: i64,
    system_time_us: i64,
    max_rss_kb: isize,
    major_faults: isize,
    minor_faults: isize,
    voluntary_context_switches: isize,
    involuntary_context_switches: isize,

    fn capture() ResourceSnapshot {
        var usage: linux.rusage = undefined;
        const result = linux.getrusage(
            linux.rusage.SELF,
            &usage,
        );
        std.debug.assert(result == 0);

        return .{
            .user_time_us = timeval_to_us(usage.utime),
            .system_time_us = timeval_to_us(usage.stime),
            .max_rss_kb = usage.maxrss,
            .major_faults = usage.majflt,
            .minor_faults = usage.minflt,
            .voluntary_context_switches = usage.nvcsw,
            .involuntary_context_switches = usage.nivcsw,
        };
    }

    fn timeval_to_us(tv: linux.timeval) i64 {
        return tv.sec * 1_000_000 + @as(i64, @intCast(tv.usec));
    }
};

pub const ResourceDelta = struct {
    user_time_us: i64,
    system_time_us: i64,
    max_rss_kb: isize,
    major_faults: isize,
    minor_faults: isize,
    voluntary_context_switches: isize,
    involuntary_context_switches: isize,

    fn between(
        before: ResourceSnapshot,
        after: ResourceSnapshot,
    ) ResourceDelta {
        return .{
            .user_time_us = after.user_time_us -
                before.user_time_us,
            .system_time_us = after.system_time_us -
                before.system_time_us,
            .max_rss_kb = after.max_rss_kb,
            .major_faults = after.major_faults -
                before.major_faults,
            .minor_faults = after.minor_faults -
                before.minor_faults,
            .voluntary_context_switches = after.voluntary_context_switches -
                before.voluntary_context_switches,
            .involuntary_context_switches = after.involuntary_context_switches -
                before.involuntary_context_switches,
        };
    }
};

// --- Result and Scenario. ---

pub const Result = struct {
    name: []const u8,
    iterations: u64,
    elapsed_ns_total: u64,
    elapsed_ns_min: u64,
    elapsed_ns_max: u64,
    resources: ResourceDelta,
    failed: bool,

    pub fn elapsed_ns_mean(self: Result) u64 {
        std.debug.assert(self.iterations > 0);
        return self.elapsed_ns_total / self.iterations;
    }
};

pub const Scenario = struct {
    name: []const u8,
    iterations: u64,
    run_fn: *const fn (std.mem.Allocator) anyerror!void,
};

// --- Runner. ---

fn make_failed_result(
    name: []const u8,
    iterations: u64,
    elapsed_ns_total: u64,
    elapsed_ns_min: u64,
    elapsed_ns_max: u64,
    before: ResourceSnapshot,
) Result {
    return Result{
        .name = name,
        .iterations = iterations,
        .elapsed_ns_total = elapsed_ns_total,
        .elapsed_ns_min = elapsed_ns_min,
        .elapsed_ns_max = elapsed_ns_max,
        .resources = ResourceDelta.between(
            before,
            ResourceSnapshot.capture(),
        ),
        .failed = true,
    };
}

fn run_one(
    scenario: Scenario,
    allocator: std.mem.Allocator,
) Result {
    std.debug.assert(scenario.iterations > 0);

    // Warmup: one untimed iteration.
    scenario.run_fn(allocator) catch {
        const snap = ResourceSnapshot.capture();
        return make_failed_result(
            scenario.name,
            0,
            0,
            0,
            0,
            snap,
        );
    };

    const before = ResourceSnapshot.capture();

    var elapsed_ns_total: u64 = 0;
    var elapsed_ns_min: u64 = std.math.maxInt(u64);
    var elapsed_ns_max: u64 = 0;

    var iteration: u64 = 0;
    while (iteration < scenario.iterations) : (iteration += 1) {
        var timer = std.time.Timer.start() catch unreachable;

        scenario.run_fn(allocator) catch {
            return make_failed_result(
                scenario.name,
                iteration,
                elapsed_ns_total,
                elapsed_ns_min,
                elapsed_ns_max,
                before,
            );
        };

        const elapsed_ns = timer.read();
        elapsed_ns_total += elapsed_ns;

        if (elapsed_ns < elapsed_ns_min) {
            elapsed_ns_min = elapsed_ns;
        }
        if (elapsed_ns > elapsed_ns_max) {
            elapsed_ns_max = elapsed_ns;
        }
    }

    const after = ResourceSnapshot.capture();

    return Result{
        .name = scenario.name,
        .iterations = scenario.iterations,
        .elapsed_ns_total = elapsed_ns_total,
        .elapsed_ns_min = elapsed_ns_min,
        .elapsed_ns_max = elapsed_ns_max,
        .resources = ResourceDelta.between(before, after),
        .failed = false,
    };
}

fn report(result: Result) void {
    log.info(
        "{s}: {d} iterations, " ++
            "wall mean {d} ns, min {d} ns, max {d} ns",
        .{
            result.name,
            result.iterations,
            result.elapsed_ns_mean(),
            result.elapsed_ns_min,
            result.elapsed_ns_max,
        },
    );
    log.info(
        "{s}: user {d} us, sys {d} us, " ++
            "rss {d} KB, " ++
            "faults major {d} minor {d}, " ++
            "csw vol {d} inv {d}",
        .{
            result.name,
            result.resources.user_time_us,
            result.resources.system_time_us,
            result.resources.max_rss_kb,
            result.resources.major_faults,
            result.resources.minor_faults,
            result.resources.voluntary_context_switches,
            result.resources.involuntary_context_switches,
        },
    );
}

pub fn run(
    scenarios: []const Scenario,
    allocator: std.mem.Allocator,
) void {
    std.debug.assert(scenarios.len > 0);

    log.info(
        "running benchmarks, count: {d}",
        .{scenarios.len},
    );

    var count_successful: u32 = 0;
    var count_failed: u32 = 0;

    for (scenarios) |scenario| {
        const result = run_one(scenario, allocator);

        if (result.failed) {
            log.err("{s}: FAILED", .{result.name});
            count_failed += 1;
            continue;
        }

        report(result);
        count_successful += 1;
    }

    log.info(
        "ran {d} successful and {d} failed benchmarks",
        .{ count_successful, count_failed },
    );
}
