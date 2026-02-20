//! Benchmark runner for Tau.
//!
//! Run with: zig build bench
//! Run with optimisations: zig build bench -Doptimize=ReleaseFast
//!
//! Runs all benchmark types regardless of configuration:
//! - Core benchmarks (segment and file_backend)
//! - Server benchmarks (protocol and auth)
//! - Fault injection benchmarks (all backends under various fault conditions)

const std = @import("std");
const harness = @import("harness.zig");
const core_bench = @import("core.zig");
const server_bench = @import("server.zig");
const faults_bench = @import("faults.zig");

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Run all benchmarks regardless of config
    harness.run(&core_bench.scenarios, allocator);
    harness.run(&server_bench.scenarios, allocator);
    harness.run(&faults_bench.scenarios, allocator);
}
