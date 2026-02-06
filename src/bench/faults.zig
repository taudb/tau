//! Fault injection benchmarks: test backends under various fault conditions.
//!
//! Benchmarks both segment and file_backend storage with fault injection
//! to measure resilience and performance degradation under faults.
//!
//! Uses a simplified fault injector for benchmarks (deterministic PRNG-based).

const std = @import("std");
const tau = @import("tau");
const entities = tau.entities;
const config = tau.config;
const file_backend_mod = tau.file_backend;
const harness = @import("harness.zig");

const Timestamp = entities.Timestamp;

const point_count: u32 = config.benchmark.ingest_point_count;
const query_count: u32 = config.benchmark.query_count;
const iteration_count: u64 = config.benchmark.default_iterations;

// Simplified fault injector for benchmarks
const FaultConfig = struct {
    storage_read_error_ppm: u32,
    storage_write_error_ppm: u32,
    storage_bitflip_ppm: u32,
    storage_lost_write_ppm: u32,
    storage_gray_failure_ppm: u32,
    
    pub fn mild() FaultConfig {
        return .{
            .storage_read_error_ppm = config.faults.mild.storage_read_error_ppm,
            .storage_write_error_ppm = config.faults.mild.storage_write_error_ppm,
            .storage_bitflip_ppm = config.faults.mild.storage_bitflip_ppm,
            .storage_lost_write_ppm = config.faults.mild.storage_lost_write_ppm,
            .storage_gray_failure_ppm = config.faults.mild.storage_gray_failure_ppm,
        };
    }
    
    pub fn aggressive() FaultConfig {
        return .{
            .storage_read_error_ppm = config.faults.aggressive.storage_read_error_ppm,
            .storage_write_error_ppm = config.faults.aggressive.storage_write_error_ppm,
            .storage_bitflip_ppm = config.faults.aggressive.storage_bitflip_ppm,
            .storage_lost_write_ppm = config.faults.aggressive.storage_lost_write_ppm,
            .storage_gray_failure_ppm = config.faults.aggressive.storage_gray_failure_ppm,
        };
    }
};

const StorageFault = enum {
    none,
    read_error,
    write_error,
    bitflip,
    lost_write,
    gray_failure,
};

const FaultInjector = struct {
    prng: std.Random.DefaultPrng,
    cfg: FaultConfig,
    
    pub fn init(seed: u64, cfg: FaultConfig) FaultInjector {
        return .{
            .prng = std.Random.DefaultPrng.init(seed),
            .cfg = cfg,
        };
    }
    
    fn roll(self: *FaultInjector, ppm_chance: u32) bool {
        if (ppm_chance == 0) return false;
        if (ppm_chance >= 1_000_000) return true;
        return self.prng.random().uintLessThan(u32, 1_000_000) < ppm_chance;
    }
    
    pub fn maybe_storage_read_fault(self: *FaultInjector) StorageFault {
        if (self.roll(self.cfg.storage_read_error_ppm)) {
            return .read_error;
        }
        if (self.roll(self.cfg.storage_bitflip_ppm)) {
            return .bitflip;
        }
        if (self.roll(self.cfg.storage_gray_failure_ppm)) {
            return .gray_failure;
        }
        return .none;
    }
    
    pub fn maybe_storage_write_fault(self: *FaultInjector) StorageFault {
        if (self.roll(self.cfg.storage_write_error_ppm)) {
            return .write_error;
        }
        if (self.roll(self.cfg.storage_lost_write_ppm)) {
            return .lost_write;
        }
        if (self.roll(self.cfg.storage_gray_failure_ppm)) {
            return .gray_failure;
        }
        return .none;
    }
};

// Segment backend with fault injection

