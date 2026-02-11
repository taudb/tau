//! File-backed skip list storage backend for Series.

const std = @import("std");
const entities = @import("entities.zig");
const Timestamp = entities.Timestamp;

pub const skip_list_max_level: u32 = 20;
pub const skip_list_header_size: u32 = 4096;
pub const skip_list_magic = [8]u8{ 'T', 'A', 'U', 'S', 'K', 'I', 'P', 0 };
pub const skip_list_version: u32 = 1;

pub fn FileBackedSkipList(comptime T: type) type {
    comptime {
        const info = @typeInfo(T);
        std.debug.assert(info != .pointer);
        std.debug.assert(info != .optional);
        std.debug.assert(
            info == .int or
                info == .float or
                info == .@"enum" or
                info == .@"struct" or
                info == .array or
                info == .bool or
                info == .void,
        );
    }

    return struct {
        allocator: std.mem.Allocator,
        file: std.fs.File,
        header: Header,
        count: u32,

        const Self = @This();

        const node_size_bytes: u32 = @sizeOf(Node);

        const Header = extern struct {
            magic: [8]u8 = skip_list_magic,
            version: u32 = skip_list_version,
            node_size_bytes: u32 = node_size_bytes,
            max_level: u32 = skip_list_max_level,
            capacity_max: u32 = 0,
            count: u32 = 0,
            min_timestamp: i64 = 0,
            max_timestamp: i64 = 0,
            tails: [skip_list_max_level]u32 = [_]u32{0} ** skip_list_max_level,
            rng_state: u64 = 0,
            sequence: u64 = 0,
            checksum: u64 = 0,
            _padding: [skip_list_header_size - header_fields_size]u8 =
                [_]u8{0} ** (skip_list_header_size - header_fields_size),

            const header_fields_size: u32 = 152;

            comptime {
                std.debug.assert(@sizeOf(Header) == skip_list_header_size);
            }

            fn compute_checksum(self: *const Header) u64 {
                const bytes = std.mem.asBytes(self);
                const checksum_offset = @offsetOf(Header, "checksum");
                var hash = std.hash.Fnv1a_64.init();
                hash.update(bytes[0..checksum_offset]);
                hash.update(bytes[checksum_offset + 8 ..]);
                return hash.final();
            }

            fn write_checksum(self: *Header) void {
                self.checksum = self.compute_checksum();
            }

            fn validate_checksum(self: *const Header) bool {
                return self.checksum == self.compute_checksum();
            }
        };

        const Node = extern struct {
            timestamp: i64 = 0,
            value: T = std.mem.zeroes(T),
            height: u8 = 0,
            _reserved: [3]u8 = [_]u8{0} ** 3,
            next: [skip_list_max_level]u32 =
                [_]u32{0} ** skip_list_max_level,
        };

        comptime {
            std.debug.assert(@sizeOf(Node) == @sizeOf(Node));
        }

        pub fn init(
            allocator: std.mem.Allocator,
            dir_path: std.fs.Dir,
            label: [32]u8,
            point_count_max: u32,
        ) !Self {
            std.debug.assert(point_count_max > 0);
            std.debug.assert(point_count_max <= (1 << 20));

            const filename = derive_filename(label);
            const name = filename.slice();

            const maybe_file = dir_path.openFile(
                name,
                .{ .mode = .read_write },
            );

            if (maybe_file) |file| {
                return open_existing(allocator, file, point_count_max);
            } else |_| {
                return create_new(
                    allocator,
                    dir_path,
                    name,
                    point_count_max,
                );
            }
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(self.count <= self.header.capacity_max);
            std.debug.assert(self.count == self.header.count);

            self.flush_header() catch {};
            self.file.close();
            self.* = undefined;
        }

        pub fn append(
            self: *Self,
            timestamp: Timestamp,
            value: T,
        ) !void {
            std.debug.assert(self.count <= self.header.capacity_max);
            std.debug.assert(self.count == self.header.count);

            if (self.count >= self.header.capacity_max) {
                return error.SegmentFull;
            }

            if (self.count > 0) {
                if (timestamp <= self.header.max_timestamp) {
                    return error.OutOfOrder;
                }
            }

            const node_id: u32 = self.count + 1;
            const height = self.random_height();

            var node = Node{
                .timestamp = timestamp,
                .value = value,
                .height = @intCast(height),
            };

            var level: u32 = 0;
            while (level < height) : (level += 1) {
                node.next[level] = 0;
            }

            self.write_node(node_id, &node);

            level = 0;
            while (level < height) : (level += 1) {
                const tail_id = self.header.tails[level];
                if (tail_id != 0) {
                    self.update_node_next(tail_id, level, node_id);
                }
                self.header.tails[level] = node_id;
            }

            self.count += 1;
            self.header.count = self.count;

            if (self.count == 1) {
                self.header.min_timestamp = timestamp;
            }
            self.header.max_timestamp = timestamp;

            self.header.sequence += 1;
            self.flush_header() catch {};

            std.debug.assert(self.count <= self.header.capacity_max);
            std.debug.assert(self.count == self.header.count);
        }

        pub fn at(self: *const Self, timestamp: Timestamp) ?T {
            std.debug.assert(self.count <= self.header.capacity_max);

            if (self.count == 0) return null;
            if (timestamp < self.header.min_timestamp) return null;
            if (timestamp > self.header.max_timestamp) return null;

            var current_id: u32 = 0;
            var level_idx: u32 = skip_list_max_level;
            while (level_idx > 0) {
                level_idx -= 1;
                var next_id = if (current_id == 0)
                    self.first_at_level(level_idx)
                else
                    self.read_node_next(current_id, level_idx);

                while (next_id != 0) {
                    std.debug.assert(next_id >= 1);
                    std.debug.assert(next_id <= self.count);
                    const next_node = self.read_node(next_id);
                    if (next_node.timestamp == timestamp) {
                        return next_node.value;
                    }
                    if (next_node.timestamp < timestamp) {
                        current_id = next_id;
                        next_id = next_node.next[level_idx];
                    } else {
                        break;
                    }
                }
            }
            return null;
        }

        pub fn contains(self: *const Self, timestamp: Timestamp) bool {
            if (self.count == 0) return false;
            return timestamp >= self.header.min_timestamp and
                timestamp <= self.header.max_timestamp;
        }

        pub fn min_timestamp(self: *const Self) ?Timestamp {
            if (self.count == 0) return null;
            return self.header.min_timestamp;
        }

        pub fn max_timestamp(self: *const Self) ?Timestamp {
            if (self.count == 0) return null;
            return self.header.max_timestamp;
        }

        pub fn is_full(self: *const Self) bool {
            return self.count >= self.header.capacity_max;
        }

        pub fn capacity(self: *const Self) u32 {
            return self.header.capacity_max;
        }

        fn first_at_level(self: *const Self, level: u32) u32 {
            std.debug.assert(level < skip_list_max_level);
            if (self.count == 0) return 0;

            var node_id: u32 = 1;
            while (node_id <= self.count) : (node_id += 1) {
                const node = self.read_node(node_id);
                if (node.height > level) return node_id;
            }
            return 0;
        }

        fn random_height(self: *Self) u32 {
            var state = self.header.rng_state;
            var height: u32 = 1;
            while (height < skip_list_max_level) {
                state = splitmix64(state);
                if (state & 1 == 0) break;
                height += 1;
            }
            self.header.rng_state = state;
            return height;
        }

        fn splitmix64(state: u64) u64 {
            var z = state +% 0x9e3779b97f4a7c15;
            z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
            z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
            return z ^ (z >> 31);
        }

        const FilenameBuffer = struct {
            buf: [37]u8 = [_]u8{0} ** 37,
            len: u8 = 0,

            fn slice(self: *const FilenameBuffer) []const u8 {
                return self.buf[0..self.len];
            }
        };

        fn derive_filename(label: [32]u8) FilenameBuffer {
            var result = FilenameBuffer{};
            for (label) |byte| {
                if (byte == 0) break;
                if (result.len >= 32) break;
                result.buf[result.len] = byte;
                result.len += 1;
            }
            if (result.len == 0) {
                const default = "segment";
                @memcpy(result.buf[0..default.len], default);
                result.len = default.len;
            }
            const ext = ".skip";
            @memcpy(
                result.buf[result.len .. result.len + ext.len],
                ext,
            );
            result.len += ext.len;
            return result;
        }

        fn create_new(
            allocator: std.mem.Allocator,
            dir_path: std.fs.Dir,
            name: []const u8,
            point_count_max: u32,
        ) !Self {
            const file = try dir_path.createFile(
                name,
                .{ .read = true },
            );

            var header = Header{
                .capacity_max = point_count_max,
                .rng_state = 0x12345678_9abcdef0,
            };
            header.write_checksum();

            const header_bytes = std.mem.asBytes(&header);
            const written = try file.pwrite(header_bytes, 0);
            std.debug.assert(written == skip_list_header_size);

            return Self{
                .allocator = allocator,
                .file = file,
                .header = header,
                .count = 0,
            };
        }

        fn open_existing(
            allocator: std.mem.Allocator,
            file: std.fs.File,
            point_count_max: u32,
        ) !Self {
            var header_bytes: [skip_list_header_size]u8 = undefined;
            const bytes_read = try file.pread(&header_bytes, 0);
            if (bytes_read != skip_list_header_size) {
                return error.CorruptHeader;
            }

            const header: *Header = @ptrCast(
                @alignCast(&header_bytes),
            );

            if (!std.mem.eql(u8, &header.magic, &skip_list_magic)) {
                return error.CorruptHeader;
            }
            if (header.version != skip_list_version) {
                return error.VersionMismatch;
            }
            if (header.node_size_bytes != node_size_bytes) {
                return error.CorruptHeader;
            }
            if (!header.validate_checksum()) {
                return error.CorruptHeader;
            }

            std.debug.assert(header.count <= header.capacity_max);

            var self = Self{
                .allocator = allocator,
                .file = file,
                .header = header.*,
                .count = header.count,
            };

            _ = point_count_max;

            self.rebuild_skip_pointers();

            return self;
        }

        fn rebuild_skip_pointers(self: *Self) void {
            self.header.tails = [_]u32{0} ** skip_list_max_level;

            var node_id: u32 = 1;
            while (node_id <= self.count) : (node_id += 1) {
                const node = self.read_node(node_id);
                const height = node.height;
                std.debug.assert(height >= 1);
                std.debug.assert(height <= skip_list_max_level);

                var level: u32 = 0;
                while (level < height) : (level += 1) {
                    const tail_id = self.header.tails[level];
                    if (tail_id != 0) {
                        self.update_node_next(tail_id, level, node_id);
                    }
                    self.header.tails[level] = node_id;
                }
            }

            // Clear forward pointers of tail nodes.
            var level: u32 = 0;
            while (level < skip_list_max_level) : (level += 1) {
                const tail_id = self.header.tails[level];
                if (tail_id != 0) {
                    self.update_node_next(tail_id, level, 0);
                }
            }
        }

        fn node_offset(node_id: u32) u64 {
            std.debug.assert(node_id >= 1);
            return @as(u64, skip_list_header_size) +
                @as(u64, node_id - 1) * @as(u64, node_size_bytes);
        }

        fn write_node(self: *Self, node_id: u32, node: *const Node) void {
            std.debug.assert(node_id >= 1);
            std.debug.assert(node_id <= self.header.capacity_max);
            const offset = node_offset(node_id);
            const bytes = std.mem.asBytes(node);
            const written = self.file.pwrite(bytes, offset) catch 0;
            std.debug.assert(written == node_size_bytes);
        }

        fn read_node(self: *const Self, node_id: u32) Node {
            std.debug.assert(node_id >= 1);
            std.debug.assert(node_id <= self.count);
            const offset = node_offset(node_id);
            var node: Node = undefined;
            const bytes = std.mem.asBytes(&node);
            const bytes_read = self.file.pread(
                bytes,
                offset,
            ) catch 0;
            std.debug.assert(bytes_read == node_size_bytes);
            return node;
        }

        fn read_node_next(
            self: *const Self,
            node_id: u32,
            level: u32,
        ) u32 {
            std.debug.assert(node_id >= 1);
            std.debug.assert(node_id <= self.count);
            std.debug.assert(level < skip_list_max_level);
            const node = self.read_node(node_id);
            return node.next[level];
        }

        fn update_node_next(
            self: *Self,
            node_id: u32,
            level: u32,
            target_id: u32,
        ) void {
            std.debug.assert(node_id >= 1);
            std.debug.assert(node_id <= self.header.capacity_max);
            std.debug.assert(level < skip_list_max_level);
            var node = self.read_node(node_id);
            node.next[level] = target_id;
            self.write_node(node_id, &node);
        }

        fn flush_header(self: *Self) !void {
            std.debug.assert(self.count == self.header.count);
            self.header.write_checksum();
            const bytes = std.mem.asBytes(&self.header);
            const written = try self.file.pwrite(bytes, 0);
            std.debug.assert(written == skip_list_header_size);
        }
    };
}

