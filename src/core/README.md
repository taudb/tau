# Core

The foundational data model and storage layer for Tau.

## Configuration

Storage constants are in `src/config.zig`:

```zig
pub const storage = struct {
    pub const segment_capacity_max: u32 = 1 << 20;
    pub const segment_capacity_default: u32 = 1024;
    pub const label_length: u32 = 32;
};
```

## Modules

| File | Purpose |
|---|---|
| `entities.zig` | `Timestamp`, `TimeDomain`, `Series(T)`, `Lens(In, Out)`. |
| `storage.zig` | `Segment(T)`: columnar, append-only, sorted storage block. |

## Data model

A `Series(T)` is a partial function from timestamps to values — see [MATHS.md](../../MATHS.md). It is backed by one or more `Segment` blocks, each holding a contiguous pair of timestamp and value columns. Segments are append-only and enforce strict monotonic timestamp ordering. Point lookups use binary search within segments (O(log n) per segment).

A `Lens(In, Out)` is a lazy, zero-copy transformation over a Series. Lenses compose via standard function composition and preserve null (⊥) propagation. They hold a pointer to their source and evaluate on each lookup — no data is materialised.

## Invariants

- Timestamps within a segment are strictly increasing.
- `Series.domain` always reflects the range of stored timestamps.
- Lens lookups never interpolate; unstored timestamps return null.
- Segment count never exceeds `segment_capacity_max`.
