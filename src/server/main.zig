//! Tau database server entry point.
//!
//! Configuration is in src/config.zig - edit and recompile to change settings.

const std = @import("std");
const assert = std.debug.assert;

const tau = @import("tau");
const config = tau.config;

const listener_mod = @import("listener.zig");
const auth_mod = @import("auth.zig");

const log = std.log.scoped(.server);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get certificate from config.
    const certificate = config.server.certificate;

    // Validate certificate is not default.
    const default_cert = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    };

    if (std.mem.eql(u8, &certificate, &default_cert)) {
        log.warn("using default certificate - change in config.zig for production", .{});
    }

    log.info("starting server on {d}.{d}.{d}.{d}:{d}", .{
        config.server.address[0],
        config.server.address[1],
        config.server.address[2],
        config.server.address[3],
        config.server.port,
    });

    var server = listener_mod.Listener.init(
        allocator,
        .{
            .port = config.server.port,
            .address = config.server.address,
            .certificate = certificate,
        },
    );
    defer server.deinit();

    try server.start();
}
