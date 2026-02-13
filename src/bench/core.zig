//! Core benchmark scenarios: entities and storage layer.
//!
//! Benchmarks both in-memory Segment and file-backed columnar
//! storage backends side-by-side for comparison. All constants are
//! driven by config.benchmark.

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

// In-memory Segment benchmarks.

fn segment_ingest(allocator: std.mem.Allocator) !void {
    const label = [_]u8{0} ** 32;
    var series = entities.Series(f64).init(
        allocator,
        label,
        point_count,
    );
    defer series.deinit();

    var timestamp: Timestamp = 0;
    while (timestamp < point_count) : (timestamp += 1) {
        try series.append(
            timestamp,
            @as(f64, @floatFromInt(timestamp)) * 0.1,
        );
    }
}

fn segment_point_query(allocator: std.mem.Allocator) !void {
    const label = [_]u8{0} ** 32;
    var series = entities.Series(f64).init(
        allocator,
        label,
        point_count,
    );
    defer series.deinit();

    var timestamp: Timestamp = 0;
    while (timestamp < point_count) : (timestamp += 1) {
        try series.append(
            timestamp,
            @as(f64, @floatFromInt(timestamp)) * 0.1,
        );
    }

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var checksum: u64 = 0;
    var query_index: u32 = 0;
    while (query_index < query_count) : (query_index += 1) {
        const target: Timestamp = @intCast(
            random.uintLessThan(u32, point_count),
        );
        if (series.at(target)) |value| {
            checksum +%= @bitCast(
                @as(i64, @intFromFloat(value)),
            );
        }
    }
    std.mem.doNotOptimizeAway(checksum);
}

fn to_celsius(raw: f64) f64 {
    return (raw - 32.0) * (5.0 / 9.0);
}

fn segment_lens_query(allocator: std.mem.Allocator) !void {
    const label = [_]u8{0} ** 32;
    var series = entities.Series(f64).init(
        allocator,
        label,
        point_count,
    );
    defer series.deinit();

    var timestamp: Timestamp = 0;
    while (timestamp < point_count) : (timestamp += 1) {
        try series.append(
            timestamp,
            @as(f64, @floatFromInt(timestamp)) * 0.1,
        );
    }

    const lens = entities.Lens(f64).init(
        f64,
        &series,
        to_celsius,
    );

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var checksum: u64 = 0;
    var query_index: u32 = 0;
    while (query_index < query_count) : (query_index += 1) {
        const target: Timestamp = @intCast(
            random.uintLessThan(u32, point_count),
        );
        if (lens.at(target)) |value| {
            checksum +%= @bitCast(
                @as(i64, @intFromFloat(value)),
            );
        }
    }
    std.mem.doNotOptimizeAway(checksum);
}

// File-backed columnar segment benchmarks.

fn file_backend_ingest(allocator: std.mem.Allocator) !void {
    var bench_path_buf: [64]u8 = undefined;
    const bench_path = std.fmt.bufPrint(&bench_path_buf, "/tmp/tau-bench-{x}", .{@as(u64, @intCast(std.time.nanoTimestamp()))}) catch unreachable;
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
    while (timestamp < point_count) : (timestamp += 1) {
        try fb.append(
            timestamp,
            @as(f64, @floatFromInt(timestamp)) * 0.1,
        );
    }
}

fn file_backend_point_query(allocator: std.mem.Allocator) !void {
    var bench_path_buf: [64]u8 = undefined;
    const bench_path = std.fmt.bufPrint(&bench_path_buf, "/tmp/tau-bench-{x}", .{@as(u64, @intCast(std.time.nanoTimestamp()))}) catch unreachable;
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
    while (timestamp < point_count) : (timestamp += 1) {
        try fb.append(
            timestamp,
            @as(f64, @floatFromInt(timestamp)) * 0.1,
        );
    }

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var checksum: u64 = 0;
    var query_index: u32 = 0;
    while (query_index < query_count) : (query_index += 1) {
        const target: Timestamp = @intCast(
            random.uintLessThan(u32, point_count),
        );
        if (fb.at(target)) |value| {
            checksum +%= @bitCast(
                @as(i64, @intFromFloat(value)),
            );
        }
    }
    std.mem.doNotOptimizeAway(checksum);
}

pub const scenarios = [_]harness.Scenario{
    .{
        .name = "core/segment_ingest",
        .iterations = iteration_count,
        .run_fn = segment_ingest,
    },
    .{
        .name = "core/segment_point_query",
        .iterations = iteration_count,
        .run_fn = segment_point_query,
    },
    .{
        .name = "core/segment_lens_query",
        .iterations = iteration_count,
        .run_fn = segment_lens_query,
    },
    .{
        .name = "core/file_backend_ingest",
        .iterations = iteration_count,
        .run_fn = file_backend_ingest,
    },
    .{
        .name = "core/file_backend_point_query",
        .iterations = iteration_count,
        .run_fn = file_backend_point_query,
    },
};
