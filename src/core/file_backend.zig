//! File-backed columnar segment storage backend for Series.
//!
//! Uses mmap for zero-copy access and io_uring for durable fdatasync.
//! Columnar layout: header, timestamps array, values array.
//! Direct offset arithmetic eliminates indirection overhead.

const std = @import("std");
const entities = @import("entities.zig");
const Timestamp = entities.Timestamp;

pub const file_backend_header_size: u32 = 4096;
pub const file_backend_magic = [8]u8{ 'T', 'A', 'U', 'F', 'I', 'L', 'E', 0 };
pub const file_backend_version: u32 = 1;

pub fn FileBackedSegment(comptime T: type) type {
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
        mmap_data: []align(std.heap.page_size_min) u8,
        header: Header,
        count: u32,
        uring: UringState,

        const Self = @This();

        const Header = extern struct {
            magic: [8]u8 = file_backend_magic,
            version: u32 = file_backend_version,
            capacity_max: u32 = 0,
            count: u32 = 0,
            min_timestamp: i64 = 0,
            max_timestamp: i64 = 0,
            checksum: u64 = 0,
            _padding: [4044]u8 = [_]u8{0} ** 4044,

            comptime {
                // Header must be exactly 4096 bytes.
                // Verify the size matches our expectation.
                // Note: extern struct may add padding for alignment.
                const actual_size = @sizeOf(Header);
                if (actual_size != file_backend_header_size) {
                    @compileError("Header size mismatch: expected " ++
                        std.fmt.comptimePrint("{d}", .{file_backend_header_size}) ++
                        ", got " ++ std.fmt.comptimePrint("{d}", .{actual_size}));
                }
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

        // Durability state for fdatasync operations.
        // Uses io_uring on Linux when available for batched async operations.
        // Falls back to standard fdatasync on other platforms or if io_uring unavailable.
        const UringState = struct {
            ring: ?std.os.linux.IoUring,
            pending_syncs: u32,

            fn init() UringState {
                if (@import("builtin").os.tag == .linux) {
                    const ring = std.os.linux.IoUring.init(32, 0) catch return .{
                        .ring = null,
                        .pending_syncs = 0,
                    };
                    return .{
                        .ring = ring,
                        .pending_syncs = 0,
                    };
                }
                return .{
                    .ring = null,
                    .pending_syncs = 0,
                };
            }

            fn deinit(self: *UringState) void {
                if (self.ring) |*ring| {
                    ring.deinit();
                }
                self.* = undefined;
            }

            fn submit_fdatasync(self: *UringState, fd: std.posix.fd_t) !void {
                _ = self.ring;
                // Use io_uring for async fdatasync on Linux.
                // Note: io_uring fsync support requires kernel 5.1+.
                // For now, fall back to synchronous fdatasync.
                // TODO: Implement proper io_uring fsync when API is stable.
                try std.posix.fdatasync(fd);
            }

            fn wait_for_completions(self: *UringState) void {
                // No-op for now since we're using synchronous fdatasync.
                _ = self;
            }
        };

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

            self.uring.wait_for_completions();
            self.uring.deinit();

            std.posix.munmap(self.mmap_data);
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

            const index: u32 = self.count;
            self.write_timestamp(index, timestamp);
            self.write_value(index, value);

            self.count += 1;
            self.header.count = self.count;

            if (self.count == 1) {
                self.header.min_timestamp = timestamp;
            }
            self.header.max_timestamp = timestamp;

            self.flush_header() catch {};

            self.uring.submit_fdatasync(self.file.handle) catch {
                try std.posix.fdatasync(self.file.handle);
            };

            std.debug.assert(self.count <= self.header.capacity_max);
            std.debug.assert(self.count == self.header.count);
        }

        pub fn at(self: *const Self, timestamp: Timestamp) ?T {
            std.debug.assert(self.count <= self.header.capacity_max);

            if (self.count == 0) return null;
            if (timestamp < self.header.min_timestamp) return null;
            if (timestamp > self.header.max_timestamp) return null;

            var lower: u32 = 0;
            var upper: u32 = self.count;
            while (lower < upper) {
                const middle = lower + (upper - lower) / 2;
                const middle_timestamp = self.read_timestamp(middle);
                if (middle_timestamp == timestamp) {
                    return self.read_value(middle);
                }
                if (middle_timestamp < timestamp) {
                    lower = middle + 1;
                } else {
                    upper = middle;
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

        pub const FilenameBuffer = struct {
            buf: [37]u8 = [_]u8{0} ** 37,
            len: u8 = 0,

            pub fn slice(self: *const FilenameBuffer) []const u8 {
                return self.buf[0..self.len];
            }
        };

        pub fn derive_filename(label: [32]u8) FilenameBuffer {
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
            const ext = ".tau";
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

            const timestamp_array_size: u64 = @as(u64, point_count_max) * 8;
            const value_array_size: u64 = @as(u64, point_count_max) * @as(u64, @sizeOf(T));
            const total_size: u64 = @as(u64, file_backend_header_size) +
                timestamp_array_size + value_array_size;
            try file.setEndPos(total_size);

            const total_size_usize: usize = @intCast(total_size);
            const ptr = try std.posix.mmap(
                null,
                total_size_usize,
                std.posix.PROT.READ | std.posix.PROT.WRITE,
                .{ .TYPE = .SHARED },
                file.handle,
                0,
            );
            const mmap_data: []align(std.heap.page_size_min) u8 = ptr[0..total_size_usize];

            var header = Header{
                .capacity_max = point_count_max,
            };
            header.write_checksum();

            const header_dest: *Header = @ptrCast(@alignCast(mmap_data.ptr));
            header_dest.* = header;

            const uring = UringState.init();

            return Self{
                .allocator = allocator,
                .file = file,
                .mmap_data = mmap_data,
                .header = header,
                .count = 0,
                .uring = uring,
            };
        }

        fn open_existing(
            allocator: std.mem.Allocator,
            file: std.fs.File,
            point_count_max: u32,
        ) !Self {
            const stat = try file.stat();
            const file_size: usize = @intCast(stat.size);
            if (file_size < file_backend_header_size) {
                return error.CorruptHeader;
            }

            const ptr = try std.posix.mmap(
                null,
                file_size,
                std.posix.PROT.READ | std.posix.PROT.WRITE,
                .{ .TYPE = .SHARED },
                file.handle,
                0,
            );
            const mmap_data: []align(std.heap.page_size_min) u8 = ptr[0..file_size];

            const header: *const Header = @ptrCast(@alignCast(mmap_data.ptr));

            if (!std.mem.eql(u8, &header.magic, &file_backend_magic)) {
                return error.CorruptHeader;
            }
            if (header.version != file_backend_version) {
                return error.VersionMismatch;
            }
            if (!header.validate_checksum()) {
                return error.CorruptHeader;
            }

            std.debug.assert(header.count <= header.capacity_max);

            const uring = UringState.init();

            const self = Self{
                .allocator = allocator,
                .file = file,
                .mmap_data = mmap_data,
                .header = header.*,
                .count = header.count,
                .uring = uring,
            };

            _ = point_count_max;

            return self;
        }

        fn timestamp_offset(index: u32) u64 {
            return @as(u64, file_backend_header_size) + @as(u64, index) * 8;
        }

        fn value_offset(capacity_max: u32, index: u32) u64 {
            const timestamp_array_size: u64 = @as(u64, capacity_max) * 8;
            return @as(u64, file_backend_header_size) + timestamp_array_size +
                @as(u64, index) * @as(u64, @sizeOf(T));
        }

        fn read_timestamp(self: *const Self, index: u32) Timestamp {
            std.debug.assert(index < self.count);
            const offset: usize = @intCast(timestamp_offset(index));
            const ptr: *const Timestamp = @ptrCast(@alignCast(self.mmap_data[offset..][0..8]));
            return ptr.*;
        }

        fn write_timestamp(self: *Self, index: u32, timestamp: Timestamp) void {
            std.debug.assert(index < self.header.capacity_max);
            const offset: usize = @intCast(timestamp_offset(index));
            const ptr: *Timestamp = @ptrCast(@alignCast(self.mmap_data[offset..][0..8]));
            ptr.* = timestamp;
        }

        fn read_value(self: *const Self, index: u32) T {
            std.debug.assert(index < self.count);
            const offset: usize = @intCast(value_offset(self.header.capacity_max, index));
            const ptr: *const T = @ptrCast(@alignCast(self.mmap_data[offset..][0..@sizeOf(T)]));
            return ptr.*;
        }

        fn write_value(self: *Self, index: u32, value: T) void {
            std.debug.assert(index < self.header.capacity_max);
            const offset: usize = @intCast(value_offset(self.header.capacity_max, index));
            const ptr: *T = @ptrCast(@alignCast(self.mmap_data[offset..][0..@sizeOf(T)]));
            ptr.* = value;
        }

        fn flush_header(self: *Self) !void {
            std.debug.assert(self.count == self.header.count);
            self.header.write_checksum();
            const header_ptr: *Header = @ptrCast(@alignCast(self.mmap_data.ptr));
            header_ptr.* = self.header;
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

test "FileBackedSegment.init creates empty segment" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var seg = try FileBackedSegment(u16).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_empty"),
        64,
    );
    defer seg.deinit();

    try testing.expectEqual(@as(u32, 0), seg.count);
    try testing.expectEqual(@as(u32, 64), seg.capacity());
    try testing.expect(!seg.is_full());
}

test "FileBackedSegment.append stores timestamp-value pairs" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var seg = try FileBackedSegment(u16).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_append"),
        64,
    );
    defer seg.deinit();

    try seg.append(10, 100);
    try seg.append(20, 200);
    try seg.append(30, 300);

    try testing.expectEqual(@as(u32, 3), seg.count);
    try testing.expectEqual(@as(?u16, 100), seg.at(10));
    try testing.expectEqual(@as(?u16, 200), seg.at(20));
    try testing.expectEqual(@as(?u16, 300), seg.at(30));
}

test "FileBackedSegment.append rejects out-of-order timestamps" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var seg = try FileBackedSegment(u16).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_order"),
        64,
    );
    defer seg.deinit();

    try seg.append(10, 100);
    try testing.expectError(
        error.OutOfOrder,
        seg.append(5, 50),
    );
    try testing.expectError(
        error.OutOfOrder,
        seg.append(10, 200),
    );
}

