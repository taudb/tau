# Benchmarks

Benchmark framework for Tau. Measures wall-clock time and system resource usage (via `getrusage(2)`, mirroring `time(1)`) per scenario.

## Usage

```sh
zig build bench                            # debug build
zig build bench -Doptimize=ReleaseFast     # optimised build
```

## Resource metrics

Each scenario reports:

| Metric | Source | Description |
|---|---|---|
| Wall time (ns) | `Timer` | Mean, min, max elapsed real time per iteration. |
| User CPU (µs) | `ru_utime` | Time spent in user mode. |
| System CPU (µs) | `ru_stime` | Time spent in kernel mode. |
| Peak RSS (KB) | `ru_maxrss` | Maximum resident set size. |
| Major faults | `ru_majflt` | Page faults requiring disk I/O. |
| Minor faults | `ru_minflt` | Page faults resolved without I/O. |
| Vol. CSW | `ru_nvcsw` | Voluntary context switches (waits/yields). |
| Invol. CSW | `ru_nivcsw` | Involuntary context switches (preemption). |

## Structure

```
src/bench/
├── harness.zig   # Reusable runner: Scenario, Result, resource sampling.
├── core.zig      # Core scenarios: ingest, point query, lens query.
├── main.zig      # Entry point: collects and runs all scenario modules.
└── README.md
```

## Adding a scenario module

1. Create a new file, e.g. `src/bench/protocol.zig`.
2. Import the harness and define scenario functions:

```zig
const harness = @import("harness.zig");

fn my_scenario(allocator: std.mem.Allocator) !void {
    // ...
}

pub const scenarios = [_]harness.Scenario{
    .{
        .name = "protocol/my_scenario",
        .iterations = 100,
        .run_fn = my_scenario,
    },
};
```

3. Import the module in `main.zig` and pass its scenarios to `harness.run`.

## Current scenarios

| Name | What it measures |
|---|---|
| `core/ingest_throughput` | Append 100k points to a Series. |
| `core/point_query` | 10k random point lookups via binary search. |
| `core/lens_query` | 10k random lookups through a Lens transform. |
