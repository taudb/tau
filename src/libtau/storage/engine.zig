//! The storage engine is the db servers point of access for controlling the underlying backend for persisting primitive instances

const std = @import("std");
const Backend = @import("backends/backend.zig").Backend;

pub const EngineCommand = enum {
    Put,
    Get,
    Delete,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    backend: ?*Backend = null,

    pub fn init(allocator: std.mem.Allocator, backend: *Backend) Engine {
        // Positive space: allocator and backend must be valid
        const assert = std.debug.assert;
        // assert(allocator.ptr != null); // Removed: Allocator is not a pointer
        // assert(backend != null); // Removed: backend is a pointer, can't be null
        // Negative space: backend should not be null pointer
        assert(@intFromPtr(backend) != 0);

        const engine = Engine{
            .allocator = allocator,
            .backend = backend,
        };

        // Post-condition assertions
        // assert(engine.allocator.ptr != null); // Removed: Allocator is not a pointer
        assert(engine.backend != null);
        assert(@intFromPtr(engine.backend) != 0);

        return engine;
    }

    pub fn deinit(self: *Engine) void {
        const assert = std.debug.assert;
        // Pre-condition assertions
        // assert(self != null); // Removed: self is a pointer, can't be null
        assert(@intFromPtr(self) != 0);
        // Negative space: self should not be null pointer
        // assert(self.allocator.ptr != null); // Removed: Allocator is not a pointer

        // Clean up resources if needed
        if (self.backend) |b| {
            // assert(b != null); // Removed: b is non-null from optional
            assert(@intFromPtr(b) != 0);
            b.deinit();
            self.backend = null;
        }

        // Post-condition assertions
        assert(self.backend == null);
        // assert(self.allocator.ptr != null); // Removed: Allocator is not a pointer
    }

    pub fn execute(self: *Engine, command: EngineCommand, id: []const u8, data: []const u8) !?[]const u8 {
        const assert = std.debug.assert;
        // Pre-condition assertions
        // assert(self != null); // Removed: self is a pointer, can't be null
        assert(@intFromPtr(self) != 0);
        assert(id.len > 0);
        assert(@intFromPtr(id.ptr) != 0);
        // Negative space: id should not be empty slice
        // assert(id.ptr != null); // Removed: id is []const u8, ptr is [*]const u8 which can't be null
        // For Put command, data should be non-empty
        if (command == .Put) {
            assert(data.len > 0);
            assert(@intFromPtr(data.ptr) != 0);
        }

        var result: ?[]const u8 = null;

        switch (command) {
            .Put => {
                if (self.backend) |b| {
                    // assert(b != null); // Removed: b is non-null from optional
                    assert(@intFromPtr(b) != 0);
                    try b.backend.InMemory.write(id, data);
                    result = null;
                } else {
                    return error.BackendNotInitialized;
                }
            },
            .Get => {
                if (self.backend) |b| {
                    // assert(b != null); // Removed: b is non-null from optional
                    assert(@intFromPtr(b) != 0);
                    const stored_data = try b.backend.InMemory.read(id);
                    result = stored_data;
                } else {
                    return error.BackendNotInitialized;
                }
            },
            .Delete => {
                if (self.backend) |b| {
                    // assert(b != null); // Removed: b is non-null from optional
                    assert(@intFromPtr(b) != 0);
                    try b.backend.InMemory.delete(id);
                    result = null;
                } else {
                    return error.BackendNotInitialized;
                }
            },
        }

        // Post-condition assertions
        if (command == .Get) {
            // For Get, result should be valid (could be empty slice for not found)
            assert(result != null);
            if (result.?.len > 0) {
                assert(@intFromPtr(result.?.ptr) != 0);
            }
        } else {
            // For Put and Delete, result should be null
            assert(result == null);
        }

        return result;
    }
};