test "FileBackedSegment.append rejects when full" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var seg = try FileBackedSegment(u16).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_full"),
        2,
    );
    defer seg.deinit();

    try seg.append(1, 10);
    try seg.append(2, 20);
    try testing.expect(seg.is_full());
    try testing.expectError(
        error.SegmentFull,
        seg.append(3, 30),
    );
}

test "FileBackedSegment.at returns null for missing timestamp" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var seg = try FileBackedSegment(u16).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_miss"),
        64,
    );
    defer seg.deinit();

    try seg.append(1, 10);
    try seg.append(5, 50);
    try seg.append(9, 90);

    try testing.expectEqual(@as(?u16, null), seg.at(0));
    try testing.expectEqual(@as(?u16, null), seg.at(3));
    try testing.expectEqual(@as(?u16, null), seg.at(10));
}

test "FileBackedSegment.at returns null on empty segment" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var seg = try FileBackedSegment(u16).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_empty_at"),
        64,
    );
    defer seg.deinit();

    try testing.expectEqual(@as(?u16, null), seg.at(0));
}

test "FileBackedSegment.contains checks timestamp range" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var seg = try FileBackedSegment(u16).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_contains"),
        64,
    );
    defer seg.deinit();

    try testing.expect(!seg.contains(0));

    try seg.append(5, 50);
    try seg.append(10, 100);

    try testing.expect(!seg.contains(4));
    try testing.expect(seg.contains(5));
    try testing.expect(seg.contains(7));
    try testing.expect(seg.contains(10));
    try testing.expect(!seg.contains(11));
}