const testing = std.testing;

const blank_label: [32]u8 = [_]u8{0} ** 32;

fn make_label(name: []const u8) [32]u8 {
    var label: [32]u8 = [_]u8{0} ** 32;
    const copy_len = @min(name.len, 32);
    @memcpy(label[0..copy_len], name[0..copy_len]);
    return label;
}

test "FileBackedSkipList.init creates empty skip list" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var sl = try FileBackedSkipList(u16).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_empty"),
        64,
    );
    defer sl.deinit();

    try testing.expectEqual(@as(u32, 0), sl.count);
    try testing.expectEqual(@as(u32, 64), sl.capacity());
    try testing.expect(!sl.is_full());
}

test "FileBackedSkipList.append stores timestamp-value pairs" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var sl = try FileBackedSkipList(u16).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_append"),
        64,
    );
    defer sl.deinit();

    try sl.append(10, 100);
    try sl.append(20, 200);
    try sl.append(30, 300);

    try testing.expectEqual(@as(u32, 3), sl.count);
    try testing.expectEqual(@as(?u16, 100), sl.at(10));
    try testing.expectEqual(@as(?u16, 200), sl.at(20));
    try testing.expectEqual(@as(?u16, 300), sl.at(30));
}

test "FileBackedSkipList.append rejects out-of-order timestamps" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var sl = try FileBackedSkipList(u16).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_order"),
        64,
    );
    defer sl.deinit();

    try sl.append(10, 100);
    try testing.expectError(
        error.OutOfOrder,
        sl.append(5, 50),
    );
    try testing.expectError(
        error.OutOfOrder,
        sl.append(10, 200),
    );
}

