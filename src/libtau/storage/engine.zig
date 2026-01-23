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
        return Engine{
            .allocator = allocator,
            .backend = backend,
        };
    }

    pub fn deinit(self: *Engine) void {
        // Clean up resources if needed
        if (self.backend) |b| {
            b.deinit(self.allocator);
            self.backend = null;
        }
    }

    pub fn execute(self: *Engine, command: EngineCommand, data: []const u8) !?[]const u8 {
        switch (command) {
            .Put => {
                if (self.backend) |b| {
                    try b.backend.InMemory.write(self.allocator, data);
                    return null;
                } else {
                    return error.BackendNotInitialized;
                }
            },
            .Get => {
                if (self.backend) |b| {
                    const stored_data = b.backend.InMemory.read();
                    return stored_data;
                } else {
                    return error.BackendNotInitialized;
                }
            },
            .Delete => {
                if (self.backend) |b| {
                    b.backend.InMemory.clear(self.allocator);
                    return null;
                } else {
                    return error.BackendNotInitialized;
                }
            },
        }
    }
};
