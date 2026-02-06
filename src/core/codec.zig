//! Block-based delta compression for columnar time-series data.
//!
//! Two encoding schemes are used together:
//! 1. Delta-of-delta with ZigZag varint for timestamps.
//! 2. XOR with leading-zeros elimination for f64 values.

const std = @import("std");

pub const block_size_max: u32 = 1024;

/// Worst-case buffer: a varint can be up to 10 bytes, plus overhead.
pub const block_data_max: u32 = block_size_max * 12;

pub const CompressedBlock = struct {
    timestamp_data: [block_data_max]u8,
    timestamp_len: u32,
    value_data: [block_data_max]u8,
    value_len: u32,
    count: u32,
    first_timestamp: i64,
    last_timestamp: i64,
};

// Compile-time sanity checks on constants.
comptime {
    std.debug.assert(block_size_max > 0);
    std.debug.assert(block_size_max <= 65536);
    std.debug.assert(block_data_max >= block_size_max);
    std.debug.assert(block_data_max == block_size_max * 12);
}

/// Encode a block of timestamp-value pairs into a compressed block.
pub fn encode_block(
    timestamps: []const i64,
    values: []const f64,
    out: *CompressedBlock,
) void {
    const count: u32 = @intCast(timestamps.len);
    std.debug.assert(count > 0);
    std.debug.assert(count <= block_size_max);
    std.debug.assert(timestamps.len == values.len);

    out.count = count;
    out.first_timestamp = timestamps[0];
    out.last_timestamp = timestamps[count - 1];

    out.timestamp_len = encode_timestamps(timestamps, &out.timestamp_data);
    out.value_len = encode_values(values, &out.value_data);

    std.debug.assert(out.timestamp_len > 0);
    std.debug.assert(out.value_len > 0);
}

/// Decode a compressed block back to raw timestamp and value arrays.
pub fn decode_block(
    block: *const CompressedBlock,
    timestamps_out: []i64,
    values_out: []f64,
) u32 {
    std.debug.assert(block.count > 0);
    std.debug.assert(block.count <= block_size_max);
    std.debug.assert(timestamps_out.len >= block.count);
    std.debug.assert(values_out.len >= block.count);

    const ts_count = decode_timestamps(block, timestamps_out);
    const val_count = decode_values_from_block(block, values_out);

    std.debug.assert(ts_count == block.count);
    std.debug.assert(val_count == block.count);
    return block.count;
}

/// Decode only timestamps from a compressed block, useful for
/// binary search without the cost of decoding values.
pub fn decode_timestamps(
    block: *const CompressedBlock,
    timestamps_out: []i64,
) u32 {
    std.debug.assert(block.count > 0);
    std.debug.assert(block.count <= block_size_max);
    std.debug.assert(timestamps_out.len >= block.count);

    var pos: u32 = 0;
    const raw_t0 = read_raw_i64(&block.timestamp_data, &pos);
    timestamps_out[0] = raw_t0;

    if (block.count == 1) {
        std.debug.assert(pos == 8);
        return 1;
    }

    const raw_d0 = read_raw_i64(&block.timestamp_data, &pos);
    timestamps_out[1] = raw_t0 + raw_d0;

    var prev_delta: i64 = raw_d0;
    var index: u32 = 2;
    while (index < block.count) : (index += 1) {
        const dd = zigzag_decode(read_varint(
            &block.timestamp_data,
            &pos,
        ));
        const delta = prev_delta + dd;
        timestamps_out[index] = timestamps_out[index - 1] + delta;
        prev_delta = delta;
    }

    std.debug.assert(timestamps_out[0] == block.first_timestamp);
    return block.count;
}

// --- Timestamp encoding/decoding helpers ---