test "FileBackedSkipList.append rejects when full" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var sl = try FileBackedSkipList(u16).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_full"),
        2,
    );
    defer sl.deinit();

    try sl.append(1, 10);
    try sl.append(2, 20);
    try testing.expect(sl.is_full());
    try testing.expectError(
        error.SegmentFull,
        sl.append(3, 30),
    );
}

test "FileBackedSkipList.at returns null for missing timestamp" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var sl = try FileBackedSkipList(u16).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_miss"),
        64,
    );
    defer sl.deinit();

    try sl.append(1, 10);
    try sl.append(5, 50);
    try sl.append(9, 90);

    try testing.expectEqual(@as(?u16, null), sl.at(0));
    try testing.expectEqual(@as(?u16, null), sl.at(3));
    try testing.expectEqual(@as(?u16, null), sl.at(10));
}

test "FileBackedSkipList.at returns null on empty skip list" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var sl = try FileBackedSkipList(u16).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_empty_at"),
        64,
    );
    defer sl.deinit();

    try testing.expectEqual(@as(?u16, null), sl.at(0));
}

test "FileBackedSkipList.contains checks timestamp range" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var sl = try FileBackedSkipList(u16).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_contains"),
        64,
    );
    defer sl.deinit();

    try testing.expect(!sl.contains(0));

    try sl.append(5, 50);
    try sl.append(10, 100);

    try testing.expect(!sl.contains(4));
    try testing.expect(sl.contains(5));
    try testing.expect(sl.contains(7));
    try testing.expect(sl.contains(10));
    try testing.expect(!sl.contains(11));
}