fn segment_ingest_with_faults(allocator: std.mem.Allocator) !void {
    var fault_injector = FaultInjector.init(42, FaultConfig.mild());
    const label = [_]u8{0} ** 32;
    var series = entities.Series(f64).init(
        allocator,
        label,
        point_count,
    );
    defer series.deinit();

    var timestamp: Timestamp = 0;
    var successful_appends: u32 = 0;
    while (timestamp < point_count) : (timestamp += 1) {
        // Inject write faults
        const fault = fault_injector.maybe_storage_write_fault();
        if (fault == .none) {
            series.append(
                timestamp,
                @as(f64, @floatFromInt(timestamp)) * 0.1,
            ) catch {
                // Out of order or other error - continue
                continue;
            };
            successful_appends += 1;
        }
        // If fault injected, skip this append
    }
    std.mem.doNotOptimizeAway(successful_appends);
}

fn segment_query_with_faults(allocator: std.mem.Allocator) !void {
    var fault_injector = FaultInjector.init(42, FaultConfig.mild());
    const label = [_]u8{0} ** 32;
    var series = entities.Series(f64).init(
        allocator,
        label,
        point_count,
    );
    defer series.deinit();

    // Populate series first
    var timestamp: Timestamp = 0;
    while (timestamp < point_count) : (timestamp += 1) {
        series.append(
            timestamp,
            @as(f64, @floatFromInt(timestamp)) * 0.1,
        ) catch continue;
    }

    // Query with fault injection
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    var checksum: u64 = 0;
    var successful_queries: u32 = 0;
    var query_index: u32 = 0;
    while (query_index < query_count) : (query_index += 1) {
        const target: Timestamp = @intCast(
            random.uintLessThan(u32, point_count),
        );
        
        // Inject read faults
        const fault = fault_injector.maybe_storage_read_fault();
        if (fault == .none) {
            if (series.at(target)) |value| {
                checksum +%= @bitCast(
                    @as(i64, @intFromFloat(value)),
                );
                successful_queries += 1;
            }
        }
        // If fault injected, skip this query
    }
    std.mem.doNotOptimizeAway(checksum);
    std.mem.doNotOptimizeAway(successful_queries);
}

fn segment_ingest_aggressive_faults(allocator: std.mem.Allocator) !void {
    var fault_injector = FaultInjector.init(42, FaultConfig.aggressive());
    const label = [_]u8{0} ** 32;
    var series = entities.Series(f64).init(
        allocator,
        label,
        point_count,
    );
    defer series.deinit();

    var timestamp: Timestamp = 0;
    var successful_appends: u32 = 0;
    while (timestamp < point_count) : (timestamp += 1) {
        const fault = fault_injector.maybe_storage_write_fault();
        if (fault == .none) {
            series.append(
                timestamp,
                @as(f64, @floatFromInt(timestamp)) * 0.1,
            ) catch continue;
            successful_appends += 1;
        }
    }
    std.mem.doNotOptimizeAway(successful_appends);
}

fn segment_query_aggressive_faults(allocator: std.mem.Allocator) !void {
    var fault_injector = FaultInjector.init(42, FaultConfig.aggressive());
    const label = [_]u8{0} ** 32;
    var series = entities.Series(f64).init(
        allocator,
        label,
        point_count,
    );
    defer series.deinit();

    // Populate series first
    var timestamp: Timestamp = 0;
    while (timestamp < point_count) : (timestamp += 1) {
        series.append(
            timestamp,
            @as(f64, @floatFromInt(timestamp)) * 0.1,
        ) catch continue;
    }

    // Query with aggressive faults
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    var checksum: u64 = 0;
    var successful_queries: u32 = 0;
    var query_index: u32 = 0;
    while (query_index < query_count) : (query_index += 1) {
        const target: Timestamp = @intCast(
            random.uintLessThan(u32, point_count),
        );
        
        const fault = fault_injector.maybe_storage_read_fault();
        if (fault == .none) {
            if (series.at(target)) |value| {
                checksum +%= @bitCast(
                    @as(i64, @intFromFloat(value)),
                );
                successful_queries += 1;
            }
        }
    }
    std.mem.doNotOptimizeAway(checksum);
    std.mem.doNotOptimizeAway(successful_queries);
}