fn encode_timestamps(
    timestamps: []const i64,
    buf: *[block_data_max]u8,
) u32 {
    std.debug.assert(timestamps.len > 0);
    std.debug.assert(timestamps.len <= block_size_max);

    var pos: u32 = 0;
    write_raw_i64(buf, &pos, timestamps[0]);

    if (timestamps.len == 1) {
        std.debug.assert(pos == 8);
        return pos;
    }

    const delta0 = timestamps[1] - timestamps[0];
    write_raw_i64(buf, &pos, delta0);

    var prev_delta: i64 = delta0;
    var index: u32 = 2;
    const count: u32 = @intCast(timestamps.len);
    while (index < count) : (index += 1) {
        const delta = timestamps[index] - timestamps[index - 1];
        const dd = delta - prev_delta;
        write_varint(buf, &pos, zigzag_encode(dd));
        prev_delta = delta;
    }

    std.debug.assert(pos <= block_data_max);
    return pos;
}

// --- Value encoding/decoding helpers ---

fn encode_values(
    values: []const f64,
    buf: *[block_data_max]u8,
) u32 {
    std.debug.assert(values.len > 0);
    std.debug.assert(values.len <= block_size_max);

    var pos: u32 = 0;
    var prev_bits: u64 = @bitCast(values[0]);
    write_raw_u64(buf, &pos, prev_bits);

    var index: u32 = 1;
    const count: u32 = @intCast(values.len);
    while (index < count) : (index += 1) {
        const curr_bits: u64 = @bitCast(values[index]);
        const xor = curr_bits ^ prev_bits;
        if (xor == 0) {
            buf[pos] = 0x00;
            pos += 1;
        } else {
            encode_xor_value(buf, &pos, xor);
        }
        prev_bits = curr_bits;
    }

    std.debug.assert(pos <= block_data_max);
    return pos;
}

fn encode_xor_value(
    buf: *[block_data_max]u8,
    pos: *u32,
    xor: u64,
) void {
    std.debug.assert(xor != 0);
    std.debug.assert(pos.* < block_data_max);

    const leading: u8 = @intCast(@clz(xor) >> 3);
    const trailing: u8 = @intCast(@ctz(xor) >> 3);
    const significant: u8 = if (8 - leading > trailing)
        8 - leading - trailing
    else
        8 - leading;
    const actual_trailing: u8 = 8 - leading - significant;

    buf[pos.*] = (leading << 4) | significant;
    pos.* += 1;

    const trail_shift: u6 = @intCast(@as(u32, actual_trailing) * 8);
    const shifted = xor >> trail_shift;
    var byte_index: u8 = 0;
    while (byte_index < significant) : (byte_index += 1) {
        const shift: u6 = @intCast(
            (@as(u32, significant) - 1 - @as(u32, byte_index)) * 8,
        );
        buf[pos.*] = @truncate(shifted >> shift);
        pos.* += 1;
    }

    std.debug.assert(pos.* <= block_data_max);
}

fn decode_values_from_block(
    block: *const CompressedBlock,
    values_out: []f64,
) u32 {
    std.debug.assert(block.count > 0);
    std.debug.assert(values_out.len >= block.count);

    var pos: u32 = 0;
    var prev_bits = read_raw_u64(&block.value_data, &pos);
    values_out[0] = @bitCast(prev_bits);

    var index: u32 = 1;
    while (index < block.count) : (index += 1) {
        const tag = block.value_data[pos];
        pos += 1;
        if (tag == 0x00) {
            values_out[index] = @bitCast(prev_bits);
        } else {
            const xor = decode_xor_value(
                &block.value_data,
                &pos,
                tag,
            );
            prev_bits ^= xor;
            values_out[index] = @bitCast(prev_bits);
        }
    }

    std.debug.assert(index == block.count);
    return block.count;
}

