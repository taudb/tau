//! This is the database server (single-node)

const std = @import("std");
const assert = std.debug.assert;
const net = std.net;
const libtau = @import("libtau");
const primitives = libtau.primitives;
const InMemory = libtau.storage.backends.InMemory;
const Backend = libtau.storage.backends.Backend;
const BackendType = libtau.storage.backends.BackendType;
const Engine = libtau.storage.Engine;
const EngineCommand = libtau.storage.EngineCommand;

fn masthead(version: []const u8) void {
    std.debug.print("  █████                        \n", .{});
    std.debug.print(" ░░███                         \n", .{});
    std.debug.print(" ███████    ██████   █████ ████\n", .{});
    std.debug.print("░░░███░    ░░░░░███ ░░███ ░███ \n", .{});
    std.debug.print("  ░███      ███████  ░███ ░███ \n", .{});
    std.debug.print("  ░███ ███ ███░░███  ░███ ░███ \n", .{});
    std.debug.print("  ░░█████ ░░████████ ░░████████\n", .{});
    std.debug.print("   ░░░░░   ░░░░░░░░   ░░░░░░░░ \n", .{});
    std.debug.print("\nServer v{s} running...\n", .{version});
}

pub fn main() !void {
    masthead("0.1.0");

    const address = try net.Address.parseIp("127.0.0.1", 8080);
    var server = try address.listen(.{
        .reuse_address = true,
        .kernel_backlog = 128, // backlog: number of pending connections queue
    });
    defer server.deinit();

    std.debug.print("Server listening on {d}\n", .{address.getPort()});

    while (true) {
        const connection = try server.accept();
        defer connection.stream.close();

        std.debug.print("Accepted connection, port {d}\n", .{connection.address.getPort()});

        handleClient(connection.stream) catch |err| {
            std.debug.print("Error handling client: {any}\n", .{err}); // Changed {} to {any}
        };
    }
}

fn handleClient(stream: net.Stream) !void {
    var buffer: [1024]u8 = undefined;

    const bytes_read = try stream.read(&buffer);
    if (bytes_read == 0) {
        std.debug.print("Client disconnected\n", .{});
        return;
    }

    const received = buffer[0..bytes_read];
    std.debug.print("Received {d} bytes: {s}\n", .{ bytes_read, received }); // Changed {} to {d}

    // Echo the data back
    _ = try stream.writeAll(received);
}
