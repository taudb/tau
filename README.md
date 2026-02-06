# tau

A temporal database engine written in Zig. Data is modelled as typed functions of time rather than rows in tables.

## Core Ideas

- **Time is the primitive.** Every entity exists within a `TimeDomain`. No timeless data.
- **Series as functions.** A `Series(T)` is a partial function `τ → T | ⊥`, mapping timestamps to typed values.
- **Lenses for transformation.** A `Lens(In, Out)` applies a pure function over a live Series without copying data.
- **Immutable by composition.** Change is expressed by composing new lenses, not by mutating existing series.

## Build

Requires Zig 0.15.2+.

```sh
zig build          # compile
zig build run      # run demo
zig build test     # run tests
```
