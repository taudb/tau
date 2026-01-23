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

    pub fn deinit(self: *Backend, allocator: std.mem.Allocator) void {
        switch (self.backend_type) {
            .InMemory => self.backend.InMemory.deinit(allocator),
        }
    }

    /// Create and return the backend instance
    fn createBackend(backend_type: BackendType) union(BackendType) {
        InMemory: InMemory,
    } {
        switch (backend_type) {
            .InMemory => return InMemory.init(),
        }
    }
};
