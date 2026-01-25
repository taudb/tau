//! This is the database server (single-node)

const std = @import("std");
const assert = std.debug.assert;
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
const BUFFER_SIZE_BYTES = 1024;

// Global thread pool for cleanup
var thread_pool: [MAX_THREADS]?Thread = undefined;
var thread_pool_initialized = false;

fn masthead(version: []const u8) void {
    // Preconditions
    assert(version.len > 0);

    std.debug.print("\n  █████                        \n", .{});
    std.debug.print(" ░░███                         \n", .{});
    std.debug.print(" ███████    ██████   █████ ████\n", .{});
    std.debug.print("░░░███░    ░░░░░███ ░░███ ░███ \n", .{});
    std.debug.print("  ░███      ███████  ░███ ░███ \n", .{});
    std.debug.print("  ░███ ███ ███░░███  ░███ ░███ \n", .{});
    std.debug.print("  ░░█████ ░░████████ ░░████████\n", .{});
    std.debug.print("   ░░░░░   ░░░░░░░░   ░░░░░░░ \n", .{});
    std.debug.print("\nServer v{s} running...\n", .{version});
}

pub fn main() !void {
    // Preconditions
    assert(MAX_THREADS > 0);
    assert(BUFFER_SIZE_BYTES > 0);
    assert(BUFFER_SIZE_BYTES <= 65536); // Reasonable buffer size limit

    masthead("0.1.0");

    // Initialize thread pool
    if (!thread_pool_initialized) {
        @memset(&thread_pool, null);
        thread_pool_initialized = true;
    }

    // Use arena allocator for better memory management
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const address = try net.Address.parseIp("127.0.0.1", 8080);
    var server = try address.listen(.{
        .reuse_address = true,
        .kernel_backlog = 128, // backlog: number of pending connections queue
    });
    defer server.deinit();

    std.debug.print("Server listening on {d}\n", .{address.getPort()});

    // Thread management with proper synchronization
    var thread_mutex = std.Thread.Mutex{};
    var active_threads: u32 = 0;

    while (true) {
        const connection = try server.accept();
        std.debug.print("Accepted connection, port {d}\n", .{connection.address.getPort()});

        thread_mutex.lock();
        defer thread_mutex.unlock();

        // Find available thread slot with bounds checking
        var thread_found = false;
        for (0..MAX_THREADS) |i| {
            if (thread_pool[i] == null) {
                // Allocate connection copy on arena for automatic cleanup
                const conn_copy = try allocator.create(net.Server.Connection);
                conn_copy.* = connection;
                active_threads += 1;

                const thread_handle = try Thread.spawn(.{}, handleClientThread, .{ conn_copy, allocator, &thread_mutex, &active_threads, i });
                thread_pool[i] = thread_handle;
                thread_found = true;

                std.debug.print("Spawned thread {} for client port {d}\n", .{ i, connection.address.getPort() });
                break;
            }
        }

        if (!thread_found) {
            std.debug.print("Thread pool full ({} active), handling client in main thread\n", .{active_threads});
            handleClient(connection.stream, allocator) catch |err| {
                std.debug.print("Error handling client: {any}\n", .{err});
            };
            connection.stream.close();
        }

        // Postcondition check
        assert(active_threads <= MAX_THREADS);
    }
}

fn handleClientThread(connection: *net.Server.Connection, allocator: std.mem.Allocator, thread_mutex: *std.Thread.Mutex, active_threads: *u32, thread_index: usize) void {
    // Preconditions
    assert(active_threads.* > 0);
    assert(thread_index < MAX_THREADS);

    defer {
        connection.stream.close();

        // Clean up thread slot and decrement counter
        thread_mutex.lock();
        defer thread_mutex.unlock();

        thread_pool[thread_index] = null;
        active_threads.* -= 1;

        std.debug.print("Thread {} slot cleaned up, {} threads remaining\n", .{ thread_index, active_threads.* });

        // Postcondition
        assert(active_threads.* <= MAX_THREADS);
    }

    const port = connection.address.getPort();
    const thread_id = Thread.getCurrentId();
    std.debug.print("Thread {} handling client port {d}\n", .{ thread_id, port });

    handleClient(connection.stream, allocator) catch |err| {
        std.debug.print("Error handling client in thread {}: {any}\n", .{ thread_id, err });
    };

    std.debug.print("Thread {} finished handling client port {d}\n", .{ thread_id, port });
}

fn handleClient(stream: net.Stream, allocator: std.mem.Allocator) !void {
    // Preconditions
    assert(BUFFER_SIZE_BYTES > 0);
    _ = allocator; // Mark as used for future API compatibility

    var buffer: [BUFFER_SIZE_BYTES]u8 = undefined;
    var request_count: u32 = 0;

    while (true) {
        const bytes_read = try stream.read(&buffer);
        if (bytes_read == 0) {
            std.debug.print("Client disconnected after {} requests\n", .{request_count});
            return;
        }

        // Bounds checking
        assert(bytes_read <= BUFFER_SIZE_BYTES);
        request_count += 1;
        assert(request_count > 0); // Check for overflow

        const received = buffer[0..bytes_read];
        std.debug.print("Received {} bytes: {s}\n", .{ bytes_read, received });

        // Echo response
        try stream.writeAll("received.\n");
    }
}
