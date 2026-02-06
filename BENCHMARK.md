# Benchmarking Tau

How to run, interpret, and optimise Tau benchmarks.

## Running Benchmarks

```sh
# Debug build (includes safety checks, assertions, bounds checking)
zig build bench

# Release build (optimised, no safety checks — use for meaningful numbers)
zig build bench -Doptimize=ReleaseFast
```

The benchmark binary runs all scenarios sequentially. Each scenario includes one untimed warmup iteration followed by the configured number of timed iterations.

## Configuration

Benchmark parameters are compile-time constants in `src/config.zig`:

```zig
pub const benchmark = struct {
    pub const default_iterations: u32 = 10;
    pub const ingest_point_count: u32 = 100_000;
    pub const query_count: u32 = 10_000;
    pub const auth_verify_count: u32 = 100_000;
};
```

Edit and recompile to change workload sizes.

## Scenarios

### Core

| Scenario | What it measures | Workload |
|---|---|---|
| `core/segment_ingest` | Append throughput to in-memory Segment. Sequential writes of 100k timestamp-value pairs into a single segment. Measures raw columnar append speed without network or actor overhead. | 100k points × N iterations |
| `core/segment_point_query` | Point lookup latency in Segment. Pre-populates a segment with 100k points, then performs 10k random O(log n) binary search lookups. Measures read-path performance of the sorted columnar layout. | 10k lookups × N iterations |
| `core/segment_lens_query` | Lens-transformed read latency. Same as point query, but reads go through a Lens that applies a transform function (e.g. unit conversion). Measures the overhead of JIT transformation vs raw lookup. | 10k lookups × N iterations |
| `core/file_backend_ingest` | Append throughput to file-backed storage. Same workload as segment_ingest but writing through the file backend (`FileBackedSegment`). Measures the cost of durable writes vs in-memory. | 100k points × N iterations |
| `core/file_backend_point_query` | Point lookup latency from file-backed storage. Same as segment_point_query but reading from the file backend. | 10k lookups × N iterations |

### Server

| Scenario | What it measures | Workload |
|---|---|---|
| `server/protocol_roundtrip` | Protocol header encode/decode throughput. Encodes and decodes a `Header` struct for every opcode. Measures the cost of the 10-byte frame header processing. | All opcodes × N iterations |
| `server/auth_verify` | Authentication throughput. Performs 100k constant-time 32-byte certificate comparisons. Measures the cost of the XOR-accumulate compare that prevents timing attacks. | 100k verifications × N iterations |

### Fault Injection

| Scenario | What it measures | Workload |
|---|---|---|
| `faults/segment_ingest_mild` | Segment ingest under mild fault injection. Occasional storage read/write errors, rare bitflips. | 100k points × N iterations |
| `faults/segment_query_mild` | Segment queries under mild faults. | 10k lookups × N iterations |
| `faults/segment_ingest_aggressive` | Segment ingest under aggressive faults. High error rates, lost writes, gray failures. | 100k points × N iterations |
| `faults/segment_query_aggressive` | Segment queries under aggressive faults. | 10k lookups × N iterations |
| `faults/file_backend_ingest_mild` | File backend ingest under mild faults. | 100k points × N iterations |
| `faults/file_backend_query_mild` | File backend queries under mild faults. | 10k lookups × N iterations |
| `faults/file_backend_ingest_aggressive` | File backend ingest under aggressive faults. | 100k points × N iterations |
| `faults/file_backend_query_aggressive` | File backend queries under aggressive faults. | 10k lookups × N iterations |

Fault rates are configured in `src/config.zig` under `faults.mild` and `faults.aggressive`. Fault injection benchmarks measure performance degradation under failure — not just the happy path.

## Interpreting Results

Each scenario reports two lines of output:

```
info(bench): core/segment_ingest: 10 iterations, wall mean 1234567 ns, min 1200000 ns, max 1300000 ns
info(bench): core/segment_ingest: user 12000 us, sys 500 us, rss 8192 KB, faults major 0 minor 200, csw vol 0 inv 3
```

### Wall Time

| Metric | Meaning |
|---|---|
| **wall mean** | Average elapsed real time per iteration. The primary throughput metric. |
| **wall min** | Best-case iteration. Closest to the true cost with no interference. |
| **wall max** | Worst-case iteration. Shows tail latency from OS scheduling, page faults, etc. |

To compute throughput: `points / (wall_mean_ns / 1e9)` = points/second. For example, 100k points in 1.2 ms = ~83M points/sec.

### Resource Usage

| Metric | What to watch for |
|---|---|
| **user** | CPU time in user mode (µs). Should scale linearly with workload. |
| **sys** | CPU time in kernel mode (µs). High values indicate excessive syscalls (file I/O, memory mapping). |
| **rss** | Peak resident set size (KB). Should be stable across iterations (no unbounded growth). |
| **major faults** | Page faults requiring disk I/O. Should be 0 for in-memory benchmarks. Non-zero for file backend is expected on first run. |
| **minor faults** | Page faults resolved from page cache. Reflects memory allocation patterns. |
| **vol csw** | Voluntary context switches. High values indicate the process is waiting (I/O, locks). |
| **inv csw** | Involuntary context switches. High values indicate CPU contention / preemption. |

## Reference Results

Results vary by hardware, OS, kernel version, and background load. Use these as a baseline for comparison, not as absolute targets.

### Reference System

```
System:  MacBook Pro 16" 2019 / Intel i9-9980HK (16 threads) / 32 GB RAM / Arch Linux
Storage: 915 GB ext4
Build:   zig build bench -Doptimize=ReleaseFast
```

> **Note:** Benchmark numbers for this reference system will be filled in after a stable measurement run.

### Your System

Record your results here for comparison:

```
System:  <your hardware>
Storage: <your filesystem>
Build:   zig build bench -Doptimize=ReleaseFast

core/segment_ingest:           wall mean _______ ns
core/segment_point_query:      wall mean _______ ns
core/segment_lens_query:       wall mean _______ ns
core/file_backend_ingest:      wall mean _______ ns
core/file_backend_point_query: wall mean _______ ns
server/protocol_roundtrip:     wall mean _______ ns
server/auth_verify:            wall mean _______ ns
```

## System Requirements for Meaningful Benchmarks

- **Use ReleaseFast.** Debug builds include bounds checking, safety assertions, and are not representative of production performance.
- **Idle system.** Close browsers, editors, and other CPU-intensive processes. Background load introduces noise.
- **Warm filesystem cache.** Run the benchmark twice. The first run may include cold-cache page faults for file-backed benchmarks.
- **Sufficient RAM.** The benchmark should not trigger swap. Check that major faults remain at 0 for in-memory scenarios.
- **Linux.** The harness uses `getrusage(2)` for resource metrics, which is Linux-specific.

## Tips for Stable, Optimised Results

1. **Always use ReleaseFast** for performance numbers:
   ```sh
   zig build bench -Doptimize=ReleaseFast
   ```

2. **CPU pinning** reduces variance from core migration:
   ```sh
   taskset -c 0 zig-out/bin/bench
   ```

3. **Disable turbo boost** for stable clock speeds (results won't vary with thermal throttling):
   ```sh
   echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo
   ```

4. **Set CPU governor to performance**:
   ```sh
   echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
   ```

5. **Run multiple times** and compare the **min** values across runs. The minimum is the most stable estimator — it represents the run with the least OS interference.

6. **Compare ratios, not absolutes.** When evaluating a change, compare `before/after` ratios on the same machine. Absolute numbers are not portable across hardware.
