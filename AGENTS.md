# AGENTS.md - Zig Development Guidelines

This document provides comprehensive guidance for AI agents working on the tau timeseries database codebase written in Zig.

## Build & Test Commands

### Core Commands
```bash
# Build the project
zig build

# Run the application
zig build run

# Run all tests
zig build test

# Format code
zig fmt src/

# Check for syntax errors (use individual files)
zig ast-check src/main.zig
zig ast-check src/primitives/tau.zig

# Build with release optimizations
zig build -Drelease-safe
zig build -Drelease-fast
```

### Running Single Tests
```bash
# Run test in specific file
zig test src/primitives/tau.zig

# Run specific test function
zig test src/primitives/tau.zig --test-filter "test_function_name"
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
├── main.zig          # Application entry point
└── primitives/       # Core data structures
    ├── mod.zig       # Module exports
    ├── tau.zig       # Tau struct and functions
    ├── schedule.zig  # Schedule struct and functions
    ├── frame.zig     # Frame struct and functions
    ├── id.zig        # Safe ID generation
    └── lens.zig      # Time lens utilities
└── storage/          # Storage layer
    └── mod.zig       # Storage module exports
```

## Tiger Style Principles

1. **Safety First**: Always validate inputs and handle all error cases
2. **Performance from the Start**: Use napkin math during design, optimize in order: Network → Disk → Memory → CPU
3. **Developer Experience**: Get the nouns and verbs right, minimize cognitive load
4. **Immutability**: Prefer `const` over `var` when possible
5. **Memory Management**: Every allocation must have a corresponding free
6. **Documentation**: Add doc comments for public APIs

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