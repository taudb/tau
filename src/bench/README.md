# Benchmarks

Benchmark framework for Tau. Measures wall-clock time and system resource usage (via `getrusage(2)`) per scenario.

## Configuration

Benchmark constants are in `src/config.zig`:

```zig
pub const benchmark = struct {
    pub const default_iterations: u32 = 100;
    pub const ingest_point_count: u32 = 100_000;
    pub const query_count: u32 = 10_000;
    pub const auth_verify_count: u32 = 100_000;
};
```

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
├── core.zig      # Core scenarios: ingest, point query, lens query (both backends).
├── server.zig    # Server scenarios: protocol, auth.
├── faults.zig    # Fault injection scenarios: all backends under various fault conditions.
├── main.zig      # Entry point (runs all benchmarks regardless of config).
└── README.md
```

## Adding a scenario module

1. Create a new file, e.g. `src/bench/wire.zig`.
2. Import the harness and define scenario functions:

```zig
const std = @import("std");
const harness = @import("harness.zig");

fn my_scenario(allocator: std.mem.Allocator) !void {
    _ = allocator;
    // ...
}

pub const scenarios = [_]harness.Scenario{
    .{
        .name = "wire/my_scenario",
        .iterations = 100,
        .run_fn = my_scenario,
    },
};
```

3. Import the module in `main.zig` and pass its scenarios to `harness.run`.

## Current scenarios

All benchmarks run regardless of configuration - both segment and file_backend backends are always tested.

### Core

| Name | What it measures |
|---|---|
| `core/segment_ingest` | Append 100k points to in-memory Segment. |
| `core/segment_point_query` | 10k random point lookups via binary search in Segment. |
| `core/segment_lens_query` | 10k random lookups through a Lens transform over Segment. |
| `core/file_backend_ingest` | Append 100k points to file-backed storage. |
| `core/file_backend_point_query` | 10k random point lookups in file-backed storage. |

### Server

| Name | What it measures |
|---|---|
| `server/protocol_roundtrip` | Encode and decode protocol headers across all opcodes. |
| `server/auth_verify` | 100k constant-time certificate comparisons. |

### Fault Injection

| Name | What it measures |
|---|---|
| `faults/segment_ingest_mild` | Segment ingest with mild fault injection (occasional errors). |
| `faults/segment_query_mild` | Segment queries with mild fault injection. |
| `faults/segment_ingest_aggressive` | Segment ingest with aggressive fault injection (stress testing). |
| `faults/segment_query_aggressive` | Segment queries with aggressive fault injection. |
| `faults/file_backend_ingest_mild` | File backend ingest with mild fault injection. |
| `faults/file_backend_query_mild` | File backend queries with mild fault injection. |
| `faults/file_backend_ingest_aggressive` | File backend ingest with aggressive fault injection. |
| `faults/file_backend_query_aggressive` | File backend queries with aggressive fault injection. |

Fault injection benchmarks test both backends under various fault conditions to measure resilience and performance degradation. Fault rates are configured in `src/config.zig` under `faults.mild` and `faults.aggressive`.
