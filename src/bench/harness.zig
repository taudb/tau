//! Reusable benchmark harness for Tau.
//!
//! Provides a generic runner that accepts a slice of Scenario
//! descriptors, times each one, samples resource usage via
//! getrusage(2), and reports aggregate results including
//! percentile statistics and throughput.
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

/// Maximum per-iteration samples collected for percentile stats.
const max_samples: u32 = 10_000;

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

pub const Percentiles = struct {
    p50_ns: u64,
    p90_ns: u64,
    p99_ns: u64,
    mean_ns: u64,
    stddev_ns: u64,
    throughput_ops_per_sec: u64,
};

pub const Result = struct {
    name: []const u8,
    iterations: u64,
    elapsed_ns_total: u64,
    elapsed_ns_min: u64,
    elapsed_ns_max: u64,
    resources: ResourceDelta,
    percentiles: Percentiles,
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

/// Compute percentile statistics from a sorted sample array.
fn compute_percentiles(
    samples: []u64,
    count: u32,
) Percentiles {
    std.debug.assert(count > 0);
    std.debug.assert(count <= max_samples);

    const slice = samples[0..count];
    std.mem.sort(u64, slice, {}, std.sort.asc(u64));

    const n: u64 = @intCast(count);
    var sum: u64 = 0;
    var idx: u32 = 0;
    while (idx < count) : (idx += 1) {
        sum += slice[idx];
    }
    const mean: u64 = sum / n;

    // Compute variance for stddev.
    var variance_sum: u128 = 0;
    idx = 0;
    while (idx < count) : (idx += 1) {
        const sample: i128 = @intCast(slice[idx]);
        const m: i128 = @intCast(mean);
        const diff: i128 = sample - m;
        variance_sum += @intCast(diff * diff);
    }
    const variance: u64 = @intCast(
        @as(u128, variance_sum) / @as(u128, n),
    );
    const stddev: u64 = std.math.sqrt(variance);

    // Throughput: ops/sec from mean latency.
    const throughput: u64 = if (mean > 0)
        1_000_000_000 / mean
    else
        0;

    return .{
        .p50_ns = slice[percentile_index(count, 50)],
        .p90_ns = slice[percentile_index(count, 90)],
        .p99_ns = slice[percentile_index(count, 99)],
        .mean_ns = mean,
        .stddev_ns = stddev,
        .throughput_ops_per_sec = throughput,
    };
}

/// Index for a given percentile in a sorted array of `count` items.
fn percentile_index(count: u32, pct: u32) u32 {
    std.debug.assert(pct > 0);
    std.debug.assert(pct <= 100);
    std.debug.assert(count > 0);

    const idx: u32 = (count * pct) / 100;
    return if (idx > 0) idx - 1 else 0;
}

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
        .percentiles = .{
            .p50_ns = 0,
            .p90_ns = 0,
            .p99_ns = 0,
            .mean_ns = 0,
            .stddev_ns = 0,
            .throughput_ops_per_sec = 0,
        },
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

    // Collect per-iteration samples (bounded to max_samples).
    const sample_count: u32 = @intCast(
        @min(scenario.iterations, max_samples),
    );
    var samples: [max_samples]u64 = undefined;

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

        // Record sample if within bounds.
        if (iteration < max_samples) {
            samples[@intCast(iteration)] = elapsed_ns;
        }
    }

    const after = ResourceSnapshot.capture();
    const percentiles = compute_percentiles(
        &samples,
        sample_count,
    );

    return Result{
        .name = scenario.name,
        .iterations = scenario.iterations,
        .elapsed_ns_total = elapsed_ns_total,
        .elapsed_ns_min = elapsed_ns_min,
        .elapsed_ns_max = elapsed_ns_max,
        .resources = ResourceDelta.between(before, after),
        .percentiles = percentiles,
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
        "{s}: p50={d}ns p90={d}ns p99={d}ns " ++
            "throughput={d} ops/s",
        .{
            result.name,
            result.percentiles.p50_ns,
            result.percentiles.p90_ns,
            result.percentiles.p99_ns,
            result.percentiles.throughput_ops_per_sec,
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

/// Print system information via fastfetch. Falls back
/// gracefully if unavailable.
pub fn print_system_info(allocator: std.mem.Allocator) void {
    const argv = [_][]const u8{ "fastfetch", "--pipe" };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch {
        log.info("system info: unavailable", .{});
        return;
    };

    const stdout_file = child.stdout orelse {
        log.info("system info: unavailable", .{});
        return;
    };

    var buf: [4096]u8 = undefined;
    const n = stdout_file.readAll(&buf) catch {
        log.info("system info: unavailable", .{});
        return;
    };

    _ = child.wait() catch {
        log.info("system info: unavailable", .{});
        return;
    };

    if (n > 0) {
        log.info("system info:\n{s}", .{buf[0..n]});
    } else {
        log.info("system info: unavailable", .{});
    }
}

pub fn run(
    scenarios: []const Scenario,
    allocator: std.mem.Allocator,
) void {
    std.debug.assert(scenarios.len > 0);

    print_system_info(allocator);

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
