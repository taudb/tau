# Tau

A temporal database engine written in Zig. Data is modelled as typed functions of time rather than rows in tables.

Zero external dependencies. Requires only the Zig toolchain and a Linux-based system (the server and benchmark harness use Linux-specific syscalls: `getrusage(2)`, POSIX sockets, pthreads).

## Core ideas

- **Time is the primitive.** Every entity exists within a `TimeDomain`. No timeless data.
- **Series as functions.** A `Series(T)` is a partial function `τ → T | ⊥`, mapping timestamps to typed values. See [MATHS.md](MATHS.md).
- **Lenses for transformation.** A `Lens(In, Out)` applies a pure function over a live Series without copying data.
- **Immutable by composition.** Change is expressed by composing new lenses, not by mutating existing series.
- **Columnar storage.** Series are backed by `Segment` blocks — contiguous, sorted, append-only timestamp and value columns with O(log n) point lookup.

## Build

Requires Zig 0.15 on Linux.

```sh
zig build              # compile
zig build run          # run demo
zig build test         # run all tests
```

## Server

```sh
export TAU_CERTIFICATE=$(head -c 32 /dev/urandom | xxd -p -c 64)
zig build server        # starts on 127.0.0.1:7701
```

See [src/server/README.md](src/server/README.md) for the wire protocol, opcodes, and connection examples.

## Benchmarks

```sh
zig build bench                            # debug
zig build bench -Doptimize=ReleaseFast     # optimised
```

Reports wall time, CPU time, RSS, page faults, and context switches per scenario. See [src/bench/README.md](src/bench/README.md).

## Platform dependencies

Tau has zero library dependencies — only the Zig compiler is required. However, the following platform features are assumed:

- **Linux kernel** — `getrusage(2)` for benchmark resource sampling, POSIX socket API for the TCP server, pthreads for per-connection threading.
- **x86-64 or AArch64** — no architecture-specific code, but only tested on these targets.

## Design documents

- [MATHS.md](MATHS.md) — formal model: Series as partial functions, Lens as morphisms.
