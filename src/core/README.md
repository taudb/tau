# Core

The foundational data model and storage layer for Tau.

## Configuration

Storage constants are in `src/config.zig`:

```zig
pub const storage = struct {
    pub const segment_capacity_max: u32 = 1 << 20;
    pub const segment_capacity_default: u32 = 1024;
    pub const label_length: u32 = 32;
    pub const file_backend_header_size: u32 = 4096;
};
```

## Modules

| File | Purpose |
|---|---|
| `entities.zig` | `Timestamp`, `TimeDomain`, `Series(T)`, `Lens(In, Out)`. |
| `storage.zig` | `Segment(T)`: columnar, append-only, sorted storage block. |
| `file_backend.zig` | `FileBackedSegment(T)`: file-backed columnar segment with mmap and io_uring. |

## Data model

A `Series(T)` is a partial function from timestamps to values — see [MATHS.md](../../MATHS.md). It is backed by one or more `Segment` blocks, each holding a contiguous pair of timestamp and value columns. Segments are append-only and enforce strict monotonic timestamp ordering. Point lookups use binary search within segments (O(log n) per segment).

A `FileBackedSegment(T)` is a file-backed alternative to `Segment(T)`. It uses a columnar layout on disk: header, then timestamps array, then values array. Direct offset arithmetic eliminates indirection overhead. Data is accessed via mmap for zero-copy reads and writes. Durability is ensured via io_uring fdatasync on Linux (fallback to standard fdatasync on other platforms). Lookups are O(log n) via binary search over the contiguous timestamp column. Data persists across process restarts with no pointer rebuilding required.

A `Lens(In, Out)` is a lazy, zero-copy transformation over a Series. Lenses compose via standard function composition and preserve null (⊥) propagation. They hold a pointer to their source and evaluate on each lookup — no data is materialised.

## Invariants

- Timestamps within a segment are strictly increasing.
- `Series.domain` always reflects the range of stored timestamps.
- Lens lookups never interpolate; unstored timestamps return null.
- Segment count never exceeds `segment_capacity_max`.
- File backend header checksum is validated on every open.
- File backend uses direct offset arithmetic for O(1) data access.