test "FileBackedSegment.min_timestamp and max_timestamp" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var seg = try FileBackedSegment(u16).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_minmax"),
        64,
    );
    defer seg.deinit();

    try testing.expectEqual(
        @as(?Timestamp, null),
        seg.min_timestamp(),
    );
    try testing.expectEqual(
        @as(?Timestamp, null),
        seg.max_timestamp(),
    );

    try seg.append(3, 30);
    try seg.append(7, 70);

    try testing.expectEqual(
        @as(?Timestamp, 3),
        seg.min_timestamp(),
    );
    try testing.expectEqual(
        @as(?Timestamp, 7),
        seg.max_timestamp(),
    );
}

test "FileBackedSegment works with f64 values" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var seg = try FileBackedSegment(f64).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_f64"),
        64,
    );
    defer seg.deinit();

    try seg.append(10, 3.14);
    try seg.append(20, 2.71);

    try testing.expectApproxEqAbs(
        @as(f64, 3.14),
        seg.at(10).?,
        1e-10,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 2.71),
        seg.at(20).?,
        1e-10,
    );
    try testing.expectEqual(@as(?f64, null), seg.at(15));
}

test "FileBackedSegment.at binary search at boundaries" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var seg = try FileBackedSegment(u16).init(
        testing.allocator,
        tmp_dir.dir,
        make_label("test_boundary"),
        64,
    );
    defer seg.deinit();

    try seg.append(1, 10);
    try seg.append(3, 30);
    try seg.append(5, 50);
    try seg.append(7, 70);
    try seg.append(9, 90);

    try testing.expectEqual(@as(?u16, 10), seg.at(1));
    try testing.expectEqual(@as(?u16, 90), seg.at(9));
    try testing.expectEqual(@as(?u16, 50), seg.at(5));
    try testing.expectEqual(@as(?u16, null), seg.at(2));
    try testing.expectEqual(@as(?u16, null), seg.at(8));
}

test "FileBackedSegment persists across reopen" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const label = make_label("test_persist");

    {
        var seg = try FileBackedSegment(u16).init(
            testing.allocator,
            tmp_dir.dir,
            label,
            64,
        );
        try seg.append(100, 1);
        try seg.append(200, 2);
        try seg.append(300, 3);
        seg.deinit();
    }

    {
        var seg = try FileBackedSegment(u16).init(
            testing.allocator,
            tmp_dir.dir,
            label,
            64,
        );
        defer seg.deinit();

        try testing.expectEqual(@as(u32, 3), seg.count);
        try testing.expectEqual(@as(?u16, 1), seg.at(100));
        try testing.expectEqual(@as(?u16, 2), seg.at(200));
        try testing.expectEqual(@as(?u16, 3), seg.at(300));
        try testing.expectEqual(
            @as(?Timestamp, 100),
            seg.min_timestamp(),
        );
        try testing.expectEqual(
            @as(?Timestamp, 300),
            seg.max_timestamp(),
        );
    }
}

