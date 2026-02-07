# Tau

A temporal database engine written in Zig. Data is modelled as typed functions of time rather than rows in tables.

Zero external dependencies. Requires only the Zig toolchain.

## Core ideas

- **Time is the primitive.** Every entity exists within a `TimeDomain`. No timeless data.
- **Series as functions.** A `Series(T)` is a partial function `τ → T | ⊥`, mapping timestamps to typed values. See [MATHS.md](MATHS.md).
- **Lenses for transformation.** A `Lens(In, Out)` applies a pure function over a live Series without copying data.
- **Immutable by composition.** Change is expressed by composing new lenses, not by mutating existing series.
- **Columnar storage.** Series are backed by `Segment` blocks — contiguous, sorted, append-only timestamp and value columns with O(log n) point lookup.

## Configuration

All configuration is in `src/config.zig`. Edit and recompile to change settings. No environment variables, no CLI flags, no runtime config files.

```zig
// src/config.zig
pub const server = struct {
    pub const port: u16 = 7701;
    pub const address: [4]u8 = .{ 127, 0, 0, 1 };
    pub const certificate: [32]u8 = .{ ... };
    // ...
};

pub const simulation = struct {
    pub const default_seed: u64 = 0;  // 0 = use system time
    pub const default_scenarios: u32 = 1;
    pub const default_mode: Mode = .quick;
    // ...
};
```

## Build

Requires Zig 0.15 on Linux.

```sh
zig build              # compile all targets
zig build test         # run all tests
```

## Server

```sh
zig build server       # starts on configured address:port
```

Default: `127.0.0.1:7701`. See [src/server/README.md](src/server/README.md) for the wire protocol.

## Simulation

Tiger Beetle style deterministic simulation testing. Runs scenarios with fault injection to find bugs.

```sh
zig build sim                            # run simulation
zig build sim -Doptimize=ReleaseFast     # optimised (faster)
```

Configure in `src/config.zig`:
- `simulation.default_mode`: quick, standard, century, or chaos
- `simulation.default_scenarios`: number of scenarios to run
- `simulation.default_seed`: seed for reproducibility (0 = random)

See [src/sim/README.md](src/sim/README.md) for details.

## Benchmarks

```sh
zig build bench                            # debug
zig build bench -Doptimize=ReleaseFast     # optimised
```

See [src/bench/README.md](src/bench/README.md).

## Project structure

```
src/
├── config.zig       # All configuration (edit to configure)
├── root.zig         # Library root
├── core/            # Data model: Series, Segment, Lens
├── server/          # TCP database server
├── sim/             # Simulation testing framework
└── bench/           # Benchmark harness
```

## Design documents

- [MATHS.md](MATHS.md) — formal model: Series as partial functions, Lens as morphisms.
- [TIGER_STYLE.md](TIGER_STYLE.md) — coding style guide.
