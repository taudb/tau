//! In-memory K/V backend for binary-encoded primitives using HashMap for O(1) lookups

const std = @import("std");
const Allocator = std.mem.Allocator;
const ByteSlice = []const u8;
const mem = std.mem;
const assert = std.debug.assert;

// Domain-specific types for better type safety
const KeyLength = u32;
const ValueLength = u32;

const KV = struct {
    key: []u8, // Owned
    value: []u8, // Owned
};

pub const InMemory = struct {
    kvs: std.StringHashMap([]u8), // HashMap for O(1) lookups
    allocator: Allocator,
    mutex: std.Thread.Mutex, // For thread safety

    pub fn init(allocator: Allocator) !InMemory {
        // Preconditions
        // assert(allocator.ptr != null); // Removed: Allocator is not a pointer
        assert(@intFromPtr(allocator.ptr) != 0);

        const backend = InMemory{
            .kvs = std.StringHashMap([]u8).init(allocator),
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };

        // Postconditions
        // assert(backend.allocator.ptr != null); // Removed: Allocator is not a pointer
        assert(@intFromPtr(backend.allocator.ptr) != 0);
        assert(backend.kvs.count() == 0);

        return backend;
    }

    pub fn deinit(self: *InMemory) void {
        // Preconditions
        // assert(self != null); // Removed: self is a pointer, can't be null

        var iterator = self.kvs.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.kvs.deinit();

        // Postconditions
        assert(@intFromPtr(self) != 0);
    }

    pub fn write(self: *InMemory, key: ByteSlice, value: ByteSlice) !void {
        // Preconditions
        // assert(self != null); // Removed: self is a pointer, can't be null
        assert(key.len > 0);
        assert(value.len > 0);

        self.mutex.lock();
        defer self.mutex.unlock();

        // Store key-value in HashMap (O(1) operation)
        const dup_key = try self.allocator.dupe(u8, key);
        const dup_val = try self.allocator.dupe(u8, value);

        try self.kvs.put(dup_key, dup_val);

        // Postcondition
        assert(self.kvs.contains(key));
    }

    pub fn read(self: *InMemory, key: ByteSlice) ![]u8 {
        // Preconditions
        // assert(self != null); // Removed: self is a pointer, can't be null
        assert(key.len > 0);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.kvs.get(key)) |value| {
            const result = try self.allocator.dupe(u8, value);
            // Postconditions
            assert(result.len == value.len);
            return result;
        } else {
            // Return empty slice for not found
            return &[_]u8{};
        }
    }

    pub fn delete(self: *InMemory, key: ByteSlice) !void {
        // Preconditions
        // assert(self != null); // Removed: self is a pointer, can't be null
        assert(key.len > 0);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.kvs.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);

            // Postcondition
            assert(!self.kvs.contains(key));
        } else {
            // Key didn't exist - should be idempotent
            assert(!self.kvs.contains(key));
        }
    }
};
