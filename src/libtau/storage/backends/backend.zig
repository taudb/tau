//! Backend type and factory for creating different storage backends

const std = @import("std");
const InMemory = @import("memory_backend.zig").InMemory;

pub const BackendType = enum {
    InMemory,
    // TODO: Add file based backend
    // TODO: Add mmap based backend
};

/// Factory for creating different storage backends
pub const Backend = struct {
    backend_type: BackendType,
    backend: union(BackendType) {
        InMemory: InMemory,
    },

    pub fn deinit(self: *Backend) void {
        const assert = std.debug.assert;
        // Pre-condition assertions
        assert(self != null);
        assert(@intFromPtr(self) != 0);
        // Negative space: backend_type should be valid
        assert(@intFromEnum(self.backend_type) >= 0);

        switch (self.backend_type) {
            .InMemory => {
                assert(self.backend.InMemory.allocator.ptr != null);
                self.backend.InMemory.deinit();
            },
        }

        // Post-condition assertions
        assert(self != null);
        assert(@intFromPtr(self) != 0);
    }

    /// Create and return the backend instance
    fn createBackend(backend_type: BackendType, allocator: std.mem.Allocator) union(BackendType) {
        InMemory: InMemory,
    } {
        const assert = std.debug.assert;
        // Pre-condition assertions
        assert(allocator.ptr != null);
        assert(@intFromPtr(allocator) != 0);
        // Negative space: backend_type should be valid
        assert(@intFromEnum(backend_type) >= 0);

        const result = switch (backend_type) {
            .InMemory => InMemory.init(allocator) catch unreachable,
        };

        // Post-condition assertions
        assert(result.InMemory.allocator.ptr != null);
        assert(@intFromPtr(&result) != 0);

        return result;
    }
};
