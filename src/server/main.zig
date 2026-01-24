//! This is the database server (single-node)

const std = @import("std");
const net = std.net;
const Thread = std.Thread;
const libtau = @import("libtau");
const primitives = libtau.primitives;
const InMemory = libtau.storage.backends.InMemory;
const Backend = libtau.storage.backends.Backend;
const BackendType = libtau.storage.backends.BackendType;
const Engine = libtau.storage.Engine;
const EngineCommand = libtau.storage.EngineCommand;

const MAX_THREADS = 8;

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

    const gpa = std.heap.page_allocator;

    const address = try net.Address.parseIp("127.0.0.1", 8080);
    var server = try address.listen(.{
        .reuse_address = true,
        .kernel_backlog = 128, // backlog: number of pending connections queue
    });
    defer server.deinit();

    std.debug.print("Server listening on {d}\n", .{address.getPort()});

    // Thread management
    var thread_pool: [MAX_THREADS]?Thread = undefined;
    @memset(&thread_pool, null);
    var thread_mutex = std.Thread.Mutex{};

    while (true) {
        const connection = try server.accept();
        std.debug.print("Accepted connection, port {d}\n", .{connection.address.getPort()});

        thread_mutex.lock();
        defer thread_mutex.unlock();

        // Find available thread slot
        var thread_found = false;
        for (0..MAX_THREADS) |i| {
            if (thread_pool[i] == null) {
                // Create a copy of the connection for the thread
                const conn_copy = try gpa.create(net.Server.Connection);
                conn_copy.* = connection;

                thread_pool[i] = try Thread.spawn(.{}, handleClientThread, .{conn_copy});
                thread_found = true;

                std.debug.print("Spawned thread {} for client port {d}\n", .{ i, connection.address.getPort() });
                break;
            }
        }

        if (!thread_found) {
            std.debug.print("Thread pool full, handling client in main thread\n", .{});
            handleClient(connection.stream) catch |err| {
                std.debug.print("Error handling client: {any}\n", .{err});
            };
        }
    }
}

fn handleClientThread(connection: *net.Server.Connection) void {
    defer {
        connection.stream.close();
        std.heap.page_allocator.destroy(connection);
    }

    const port = connection.address.getPort();
    const thread_id = Thread.getCurrentId();
    std.debug.print("Thread {} handling client port {d}\n", .{ thread_id, port });

    handleClient(connection.stream) catch |err| {
        std.debug.print("Error handling client in thread {}: {any}\n", .{ thread_id, err });
    };

    std.debug.print("Thread {} finished handling client port {d}\n", .{ thread_id, port });
}

fn handleClient(stream: net.Stream) !void {
    var buffer: [1024]u8 = undefined;

    while (true) {
        const bytes_read = try stream.read(&buffer);
        if (bytes_read == 0) {
            std.debug.print("Client disconnected\n", .{});
            return;
        }

        const received = buffer[0..bytes_read];
        std.debug.print("Received {d} bytes: {s}\n", .{ bytes_read, received });

        // Echo the data back
        _ = try stream.writeAll(received);
    }
}
