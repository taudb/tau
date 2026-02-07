//! Benchmark runner for Tau.
//!
//! Run with: zig build bench
//! Run with optimisations: zig build bench -Doptimize=ReleaseFast

const std = @import("std");
const harness = @import("harness.zig");
const core_bench = @import("core.zig");

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    harness.run(&core_bench.scenarios, allocator);
}