fn decode_xor_value(
    buf: *const [block_data_max]u8,
    pos: *u32,
    tag: u8,
) u64 {
    std.debug.assert(tag != 0x00);
    std.debug.assert(pos.* < block_data_max);

    const leading: u8 = tag >> 4;
    const significant: u8 = tag & 0x0F;
    const actual_trailing: u8 = 8 - leading - significant;

    var result: u64 = 0;
    var byte_index: u8 = 0;
    while (byte_index < significant) : (byte_index += 1) {
        result = (result << 8) | @as(u64, buf[pos.*]);
        pos.* += 1;
    }
    const trail_shift: u6 = @intCast(@as(u32, actual_trailing) * 8);
    result <<= trail_shift;

    std.debug.assert(result != 0);
    return result;
}

// --- Raw integer read/write helpers ---

fn write_raw_i64(
    buf: *[block_data_max]u8,
    pos: *u32,
    value: i64,
) void {
    std.debug.assert(pos.* + 8 <= block_data_max);
    std.debug.assert(pos.* <= block_data_max - 8);
    const le = std.mem.nativeToLittle(i64, value);
    const bytes = std.mem.toBytes(le);
    @memcpy(buf[pos.*..][0..8], &bytes);
    pos.* += 8;
}

fn read_raw_i64(
    buf: *const [block_data_max]u8,
    pos: *u32,
) i64 {
    std.debug.assert(pos.* + 8 <= block_data_max);
    std.debug.assert(pos.* <= block_data_max - 8);
    const bytes: [8]u8 = buf[pos.*..][0..8].*;
    pos.* += 8;
    return std.mem.littleToNative(i64, @bitCast(bytes));
}

fn write_raw_u64(
    buf: *[block_data_max]u8,
    pos: *u32,
    value: u64,
) void {
    std.debug.assert(pos.* + 8 <= block_data_max);
    std.debug.assert(pos.* <= block_data_max - 8);
    const le = std.mem.nativeToLittle(u64, value);
    const bytes = std.mem.toBytes(le);
    @memcpy(buf[pos.*..][0..8], &bytes);
    pos.* += 8;
}

fn read_raw_u64(
    buf: *const [block_data_max]u8,
    pos: *u32,
) u64 {
    std.debug.assert(pos.* + 8 <= block_data_max);
    std.debug.assert(pos.* <= block_data_max - 8);
    const bytes: [8]u8 = buf[pos.*..][0..8].*;
    pos.* += 8;
    return std.mem.littleToNative(u64, @bitCast(bytes));
}

// --- ZigZag varint helpers ---

fn zigzag_encode(value: i64) u64 {
    const v: u64 = @bitCast(value);
    const sign: u64 = @bitCast(value >> 63);
    const result = (v << 1) ^ sign;
    // Positive values produce even results, negatives produce odd.
    if (value >= 0) std.debug.assert(result & 1 == 0);
    if (value < 0) std.debug.assert(result & 1 == 1);
    return result;
}

fn zigzag_decode(value: u64) i64 {
    const shifted = value >> 1;
    const mask: u64 = @bitCast(-@as(i64, @intCast(value & 1)));
    const result: i64 = @bitCast(shifted ^ mask);
    // Round-trip property: re-encoding must yield the original.
    std.debug.assert(zigzag_encode(result) == value);
    return result;
}

fn write_varint(
    buf: *[block_data_max]u8,
    pos: *u32,
    value: u64,
) void {
    std.debug.assert(pos.* < block_data_max);

    var v = value;
    var bytes_written: u32 = 0;
    while (bytes_written < 10) : (bytes_written += 1) {
        if (v < 0x80) {
            buf[pos.*] = @truncate(v);
            pos.* += 1;
            std.debug.assert(bytes_written < 10);
            return;
        }
        buf[pos.*] = @truncate(v | 0x80);
        pos.* += 1;
        v >>= 7;
    }
    // Unreachable: a u64 always fits in 10 varint bytes.
    unreachable;
}