// File backend with fault injection

fn file_backend_ingest_with_faults(allocator: std.mem.Allocator) !void {
    var fault_injector = FaultInjector.init(42, FaultConfig.mild());
    var bench_path_buf: [64]u8 = undefined;
    const bench_path = std.fmt.bufPrint(&bench_path_buf, "/tmp/tau-bench-fault-{x}", .{@as(u64, @intCast(std.time.nanoTimestamp()))}) catch unreachable;
    var bench_dir = try std.fs.cwd().makeOpenPath(bench_path, .{});
    defer {
        bench_dir.close();
        std.fs.cwd().deleteTree(bench_path) catch {};
    }

    const label = [_]u8{0} ** 32;
    var fb = try file_backend_mod.FileBackedSegment(f64).init(
        allocator,
        bench_dir,
        label,
        point_count,
    );
    defer fb.deinit();

    var timestamp: Timestamp = 0;
    var successful_appends: u32 = 0;
    while (timestamp < point_count) : (timestamp += 1) {
        const fault = fault_injector.maybe_storage_write_fault();
        if (fault == .none) {
            fb.append(
                timestamp,
                @as(f64, @floatFromInt(timestamp)) * 0.1,
            ) catch continue;
            successful_appends += 1;
        }
    }
    std.mem.doNotOptimizeAway(successful_appends);
}

fn file_backend_query_with_faults(allocator: std.mem.Allocator) !void {
    var fault_injector = FaultInjector.init(42, FaultConfig.mild());
    var bench_path_buf: [64]u8 = undefined;
    const bench_path = std.fmt.bufPrint(&bench_path_buf, "/tmp/tau-bench-fault-{x}", .{@as(u64, @intCast(std.time.nanoTimestamp()))}) catch unreachable;
    var bench_dir = try std.fs.cwd().makeOpenPath(bench_path, .{});
    defer {
        bench_dir.close();
        std.fs.cwd().deleteTree(bench_path) catch {};
    }

    const label = [_]u8{0} ** 32;
    var fb = try file_backend_mod.FileBackedSegment(f64).init(
        allocator,
        bench_dir,
        label,
        point_count,
    );
    defer fb.deinit();

    // Populate first
    var timestamp: Timestamp = 0;
    while (timestamp < point_count) : (timestamp += 1) {
        fb.append(
            timestamp,
            @as(f64, @floatFromInt(timestamp)) * 0.1,
        ) catch continue;
    }

    // Query with faults
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    var checksum: u64 = 0;
    var successful_queries: u32 = 0;
    var query_index: u32 = 0;
    while (query_index < query_count) : (query_index += 1) {
        const target: Timestamp = @intCast(
            random.uintLessThan(u32, point_count),
        );
        
        const fault = fault_injector.maybe_storage_read_fault();
        if (fault == .none) {
            if (fb.at(target)) |value| {
                checksum +%= @bitCast(
                    @as(i64, @intFromFloat(value)),
                );
                successful_queries += 1;
            }
        }
    }
    std.mem.doNotOptimizeAway(checksum);
    std.mem.doNotOptimizeAway(successful_queries);
}

