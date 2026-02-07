//! Tau database server entry point.
//!
//! Requires TAU_CERTIFICATE environment variable set to a
//! 64-character hex string (32 bytes). Clients must present
//! the same certificate on CONNECT.

const std = @import("std");
const listener_mod = @import("listener.zig");
const auth_mod = @import("auth.zig");

const log = std.log.scoped(.server);

const default_port: u16 = 7701;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const certificate = read_certificate() orelse {
        log.err(
            "TAU_CERTIFICATE env var must be set " ++
                "(64 hex chars, 32 bytes)",
            .{},
        );
        return error.MissingCertificate;
    };

    var server = listener_mod.Listener.init(
        allocator,
        .{
            .port = default_port,
            .address = .{ 127, 0, 0, 1 },
            .certificate = certificate,
        },
    );
    defer server.deinit();

    try server.start();
}

fn read_certificate() ?[auth_mod.certificate_length]u8 {
    const hex = std.posix.getenv("TAU_CERTIFICATE") orelse
        return null;

    if (hex.len != auth_mod.certificate_length * 2) {
        return null;
    }

    var certificate: [auth_mod.certificate_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&certificate, hex) catch
        return null;
    return certificate;
}