fn read_varint(
    buf: *const [block_data_max]u8,
    pos: *u32,
) u64 {
    std.debug.assert(pos.* < block_data_max);

    var result: u64 = 0;
    var shift: u6 = 0;
    var bytes_read: u32 = 0;
    while (bytes_read < 10) : (bytes_read += 1) {
        const byte = buf[pos.*];
        pos.* += 1;
        result |= @as(u64, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) {
            std.debug.assert(bytes_read < 10);
            return result;
        }
        shift +|= 7;
    }
    // Unreachable: a valid varint is at most 10 bytes.
    unreachable;
}

// --- Tests ---

const testing = std.testing;

test "encode_decode_single_point" {
    const timestamps = [_]i64{1000};
    const values = [_]f64{3.14};
    var block: CompressedBlock = undefined;

    encode_block(&timestamps, &values, &block);

    try testing.expectEqual(@as(u32, 1), block.count);
    try testing.expectEqual(@as(i64, 1000), block.first_timestamp);
    try testing.expectEqual(@as(i64, 1000), block.last_timestamp);

    var ts_out: [1]i64 = undefined;
    var val_out: [1]f64 = undefined;
    const count = decode_block(&block, &ts_out, &val_out);

    try testing.expectEqual(@as(u32, 1), count);
    try testing.expectEqual(@as(i64, 1000), ts_out[0]);
    try testing.expectApproxEqAbs(@as(f64, 3.14), val_out[0], 1e-15);
}

test "encode_decode_constant_delta" {
    var timestamps: [100]i64 = undefined;
    var values: [100]f64 = undefined;
    var index: u32 = 0;
    while (index < 100) : (index += 1) {
        timestamps[index] = 1000 + @as(i64, index) * 10;
        values[index] = @as(f64, @floatFromInt(index)) * 1.5;
    }

    var block: CompressedBlock = undefined;
    encode_block(&timestamps, &values, &block);

    try testing.expectEqual(@as(u32, 100), block.count);
    try testing.expectEqual(@as(i64, 1000), block.first_timestamp);
    try testing.expectEqual(@as(i64, 1990), block.last_timestamp);

    var ts_out: [100]i64 = undefined;
    var val_out: [100]f64 = undefined;
    const count = decode_block(&block, &ts_out, &val_out);

    try testing.expectEqual(@as(u32, 100), count);
    index = 0;
    while (index < 100) : (index += 1) {
        try testing.expectEqual(timestamps[index], ts_out[index]);
        try testing.expectApproxEqAbs(
            values[index],
            val_out[index],
            1e-15,
        );
    }
}

test "encode_decode_varying_delta" {
    const timestamps = [_]i64{ 100, 105, 130, 131, 200, 500 };
    const values = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 };
    var block: CompressedBlock = undefined;

    encode_block(&timestamps, &values, &block);

    try testing.expectEqual(@as(u32, 6), block.count);
    try testing.expectEqual(@as(i64, 100), block.first_timestamp);
    try testing.expectEqual(@as(i64, 500), block.last_timestamp);

    var ts_out: [6]i64 = undefined;
    var val_out: [6]f64 = undefined;
    const count = decode_block(&block, &ts_out, &val_out);

    try testing.expectEqual(@as(u32, 6), count);
    var index: u32 = 0;
    while (index < 6) : (index += 1) {
        try testing.expectEqual(timestamps[index], ts_out[index]);
        try testing.expectApproxEqAbs(
            values[index],
            val_out[index],
            1e-15,
        );
    }
}

test "encode_decode_identical_values" {
    var timestamps: [50]i64 = undefined;
    var values: [50]f64 = undefined;
    var index: u32 = 0;
    while (index < 50) : (index += 1) {
        timestamps[index] = @as(i64, index) * 100;
        values[index] = 42.0;
    }

    var block: CompressedBlock = undefined;
    encode_block(&timestamps, &values, &block);

    try testing.expectEqual(@as(u32, 50), block.count);

    // Identical values should compress well: 8 bytes for first value
    // plus 1 byte per subsequent identical value.
    try testing.expect(block.value_len <= 8 + 49);

    var ts_out: [50]i64 = undefined;
    var val_out: [50]f64 = undefined;
    const count = decode_block(&block, &ts_out, &val_out);

    try testing.expectEqual(@as(u32, 50), count);
    index = 0;
    while (index < 50) : (index += 1) {
        try testing.expectEqual(@as(f64, 42.0), val_out[index]);
    }
}

