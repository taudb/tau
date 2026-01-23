//! In memory backend for storing binary encodings

const std = @import("std");
const Backend = @import("backend.zig").Backend;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ByteSlice = []const u8;
const mem = std.mem;
const fmt = std.fmt;
const debug = std.debug;

pub const InMemory = struct {
    storage: std.ArrayListUnmanaged(u8),
    // TODO: Replace storage type with a more efficient structure

    pub fn init() InMemory {
        return InMemory{
            .storage = std.ArrayListUnmanaged(u8){},
        };
    }

    pub fn write(self: *InMemory, allocator: Allocator, data: ByteSlice) !void {
        try self.storage.appendSlice(allocator, data);
    }

    pub fn read(self: *InMemory) ByteSlice {
        return self.storage.items;
    }

    pub fn clear(self: *InMemory, allocator: Allocator) void {
        self.storage.clearAndFree(allocator);
    }

    pub fn deinit(self: *InMemory, allocator: Allocator) void {
        self.storage.deinit(allocator);
    }
};

test "InMemory backend write and read" {
    const allocator = std.heap.page_allocator;
    var backend = try InMemory.init(allocator);

    const data: []const u8 = "Hello, In-Memory Backend!";
    try backend.write(data);

    const read_data = backend.read();
    try std.testing.expect(mem.eql(u8, data, read_data));

    backend.deinit();
}

test "InMemory backend clear" {
    const allocator = std.heap.page_allocator;
    var backend = try InMemory.init(allocator);

    const data: []const u8 = "Temporary Data";
    try backend.write(data);

    backend.clear();
    const read_data = backend.read();
    try std.testing.expect(read_data.len == 0);

    backend.deinit();
}

test "InMemory backend multiple writes" {
    const allocator = std.heap.page_allocator;
    var backend = try InMemory.init(allocator);

    const data1: []const u8 = "First Part, ";
    const data2: []const u8 = "Second Part.";
    try backend.write(data1);
    try backend.write(data2);

    const expected: []const u8 = "First Part, Second Part.";
    const read_data = backend.read();
    try std.testing.expect(mem.eql(u8, expected, read_data));

    backend.deinit();
}