test "FileBackedSkipList.min_timestamp and max_timestamp" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var sl = try FileBackedSkipList(u16).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_minmax"),
        64,
    );
    defer sl.deinit();

    try testing.expectEqual(
        @as(?Timestamp, null),
        sl.min_timestamp(),
    );
    try testing.expectEqual(
        @as(?Timestamp, null),
        sl.max_timestamp(),
    );

    try sl.append(3, 30);
    try sl.append(7, 70);

    try testing.expectEqual(
        @as(?Timestamp, 3),
        sl.min_timestamp(),
    );
    try testing.expectEqual(
        @as(?Timestamp, 7),
        sl.max_timestamp(),
    );
}

test "FileBackedSkipList works with f64 values" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var sl = try FileBackedSkipList(f64).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_f64"),
        64,
    );
    defer sl.deinit();

    try sl.append(10, 3.14);
    try sl.append(20, 2.71);

    try testing.expectApproxEqAbs(
        @as(f64, 3.14),
        sl.at(10).?,
        1e-10,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 2.71),
        sl.at(20).?,
        1e-10,
    );
    try testing.expectEqual(@as(?f64, null), sl.at(15));
}

test "FileBackedSkipList.at binary search at boundaries" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var sl = try FileBackedSkipList(u16).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_boundary"),
        64,
    );
    defer sl.deinit();

    try sl.append(1, 10);
    try sl.append(3, 30);
    try sl.append(5, 50);
    try sl.append(7, 70);
    try sl.append(9, 90);

    try testing.expectEqual(@as(?u16, 10), sl.at(1));
    try testing.expectEqual(@as(?u16, 90), sl.at(9));
    try testing.expectEqual(@as(?u16, 50), sl.at(5));
    try testing.expectEqual(@as(?u16, null), sl.at(2));
    try testing.expectEqual(@as(?u16, null), sl.at(8));
}