test "encode_decode_random_values" {
    const test_values = [_]f64{
        0.0,         -0.0,          1.0,
        -1.0,        1e-300,        1e300,
        -1e-300,     -1e300,        std.math.pi,
        std.math.e,  2.2250738585072014e-308,
        1.7976931348623157e308,
    };
    var timestamps: [test_values.len]i64 = undefined;
    var index: u32 = 0;
    while (index < test_values.len) : (index += 1) {
        timestamps[index] = @as(i64, index) * 1000;
    }

    var block: CompressedBlock = undefined;
    encode_block(&timestamps, &test_values, &block);

    const count_u32: u32 = @intCast(test_values.len);
    try testing.expectEqual(count_u32, block.count);

    var ts_out: [test_values.len]i64 = undefined;
    var val_out: [test_values.len]f64 = undefined;
    const count = decode_block(&block, &ts_out, &val_out);

    try testing.expectEqual(count_u32, count);
    index = 0;
    while (index < test_values.len) : (index += 1) {
        // Bit-exact comparison for special values.
        const expected_bits: u64 = @bitCast(test_values[index]);
        const actual_bits: u64 = @bitCast(val_out[index]);
        try testing.expectEqual(expected_bits, actual_bits);
    }
}

test "encode_decode_special_floats" {
    const test_values = [_]f64{
        std.math.nan(f64),
        std.math.inf(f64),
        -std.math.inf(f64),
        -0.0,
        @as(f64, @bitCast(@as(u64, 1))),
    };
    var timestamps: [test_values.len]i64 = undefined;
    var index: u32 = 0;
    while (index < test_values.len) : (index += 1) {
        timestamps[index] = @as(i64, index);
    }

    var block: CompressedBlock = undefined;
    encode_block(&timestamps, &test_values, &block);

    try testing.expectEqual(
        @as(u32, test_values.len),
        block.count,
    );

    var ts_out: [test_values.len]i64 = undefined;
    var val_out: [test_values.len]f64 = undefined;
    const count = decode_block(&block, &ts_out, &val_out);

    try testing.expectEqual(
        @as(u32, test_values.len),
        count,
    );
    index = 0;
    while (index < test_values.len) : (index += 1) {
        const expected_bits: u64 = @bitCast(test_values[index]);
        const actual_bits: u64 = @bitCast(val_out[index]);
        try testing.expectEqual(expected_bits, actual_bits);
    }
}

test "encode_decode_block_size_max" {
    var timestamps: [block_size_max]i64 = undefined;
    var values: [block_size_max]f64 = undefined;
    var index: u32 = 0;
    while (index < block_size_max) : (index += 1) {
        timestamps[index] = @as(i64, index) * 1000;
        values[index] = @as(
            f64,
            @floatFromInt(index),
        ) * 0.001;
    }

    var block: CompressedBlock = undefined;
    encode_block(&timestamps, &values, &block);

    try testing.expectEqual(block_size_max, block.count);
    try testing.expectEqual(@as(i64, 0), block.first_timestamp);
    try testing.expectEqual(
        @as(i64, (@as(i64, block_size_max) - 1) * 1000),
        block.last_timestamp,
    );

    var ts_out: [block_size_max]i64 = undefined;
    var val_out: [block_size_max]f64 = undefined;
    const count = decode_block(&block, &ts_out, &val_out);

    try testing.expectEqual(block_size_max, count);
    // Spot-check first, last, and a middle point.
    try testing.expectEqual(@as(i64, 0), ts_out[0]);
    try testing.expectEqual(
        @as(i64, 512000),
        ts_out[512],
    );
    try testing.expectEqual(
        timestamps[block_size_max - 1],
        ts_out[block_size_max - 1],
    );
    try testing.expectApproxEqAbs(
        @as(f64, 0.0),
        val_out[0],
        1e-15,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 0.512),
        val_out[512],
        1e-15,
    );
}

