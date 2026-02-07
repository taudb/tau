# Simulation

Tiger Beetle style deterministic simulation testing framework for Tau.

## Philosophy

From [TIGER_STYLE.md](../../TIGER_STYLE.md):

> Assertions downgrade catastrophic correctness bugs into liveness bugs. Assertions are a force multiplier for discovering bugs by fuzzing.

The simulation framework:
1. Wraps the system under test in a state machine
2. Applies random operations with deterministic PRNG
3. Injects faults (storage, network, memory)
4. Verifies invariants after each operation
5. Compares against a shadow state for correctness

## Configuration

All configuration is in `src/config.zig`:

```zig
pub const simulation = struct {
    pub const default_seed: u64 = 0;       // 0 = use system time
    pub const default_scenarios: u32 = 1;
    pub const default_mode: Mode = .quick;

    pub const quick = struct {
        pub const duration_years: u32 = 1;
        pub const ops_per_day: u32 = 100;
        // ...
    };

    pub const century = struct {
        pub const duration_years: u32 = 100;
        // ...
    };
};

pub const faults = struct {
    pub const mild = FaultRates{ .network_drop_ppm = 1000, ... };
    pub const aggressive = FaultRates{ .network_drop_ppm = 50_000, ... };
    pub const chaos = FaultRates{ .network_drop_ppm = 200_000, ... };
};
```

## Running

```sh
zig build sim                            # debug build
zig build sim -Doptimize=ReleaseFast     # optimised build
```

## Modules

| File | Purpose |
|---|---|
| `prng.zig` | Deterministic PRNG (SplitMix64) for reproducible randomness. |
| `clock.zig` | Virtual clock for time simulation. |
| `faults.zig` | Fault injection system: storage, network, memory faults. |
| `state_machine.zig` | State machine wrapper with shadow state verification. |
| `harness.zig` | Scenario runner and statistics. |
| `main.zig` | Entry point. |

## Simulation modes

| Mode | Duration | Ops/day | Faults | Purpose |
|---|---|---|---|---|
| quick | 1 year | 100 | none | Fast smoke test |
| standard | 10 years | 500 | mild | Normal testing |
| century | 100 years | 25 | aggressive | Long-term stress test |
| chaos | 10 years | 2000 | chaos | Maximum fault injection |

## Fault injection

Fault rates are specified in parts-per-million (ppm):

| Fault | Chaos ppm | Description |
|---|---|---|
| `network_drop` | 200,000 | 20% packet loss |
| `network_reorder` | 100,000 | 10% reordering |
| `storage_read_error` | 100,000 | 10% read failures |
| `storage_bitflip` | 10,000 | 1% bit corruption |

## Deterministic replay

Every scenario is reproducible from its seed:

```zig
// In config.zig
pub const simulation = struct {
    pub const default_seed: u64 = 12345;  // specific seed
    pub const default_scenarios: u32 = 1;
    pub const default_mode: Mode = .standard;
};
```

Failed seeds are logged for replay:

```
warn(harness): failed seeds for replay:
warn(harness):   seed=12345678901234567890
```

## Invariants checked

1. **Count consistency**: Series count matches shadow state count
2. **Domain consistency**: Series domain matches shadow domain
3. **Value consistency**: Lookups return same value from Series and shadow
4. **Monotonic timestamps**: Timestamps strictly increase

## Tiger Beetle style features

- Minimum 2 assertions per function
- All loops are bounded
- All memory is statically allocated at startup
- All randomness is deterministic from seed
- Explicit types (u32, i64) not usize
- Functions under 70 lines

