# AGENTS.md - Zig Development Guidelines

This document provides comprehensive guidance for AI agents working on the tau timeseries database codebase written in Zig.

## Build & Test Commands

### Core Commands
```bash
# Build the project
zig build

# Run the tau server
zig build run

# Format code
zig fmt src/

# Check for syntax errors (use individual files)
zig ast-check src/server/main.zig
zig ast-check src/libtau/primitives/tau.zig

# Build with release optimizations
zig build -Drelease-safe
zig build -Drelease-fast
```

### Running Tests
```bash
# Run all tests (libtau + server)
zig build test

# Run only library tests
zig build test-libtau

# Run only server tests
zig build test-server

# Run test in specific file
zig test src/libtau/primitives/tau.zig

# Run specific test function
zig test src/libtau/primitives/tau.zig --test-filter "test_function_name"
```

## Code Style Guidelines

### Import Organization
- Place all imports at the top of files
- Group std imports first, then local imports
- Use `@import()` with explicit file paths for local modules
- Alias imports for clarity when needed

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

// Local imports
const Tau = @import("primitives/tau.zig").Tau;
const Schedule = @import("primitives/schedule.zig").Schedule;
```

### Naming Conventions
- **Types**: PascalCase (`Tau`, `Schedule`, `Frame`)
- **Functions**: camelCase (`createTau`, `isValid`)
- **Variables**: snake_case (`time_ns`, `expiry_ns`)
- **Constants**: UPPER_SNAKE_CASE (`MAX_BUFFER_SIZE`, `DEFAULT_TIMEOUT`)
- **File names**: snake_case (`tau.zig`, `schedule.zig`)

### Struct Definition Style
```zig
pub const Tau = struct {
    id: u128,
    diff: []const u8,
    valid_ns: u64,
    expiry_ns: u64,

    pub fn isValid(self: Tau, time_ns: u64) bool {
        return time_ns >= self.valid_ns and time_ns < self.expiry_ns;
    }

    pub fn deinit(self: Tau, allocator: std.mem.Allocator) void {
        allocator.free(self.diff);
    }
};
```

### Error Handling
- Use Zig's error union type (`!T`) for functions that can fail
- Handle errors explicitly with `try`, `catch`, or `if`
- Never ignore errors - always handle or propagate them

```zig
fn createTau(allocator: Allocator, diff: []const u8, valid_ns: u64, expiry_ns: u64) !Tau {
    const id = try SafeIDGenerator.generate(.Tau);
    const tau_diff = try allocator.dupe(u8, diff);
    return Tau{
        .id = id,
        .diff = tau_diff,
        .valid_ns = valid_ns,
        .expiry_ns = expiry_ns,
    };
}
```

### Memory Management
- Always pair allocations with proper cleanup
- Use `deinit()` methods for structs that own heap memory
- Use `defer` to ensure cleanup happens even on errors

```zig
const frame = try createFrame(allocator);
defer frame.deinit(allocator);

const data = try allocator.alloc(u8, size);
defer allocator.free(data);
```

### Function Design
- Keep functions focused and small (~50 lines max)
- Use meaningful parameter names
- Return simple types: `void > bool > error unions > structs`
- Document public functions with doc comments

```zig
/// Checks if the tau is valid at the given timestamp.
pub fn isValid(self: Tau, time_ns: u64) bool {
    return time_ns >= self.valid_ns and time_ns < self.expiry_ns;
}
```

### Testing
- Write tests for all public functions
- Use the `test` keyword for unit tests
- Test both success and error paths
- Use descriptive test names

```zig
test "Tau.isValid returns true for valid time range" {
    const tau = Tau{
        .id = "test",
        .diff = "+1.0",
        .valid_ns = 1000,
        .expiry_ns = 2000,
    };
    
    try std.testing.expect(tau.isValid(1500));
    try std.testing.expect(!tau.isValid(999));
    try std.testing.expect(!tau.isValid(2000));
}
```

## Project Structure

```
src/
├── server/           # Server application
│   └── main.zig     # Server entry point
└── libtau/          # Library code
    ├── mod.zig       # Library module exports
    ├── primitives/   # Core data structures
    │   ├── mod.zig   # Primitive exports
    │   ├── tau.zig   # Tau struct and functions
    │   ├── schedule.zig  # Schedule struct and functions
    │   ├── frame.zig     # Frame struct and functions
    │   ├── lens.zig      # Time lens utilities
    │   └── lens_expression.zig  # Lens expressions
    ├── storage/      # Storage layer
    │   └── mod.zig   # Storage module exports
    ├── ulid/         # ULID generation
    │   └── mod.zig   # ULID module
    └── expr/         # Expression handling
        └── mod.zig   # Expression module
```

## Tiger Style Principles

1. **Safety First**: Always validate inputs and handle all error cases
2. **Performance from the Start**: Use napkin math during design, optimize in order: Network → Disk → Memory → CPU
3. **Developer Experience**: Get the nouns and verbs right, minimize cognitive load
4. **Immutability**: Prefer `const` over `var` when possible
5. **Memory Management**: Every allocation must have a corresponding free
6. **Documentation**: Add doc comments for public APIs

## Tiger Style Principles (from tigerstyle.dev)

## The Essence Of Style

> "There are three things extremely hard: steel, a diamond, and to know one's self." — Benjamin Franklin

TigerBeetle's coding style is evolving. A collective give-and-take at the intersection of engineering and art. Numbers and human intuition. Reason and experience. First principles and knowledge. Precision and poetry. Just like music. A tight beat. A rare groove. Words that rhyme and rhymes that break. Biodigital jazz. This is what we've learned along the way. The best is yet to come.

### Safety

- **Use assertions aggressively** - Assert preconditions, postconditions, and invariants. Minimum 2 assertions per function.
- **Put limits on everything** - All loops and queues must have fixed upper bounds.
- **Static memory allocation** - All memory must be statically allocated at startup. No dynamic allocation after initialization.
- **Functions ≤70 lines** - Hard limit to ensure functions fit on one screen.
- **Explicit error handling** - All errors must be handled explicitly.

### Performance

- **Napkin math first** - Use back-of-envelope sketches for network, disk, memory, CPU resources.
- **Optimize in order** - Network → Disk → Memory → CPU.
- **Batch operations** - Amortize costs by batching accesses.
- **Predictable execution** - Extract hot loops into standalone functions.

### Developer Experience

- **Get nouns and verbs right** - Names should create a clear, intuitive mental model.
- **snake_case** - Use snake_case for all identifiers (functions, variables, files).
- **Units in names** - Include units: `latency_ms_max`, not `max_latency_ms`.
- **Explicit options** - Pass options explicitly at call sites, don't rely on defaults.

## Best Practices

- Write functions that work in ALL situations, not just happy paths
- Use assertions aggressively to catch impossible states
- Fail fast and loud—detect problems as early as possible
- Keep functions small and focused (~70 lines max)
- Make the right thing easy and the wrong thing hard

## Development Workflow

1. Make changes to source files
2. Run `zig fmt src/` to format code
3. Run `zig ast-check src/main.zig` to check syntax
4. Run `zig build test` to verify tests pass
5. Run `zig build run` to test manually if needed
6. Commit only when all tests pass and code is formatted

## Key Principles

- **Correctness over cleverness**: Write clear, maintainable code
- **Explicit is better than implicit**: Make intent obvious
- **Resource safety**: Never leak memory or resources
- **Comprehensive testing**: Test both happy paths and error conditions