test "FileBackedSkipList persists across reopen" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const label = make_label("test_persist");

    {
        var sl = try FileBackedSkipList(u16).init(
            testing.allocator,
            tmp_dir.dir,
            label,
            64,
        );
        try sl.append(100, 1);
        try sl.append(200, 2);
        try sl.append(300, 3);
        sl.deinit();
    }

    {
        var sl = try FileBackedSkipList(u16).init(
            testing.allocator,
            tmp_dir.dir,
            label,
            64,
        );
        defer sl.deinit();

        try testing.expectEqual(@as(u32, 3), sl.count);
        try testing.expectEqual(@as(?u16, 1), sl.at(100));
        try testing.expectEqual(@as(?u16, 2), sl.at(200));
        try testing.expectEqual(@as(?u16, 3), sl.at(300));
        try testing.expectEqual(
            @as(?Timestamp, 100),
            sl.min_timestamp(),
        );
        try testing.expectEqual(
            @as(?Timestamp, 300),
            sl.max_timestamp(),
        );
    }
}

test "FileBackedSkipList rebuilds skip pointers on open" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const label = make_label("test_rebuild");

    {
        var sl = try FileBackedSkipList(u16).init(
            testing.allocator,
            tmp_dir.dir,
            label,
            128,
        );
        var ts: Timestamp = 1;
        while (ts <= 50) : (ts += 1) {
            try sl.append(ts, @intCast(@as(u32, @intCast(ts)) * 10));
        }
        sl.deinit();
    }

    {
        var sl = try FileBackedSkipList(u16).init(
            testing.allocator,
            tmp_dir.dir,
            label,
            128,
        );
        defer sl.deinit();

        try testing.expectEqual(@as(u32, 50), sl.count);

        try testing.expectEqual(@as(?u16, 10), sl.at(1));
        try testing.expectEqual(@as(?u16, 250), sl.at(25));
        try testing.expectEqual(@as(?u16, 500), sl.at(50));
        try testing.expectEqual(@as(?u16, null), sl.at(0));
        try testing.expectEqual(@as(?u16, null), sl.at(51));
    }
}
