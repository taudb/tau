//! In-memory K/V backend for binary-encoded primitives using skip list

const std = @import("std");
const Allocator = std.mem.Allocator;
const ByteSlice = []const u8;
const mem = std.mem;

const KV = struct {
    key: []u8, // Owned
    value: []u8, // Owned
};

pub const InMemory = struct {
    kvs: std.ArrayListUnmanaged(KV),
    allocator: Allocator,

    pub fn init(allocator: Allocator) !InMemory {
        const assert = std.debug.assert;
        // Pre-condition assertions
        assert(allocator.ptr != null);
        assert(@intFromPtr(allocator) != 0);
        // Negative space: allocator should not be null
        assert(@intFromPtr(allocator.ptr) != 0);

        const backend = InMemory{
            .kvs = .{}, // empty unmanaged arraylist
            .allocator = allocator,
        };

        // Post-condition assertions
        assert(backend.allocator.ptr != null);
        assert(@intFromPtr(backend.allocator) != 0);
        assert(backend.kvs.items.len == 0);
        assert(@intFromPtr(&backend.kvs) != 0);

        return backend;
    }

    pub fn write(self: *InMemory, key: ByteSlice, value: ByteSlice) !void {
        const assert = std.debug.assert;
        // Pre-condition assertions
        assert(self != null);
        assert(@intFromPtr(self) != 0);
        assert(key.len > 0);
        assert(@intFromPtr(key.ptr) != 0);
        assert(value.len > 0);
        assert(@intFromPtr(value.ptr) != 0);
        // Negative space: key and value should not be empty
        assert(key.ptr != null);
        assert(value.ptr != null);
        assert(self.allocator.ptr != null);

        const initial_len = self.kvs.items.len;
        var key_found = false;

        // Search for existing key
        for (self.kvs.items) |*kv| {
            if (mem.eql(u8, kv.key, key)) {
                // Key exists: replace value
                assert(kv.key.len == key.len);
                self.allocator.free(kv.value);
                kv.value = try self.allocator.dupe(u8, value);
                key_found = true;
                break;
            }
        }

        if (!key_found) {
            // New key
            const dup_key = try self.allocator.dupe(u8, key);
            const dup_val = try self.allocator.dupe(u8, value);
            try self.kvs.append(self.allocator, KV{ .key = dup_key, .value = dup_val });
        }

        // Post-condition assertions
        assert(self.kvs.items.len >= initial_len);
        assert(self.kvs.items.len > 0 or key.len > 0);
        // Verify the key was written correctly
        var found_key = false;
        for (self.kvs.items) |kv| {
            if (mem.eql(u8, kv.key, key)) {
                found_key = true;
                assert(kv.value.len == value.len);
                break;
            }
        }
        assert(found_key);
    }

    pub fn read(self: *InMemory, key: ByteSlice) !ByteSlice {
        const assert = std.debug.assert;
        // Pre-condition assertions
        assert(self != null);
        assert(@intFromPtr(self) != 0);
        assert(key.len > 0);
        assert(@intFromPtr(key.ptr) != 0);
        // Negative space: key should not be empty
        assert(key.ptr != null);
        assert(self.allocator.ptr != null);

        var result: ByteSlice = undefined;
        var found = false;

        for (self.kvs.items) |kv| {
            if (mem.eql(u8, kv.key, key)) {
                // Return dupe (caller frees)
                assert(kv.value.len > 0);
                assert(@intFromPtr(kv.value.ptr) != 0);
                result = try self.allocator.dupe(u8, kv.value);
                found = true;
                break;
            }
        }

        if (!found) {
            // Not found: return empty slice
            result = &[_]u8{};
        }

        // Post-condition assertions
        assert(result.ptr != null);
        assert(@intFromPtr(result.ptr) != 0);
        // If key was found, result should have same length as stored value
        if (found) {
            assert(result.len > 0);
        } else {
            // If not found, result should be empty
            assert(result.len == 0);
        }

        return result;
    }

    pub fn delete(self: *InMemory, key: ByteSlice) void {
        const assert = std.debug.assert;
        // Pre-condition assertions
        assert(self != null);
        assert(@intFromPtr(self) != 0);
        assert(key.len > 0);
        assert(@intFromPtr(key.ptr) != 0);
        // Negative space: key should not be empty
        assert(key.ptr != null);
        assert(self.allocator.ptr != null);

        const initial_len = self.kvs.items.len;
        var key_found = false;
        var i: usize = 0;

        while (i < self.kvs.items.len) : (i += 1) {
            if (mem.eql(u8, self.kvs.items[i].key, key)) {
                assert(self.kvs.items[i].key.len == key.len);
                assert(@intFromPtr(self.kvs.items[i].key.ptr) != 0);
                assert(@intFromPtr(self.kvs.items[i].value.ptr) != 0);
                self.allocator.free(self.kvs.items[i].key);
                self.allocator.free(self.kvs.items[i].value);
                _ = self.kvs.swapRemove(i);
                key_found = true;
                break;
            }
        }

        // Post-condition assertions
        if (key_found) {
            assert(self.kvs.items.len == initial_len - 1);
        } else {
            assert(self.kvs.items.len == initial_len);
        }
        // Verify key is no longer present
        for (self.kvs.items) |kv| {
            assert(!mem.eql(u8, kv.key, key));
        }
    }

    pub fn clear(self: *InMemory) void {
        const assert = std.debug.assert;
        // Pre-condition assertions
        assert(self != null);
        assert(@intFromPtr(self) != 0);
        assert(self.allocator.ptr != null);
        assert(@intFromPtr(self.allocator) != 0);

        const initial_len = self.kvs.items.len;

        // Free all key/value slices and reset the arraylist
        for (self.kvs.items) |*kv| {
            assert(kv.key.len > 0);
            assert(kv.value.len > 0);
            assert(@intFromPtr(kv.key.ptr) != 0);
            assert(@intFromPtr(kv.value.ptr) != 0);
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
        self.kvs.clearRetainingCapacity();

        // Post-condition assertions
        assert(self.kvs.items.len == 0);
        assert(self.kvs.capacity >= initial_len); // capacity should be retained
        assert(@intFromPtr(&self.kvs) != 0);
    }

    pub fn deinit(self: *InMemory) void {
        const assert = std.debug.assert;
        // Pre-condition assertions
        assert(self != null);
        assert(@intFromPtr(self) != 0);
        assert(self.allocator.ptr != null);
        assert(@intFromPtr(self.allocator) != 0);

        self.clear();
        self.kvs.deinit(self.allocator);

        // Post-condition assertions
        assert(self.kvs.items.len == 0);
        assert(self.kvs.capacity == 0);
        assert(@intFromPtr(&self.kvs) != 0);
        assert(self.allocator.ptr != null);
    }

    // Ordered iteration/range methods not implemented for arraylist backend yet.
    // TODO: Implement if needed for K/V interface compatibility.
};

// --- Tests ---
test "InMemory K/V backend basic functionality" {
    const allocator = std.testing.allocator;
    var backend = try InMemory.init(allocator);
    defer backend.deinit();

    const k1 = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 };
    const v1 = "value1";
    const k2 = &[_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20 };
    const v2 = "value2";

    try backend.write(k1, v1);
    try backend.write(k2, v2);
    const res1 = try backend.read(k1);
    const res2 = try backend.read(k2);
    try std.testing.expect(mem.eql(u8, res1, v1));
    try std.testing.expect(mem.eql(u8, res2, v2));
    allocator.free(res1);
    allocator.free(res2);
}

