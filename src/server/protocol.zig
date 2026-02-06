//! Binary wire protocol for Tau.
//!
//! Frame layout (10 bytes fixed header):
//!
//!   [3 bytes] magic: "TAU"
//!   [1 byte]  version
//!   [1 byte]  opcode
//!   [1 byte]  flags (reserved)
//!   [4 bytes] payload_length (big-endian, u32)
//!   [N bytes] payload
//!
//! Clients must send CONNECT as the first message. The server
//! will reject any other opcode on an unauthenticated connection.

const std = @import("std");

pub const magic = [3]u8{ 'T', 'A', 'U' };
pub const version: u8 = 1;
pub const header_length: u32 = 10;
pub const payload_length_max: u32 = 4 * 1024 * 1024;

pub const Opcode = enum(u8) {
    // Connection lifecycle.
    connect = 0x01,
    disconnect = 0x02,
    ping = 0x03,
    pong = 0x04,

    // Series management.
    create_series = 0x10,
    drop_series = 0x11,

    // Write path.
    append = 0x20,

    // Read path.
    query_point = 0x30,

    // Lens management.
    create_lens = 0x40,
    drop_lens = 0x41,
    query_lens = 0x42,
    compose_lens = 0x43,
    list_lenses = 0x44,

    // Responses.
    ok = 0xF0,
    err = 0xFF,
};

pub const StatusCode = enum(u8) {
    success = 0x00,
    bad_magic = 0x01,
    bad_version = 0x02,
    bad_opcode = 0x03,
    payload_too_large = 0x04,
    not_authenticated = 0x05,
    auth_failed = 0x06,
    series_not_found = 0x07,
    series_already_exists = 0x08,
    invalid_payload = 0x09,
    internal_error = 0x0A,
    out_of_order = 0x0B,
    lens_not_found = 0x0C,
    lens_already_exists = 0x0D,
};

pub const Header = struct {
    opcode: Opcode,
    flags: u8,
    payload_length: u32,

    pub fn encode(self: Header, buffer: *[header_length]u8) void {
        buffer[0] = magic[0];
        buffer[1] = magic[1];
        buffer[2] = magic[2];
        buffer[3] = version;
        buffer[4] = @intFromEnum(self.opcode);
        buffer[5] = self.flags;
        std.mem.writeInt(
            u32,
            buffer[6..10],
            self.payload_length,
            .big,
        );
    }

    pub fn decode(
        buffer: *const [header_length]u8,
    ) DecodeError!Header {
        if (buffer[0] != magic[0] or
            buffer[1] != magic[1] or
            buffer[2] != magic[2])
        {
            return error.BadMagic;
        }

        if (buffer[3] != version) {
            return error.BadVersion;
        }

        const opcode_byte = buffer[4];
        const opcode = std.meta.intToEnum(
            Opcode,
            opcode_byte,
        ) catch {
            return error.BadOpcode;
        };

        const payload_length = std.mem.readInt(
            u32,
            buffer[6..10],
            .big,
        );
        if (payload_length > payload_length_max) {
            return error.PayloadTooLarge;
        }

        return Header{
            .opcode = opcode,
            .flags = buffer[5],
            .payload_length = payload_length,
        };
    }

    pub const DecodeError = error{
        BadMagic,
        BadVersion,
        BadOpcode,
        PayloadTooLarge,
    };
};

const testing = std.testing;

test "Header round-trips through encode/decode" {
    const original = Header{
        .opcode = .append,
        .flags = 0,
        .payload_length = 256,
    };
    var buffer: [header_length]u8 = undefined;
    original.encode(&buffer);

    const decoded = try Header.decode(&buffer);
    try testing.expectEqual(original.opcode, decoded.opcode);
    try testing.expectEqual(original.flags, decoded.flags);
    try testing.expectEqual(
        original.payload_length,
        decoded.payload_length,
    );
}

test "Header.decode rejects bad magic" {
    var buffer = [_]u8{0} ** header_length;
    buffer[0] = 'X';
    try testing.expectError(error.BadMagic, Header.decode(&buffer));
}

test "Header.decode rejects bad version" {
    var buffer: [header_length]u8 = undefined;
    const header = Header{
        .opcode = .ping,
        .flags = 0,
        .payload_length = 0,
    };
    header.encode(&buffer);
    buffer[3] = 99;
    try testing.expectError(
        error.BadVersion,
        Header.decode(&buffer),
    );
}

test "Header.decode rejects oversized payload" {
    var buffer: [header_length]u8 = undefined;
    const header = Header{
        .opcode = .ping,
        .flags = 0,
        .payload_length = payload_length_max + 1,
    };
    header.encode(&buffer);
    try testing.expectError(
        error.PayloadTooLarge,
        Header.decode(&buffer),
    );
}

test "Header.decode rejects unknown opcode" {
    var buffer: [header_length]u8 = undefined;
    const header = Header{
        .opcode = .ping,
        .flags = 0,
        .payload_length = 0,
    };
    header.encode(&buffer);
    buffer[4] = 0xBB;
    try testing.expectError(
        error.BadOpcode,
        Header.decode(&buffer),
    );
}

test "All opcodes encode to distinct bytes" {
    const fields = @typeInfo(Opcode).@"enum".fields;
    var seen = [_]bool{false} ** 256;
    inline for (fields) |field| {
        try testing.expect(!seen[field.value]);
        seen[field.value] = true;
    }
}