fn file_backend_ingest_aggressive_faults(allocator: std.mem.Allocator) !void {
    var fault_injector = FaultInjector.init(42, FaultConfig.aggressive());
    var bench_path_buf: [64]u8 = undefined;
    const bench_path = std.fmt.bufPrint(&bench_path_buf, "/tmp/tau-bench-fault-{x}", .{@as(u64, @intCast(std.time.nanoTimestamp()))}) catch unreachable;
    var bench_dir = try std.fs.cwd().makeOpenPath(bench_path, .{});
    defer {
        bench_dir.close();
        std.fs.cwd().deleteTree(bench_path) catch {};
    }

    const label = [_]u8{0} ** 32;
    var fb = try file_backend_mod.FileBackedSegment(f64).init(
        allocator,
        bench_dir,
        label,
        point_count,
    );
    defer fb.deinit();

    var timestamp: Timestamp = 0;
    var successful_appends: u32 = 0;
    while (timestamp < point_count) : (timestamp += 1) {
        const fault = fault_injector.maybe_storage_write_fault();
        if (fault == .none) {
            fb.append(
                timestamp,
                @as(f64, @floatFromInt(timestamp)) * 0.1,
            ) catch continue;
            successful_appends += 1;
        }
    }
    std.mem.doNotOptimizeAway(successful_appends);
}

fn file_backend_query_aggressive_faults(allocator: std.mem.Allocator) !void {
    var fault_injector = FaultInjector.init(42, FaultConfig.aggressive());
    var bench_path_buf: [64]u8 = undefined;
    const bench_path = std.fmt.bufPrint(&bench_path_buf, "/tmp/tau-bench-fault-{x}", .{@as(u64, @intCast(std.time.nanoTimestamp()))}) catch unreachable;
    var bench_dir = try std.fs.cwd().makeOpenPath(bench_path, .{});
    defer {
        bench_dir.close();
        std.fs.cwd().deleteTree(bench_path) catch {};
    }

    const label = [_]u8{0} ** 32;
    var fb = try file_backend_mod.FileBackedSegment(f64).init(
        allocator,
        bench_dir,
        label,
        point_count,
    );
    defer fb.deinit();

    // Populate first
    var timestamp: Timestamp = 0;
    while (timestamp < point_count) : (timestamp += 1) {
        fb.append(
            timestamp,
            @as(f64, @floatFromInt(timestamp)) * 0.1,
        ) catch continue;
    }

    // Query with aggressive faults
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    var checksum: u64 = 0;
    var successful_queries: u32 = 0;
    var query_index: u32 = 0;
    while (query_index < query_count) : (query_index += 1) {
        const target: Timestamp = @intCast(
            random.uintLessThan(u32, point_count),
        );
        
        const fault = fault_injector.maybe_storage_read_fault();
        if (fault == .none) {
            if (fb.at(target)) |value| {
                checksum +%= @bitCast(
                    @as(i64, @intFromFloat(value)),
                );
                successful_queries += 1;
            }
        }
    }
    std.mem.doNotOptimizeAway(checksum);
    std.mem.doNotOptimizeAway(successful_queries);
}

pub const scenarios = [_]harness.Scenario{
    // Segment backend with mild faults
    .{
        .name = "faults/segment_ingest_mild",
        .iterations = iteration_count,
        .run_fn = segment_ingest_with_faults,
    },
    .{
        .name = "faults/segment_query_mild",
        .iterations = iteration_count,
        .run_fn = segment_query_with_faults,
    },
    // Segment backend with aggressive faults
    .{
        .name = "faults/segment_ingest_aggressive",
        .iterations = iteration_count,
        .run_fn = segment_ingest_aggressive_faults,
    },
    .{
        .name = "faults/segment_query_aggressive",
        .iterations = iteration_count,
        .run_fn = segment_query_aggressive_faults,
    },
    // File backend with mild faults
    .{
        .name = "faults/file_backend_ingest_mild",
        .iterations = iteration_count,
        .run_fn = file_backend_ingest_with_faults,
    },
    .{
        .name = "faults/file_backend_query_mild",
        .iterations = iteration_count,
        .run_fn = file_backend_query_with_faults,
    },
    // File backend with aggressive faults
    .{
        .name = "faults/file_backend_ingest_aggressive",
        .iterations = iteration_count,
        .run_fn = file_backend_ingest_aggressive_faults,
    },
    .{
        .name = "faults/file_backend_query_aggressive",
        .iterations = iteration_count,
        .run_fn = file_backend_query_aggressive_faults,
    },
};