test "InMemory K/V backend overwrite and delete" {
    const allocator = std.testing.allocator;
    var backend = try InMemory.init(allocator);
    defer backend.deinit();

    const k = &[_]u8{ 0x99, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x0A };
    const v1 = "bar";
    const v2 = "baz";
    try backend.write(k, v1);
    var res = try backend.read(k);
    try std.testing.expect(mem.eql(u8, res, v1));
    allocator.free(res);
    try backend.write(k, v2);
    res = try backend.read(k);
    try std.testing.expect(mem.eql(u8, res, v2));
    allocator.free(res);
    backend.delete(k);
    res = try backend.read(k);
    try std.testing.expect(res.len == 0);
    allocator.free(res);
}

test "InMemory K/V backend clear" {
    const allocator = std.testing.allocator;
    var backend = try InMemory.init(allocator);
    defer backend.deinit();

    for (1..10) |i| {
        var key_bytes: [16]u8 = undefined;
        var idx: usize = 0;
        while (idx < key_bytes.len) : (idx += 1) {
            key_bytes[idx] = @as(u8, (i + idx) & 0xFF);
        }
        const key = &key_bytes;
        const val = std.fmt.allocPrint(allocator, "v{d}", .{i}) catch unreachable;
        try backend.write(key, val);
        allocator.free(val);
    }

    backend.clear();

    for (1..10) |i| {
        var key_bytes: [16]u8 = undefined;
        var idx: usize = 0;
        while (idx < key_bytes.len) : (idx += 1) {
            key_bytes[idx] = @as(u8, (i + idx) & 0xFF);
        }
        const key = &key_bytes;
        const res = try backend.read(key);
        try std.testing.expect(res.len == 0);
    }
}
