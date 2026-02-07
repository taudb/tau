//! Server benchmark scenarios: protocol and auth operations.

const std = @import("std");
const tau = @import("tau");
const harness = @import("harness.zig");

const iteration_count: u64 = 100;

const header_length: u32 = 10;
const protocol_magic = [3]u8{ 'T', 'A', 'U' };
const protocol_version: u8 = 1;

const Opcode = enum(u8) {
    connect = 0x01,
    disconnect = 0x02,
    ping = 0x03,
    pong = 0x04,
    create_series = 0x10,
    drop_series = 0x11,
    append = 0x20,
    query_point = 0x30,
    ok = 0xF0,
    err = 0xFF,
};

fn encode_header(buffer: *[header_length]u8, opcode: Opcode, payload_length: u32) void {
    buffer[0] = protocol_magic[0];
    buffer[1] = protocol_magic[1];
    buffer[2] = protocol_magic[2];
    buffer[3] = protocol_version;
    buffer[4] = @intFromEnum(opcode);
    buffer[5] = 0;
    std.mem.writeInt(u32, buffer[6..10], payload_length, .big);
}

fn decode_header(buffer: *const [header_length]u8) bool {
    if (buffer[0] != protocol_magic[0] or
        buffer[1] != protocol_magic[1] or
        buffer[2] != protocol_magic[2])
    {
        return false;
    }
    if (buffer[3] != protocol_version) return false;
    _ = std.meta.intToEnum(Opcode, buffer[4]) catch return false;
    const payload_length = std.mem.readInt(u32, buffer[6..10], .big);
    _ = payload_length;
    return true;
}

fn protocol_roundtrip(_: std.mem.Allocator) !void {
    var buffer: [header_length]u8 = undefined;
    var checksum: u64 = 0;

    const opcodes = [_]Opcode{
        .connect,     .disconnect,
        .ping,        .pong,
        .create_series, .drop_series,
        .append,      .query_point,
        .ok,          .err,
    };

    var round: u32 = 0;
    while (round < 10_000) : (round += 1) {
        for (opcodes) |opcode| {
            encode_header(&buffer, opcode, round * 100);
            if (decode_header(&buffer)) {
                checksum +%= buffer[4];
            }
        }
    }
    std.mem.doNotOptimizeAway(checksum);
}

const certificate_length: u32 = 32;

fn constant_time_equal(
    a: *const [certificate_length]u8,
    b: *const [certificate_length]u8,
) bool {
    var diff: u8 = 0;
    for (a, b) |byte_a, byte_b| {
        diff |= byte_a ^ byte_b;
    }
    return diff == 0;
}

fn auth_verify(_: std.mem.Allocator) !void {
    const cert_a = [_]u8{0xAB} ** certificate_length;
    var checksum: u64 = 0;

    var iteration: u32 = 0;
    while (iteration < 100_000) : (iteration += 1) {
        var cert_b: [certificate_length]u8 = undefined;
        @memset(&cert_b, @as(u8, @truncate(iteration)));
        if (constant_time_equal(&cert_a, &cert_b)) {
            checksum += 1;
        }
    }
    std.mem.doNotOptimizeAway(checksum);
}

pub const scenarios = [_]harness.Scenario{
    .{
        .name = "server/protocol_roundtrip",
        .iterations = iteration_count,
        .run_fn = protocol_roundtrip,
    },
    .{
        .name = "server/auth_verify",
        .iterations = iteration_count,
        .run_fn = auth_verify,
    },
};