test "zigzag_encode_decode_roundtrip" {
    const test_cases = [_]i64{
        0,    1,      -1,     2,        -2,
        127,  -128,   255,    -256,     1000,
        -1000, std.math.maxInt(i64),
        std.math.minInt(i64) + 1,
    };

    var index: u32 = 0;
    while (index < test_cases.len) : (index += 1) {
        const original = test_cases[index];
        const encoded = zigzag_encode(original);
        const decoded = zigzag_decode(encoded);
        try testing.expectEqual(original, decoded);

        // Negative space: encoded value of n differs from n+1.
        if (original < std.math.maxInt(i64)) {
            const other = zigzag_encode(original + 1);
            try testing.expect(encoded != other);
        }
    }

    // ZigZag(0) == 0.
    try testing.expectEqual(@as(u64, 0), zigzag_encode(0));
    // ZigZag(-1) == 1.
    try testing.expectEqual(@as(u64, 1), zigzag_encode(-1));
    // ZigZag(1) == 2.
    try testing.expectEqual(@as(u64, 2), zigzag_encode(1));
}

test "decode_timestamps_only" {
    const timestamps = [_]i64{ 10, 20, 35, 60, 100 };
    const values = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    var block: CompressedBlock = undefined;

    encode_block(&timestamps, &values, &block);

    try testing.expectEqual(@as(u32, 5), block.count);

    // Decode only timestamps, without touching values.
    var ts_out: [5]i64 = undefined;
    const count = decode_timestamps(&block, &ts_out);

    try testing.expectEqual(@as(u32, 5), count);
    var index: u32 = 0;
    while (index < 5) : (index += 1) {
        try testing.expectEqual(timestamps[index], ts_out[index]);
    }

    // Negative: buffer large enough for count but no more.
    var ts_large: [10]i64 = [_]i64{-999} ** 10;
    const count2 = decode_timestamps(&block, &ts_large);
    try testing.expectEqual(@as(u32, 5), count2);
    // Elements beyond count are untouched.
    try testing.expectEqual(@as(i64, -999), ts_large[5]);
}

test "compression_ratio_constant_delta" {
    // Constant-delta timestamps should compress to roughly
    // 16 bytes (t0 + d0) plus 1 byte per subsequent point
    // (ZigZag(0) == varint(0) == 1 byte).
    var timestamps: [100]i64 = undefined;
    var values: [100]f64 = undefined;
    var index: u32 = 0;
    while (index < 100) : (index += 1) {
        timestamps[index] = @as(i64, index) * 10;
        values[index] = 42.0;
    }

    var block: CompressedBlock = undefined;
    encode_block(&timestamps, &values, &block);

    // Raw size: 100 * 8 = 800 bytes.
    const raw_ts_size: u32 = 100 * 8;
    try testing.expect(block.timestamp_len < raw_ts_size);
    // Constant delta: 16 header + 98 * 1-byte varints = 114.
    try testing.expect(block.timestamp_len <= 116);

    // Identical values: 8 + 99 * 1 = 107 bytes.
    const raw_val_size: u32 = 100 * 8;
    try testing.expect(block.value_len < raw_val_size);
    try testing.expect(block.value_len <= 108);

    // Verify the data still round-trips.
    var ts_out: [100]i64 = undefined;
    var val_out: [100]f64 = undefined;
    const count = decode_block(&block, &ts_out, &val_out);
    try testing.expectEqual(@as(u32, 100), count);
}
