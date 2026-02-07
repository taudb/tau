//! Core benchmark scenarios: entities and storage layer.

const std = @import("std");
const tau = @import("tau");
const entities = tau.entities;
const harness = @import("harness.zig");

const Timestamp = entities.Timestamp;

const point_count: u32 = 100_000;
const query_count: u32 = 10_000;
const iteration_count: u64 = 100;

fn ingest_throughput(allocator: std.mem.Allocator) !void {
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

fn point_query(allocator: std.mem.Allocator) !void {
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

fn lens_query(allocator: std.mem.Allocator) !void {
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

pub const scenarios = [_]harness.Scenario{
    .{
        .name = "core/ingest_throughput",
        .iterations = iteration_count,
        .run_fn = ingest_throughput,
    },
    .{
        .name = "core/point_query",
        .iterations = iteration_count,
        .run_fn = point_query,
    },
    .{
        .name = "core/lens_query",
        .iterations = iteration_count,
        .run_fn = lens_query,
    },
};
