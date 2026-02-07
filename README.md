# Tau

A temporal database engine written in Zig. Data is modelled as typed functions of time rather than rows in tables.

## Core ideas

- **Time is the primitive.** Every entity exists within a `TimeDomain`. No timeless data.
- **Series as functions.** A `Series(T)` is a partial function `τ → T | ⊥`, mapping timestamps to typed values. See [MATHS.md](MATHS.md).
- **Lenses for transformation.** A `Lens(In, Out)` applies a pure function over a live Series without copying data.
- **Immutable by composition.** Change is expressed by composing new lenses, not by mutating existing series.
- **Columnar storage.** Series are backed by `Segment` blocks — contiguous, sorted, append-only timestamp and value columns with O(log n) point lookup.

## Project structure

```
src/
├── core/
│   ├── entities.zig   # TimeDomain, Series, Lens.
│   └── storage.zig    # Segment: columnar storage backing.
├── bench/             # Benchmark framework. See src/bench/README.md.
│   ├── harness.zig
│   ├── core.zig
│   └── main.zig
├── main.zig           # Demo entry point.
└── root.zig           # Library root (pub exports).
```

## Build

Requires Zig 0.15.

```sh
zig build              # compile
zig build run          # run demo
zig build test         # run tests
zig build bench        # run benchmarks (debug)
zig build bench -Doptimize=ReleaseFast   # run benchmarks (optimised)
```

## Design documents

- [PLAN.md](PLAN.md) — build plan and open design decisions.
- [MATHS.md](MATHS.md) — formal model: Series as partial functions, Lens as morphisms.
