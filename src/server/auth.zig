//! Connection authentication via pre-shared certificate.
//!
//! On CONNECT, the client sends a 32-byte certificate token in
//! the payload. The server compares it against the configured
//! certificate using constant-time equality to prevent timing
//! attacks.
//!
//! This module manages session state per connection: a session
//! is created on successful CONNECT and destroyed on DISCONNECT
//! or connection drop.

const std = @import("std");

pub const certificate_length: u32 = 32;

pub const Session = struct {
    authenticated: bool,
    address: std.net.Address,

    const Self = @This();

    pub fn init(address: std.net.Address) Self {
        return .{
            .authenticated = false,
            .address = address,
        };
    }

    pub fn authenticate(
        self: *Self,
        client_cert: *const [certificate_length]u8,
        server_cert: *const [certificate_length]u8,
    ) AuthError!void {
        std.debug.assert(!self.authenticated);

        if (!constant_time_equal(client_cert, server_cert)) {
            return error.AuthFailed;
        }

        self.authenticated = true;
    }

    pub fn disconnect(self: *Self) void {
        self.authenticated = false;
    }

    pub const AuthError = error{AuthFailed};
};

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

const testing = std.testing;

fn make_test_address() std.net.Address {
    return std.net.Address.initIp4(
        .{ 127, 0, 0, 1 },
        9000,
    );
}

test "Session starts unauthenticated" {
    const session = Session.init(make_test_address());
    try testing.expect(!session.authenticated);
}

test "Session authenticates with matching certificate" {
    var session = Session.init(make_test_address());
    const cert = [_]u8{0xAB} ** certificate_length;
    try session.authenticate(&cert, &cert);
    try testing.expect(session.authenticated);
}

test "Session rejects mismatched certificate" {
    var session = Session.init(make_test_address());
    const client_cert = [_]u8{0xAB} ** certificate_length;
    const server_cert = [_]u8{0xCD} ** certificate_length;
    try testing.expectError(
        error.AuthFailed,
        session.authenticate(&client_cert, &server_cert),
    );
    try testing.expect(!session.authenticated);
}

test "Session disconnect clears authentication" {
    var session = Session.init(make_test_address());
    const cert = [_]u8{0xAB} ** certificate_length;
    try session.authenticate(&cert, &cert);
    try testing.expect(session.authenticated);
    session.disconnect();
    try testing.expect(!session.authenticated);
}

test "constant_time_equal returns true for equal buffers" {
    const a = [_]u8{0x42} ** certificate_length;
    const b = [_]u8{0x42} ** certificate_length;
    try testing.expect(constant_time_equal(&a, &b));
}

test "constant_time_equal returns false for different buffers" {
    const a = [_]u8{0x42} ** certificate_length;
    var b = [_]u8{0x42} ** certificate_length;
    b[15] = 0x00;
    try testing.expect(!constant_time_equal(&a, &b));
}
