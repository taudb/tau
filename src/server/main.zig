//! This is the database server (single-node)

const std = @import("std");
const assert = std.debug.assert;
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

fn sanity(allocator: std.mem.Allocator) !void {
    std.debug.print("Running sanity check using in-memory backend...\n", .{});

    // 1. Create example data (Tau, Schedule, Frame)
    var tau = try primitives.Tau.create(allocator, "+1.5", 1000, 2000);
    defer (&tau).deinit(allocator);
    var taus = [_]primitives.Tau{tau};
    var schedule = try primitives.Schedule.create(allocator, "Test Schedule", taus[0..]);
    defer (&schedule).deinit(allocator);
    var schedules = [_]primitives.Schedule{schedule};
    var frame = try primitives.Frame.create(allocator, schedules[0..]);
    defer (&frame).deinit(allocator);

    // 2. Initialize in-memory backend and engine
    var memory_backend = InMemory.init();
    defer memory_backend.deinit(allocator);
    var backend = Backend{
        .backend_type = BackendType.InMemory,
        .backend = .{ .InMemory = memory_backend },
    };
    var engine = Engine.init(allocator, &backend);
    defer engine.deinit();

    // 3. Serialize Frame, store with engine
    const frame_serialized = try frame.serialize(allocator);
    defer allocator.free(frame_serialized);
    _ = try engine.execute(EngineCommand.Put, frame_serialized);
    std.debug.print("Frame serialized and stored in engine.\n", .{});

    // 4. Read back & verify roundtrip correctness
    const maybe_bytes = try engine.execute(EngineCommand.Get, &[_]u8{});
    if (maybe_bytes) |bytes| {
        var roundtrip_frame: primitives.Frame = undefined;
        try roundtrip_frame.deserialize(allocator, bytes);
        defer (&roundtrip_frame).deinit(allocator);
        assert(frame.schedules.len == roundtrip_frame.schedules.len);
        assert(frame.schedules[0].taus.len == roundtrip_frame.schedules[0].taus.len);
        assert(std.mem.eql(u8, frame.schedules[0].name, roundtrip_frame.schedules[0].name));
        assert(frame.schedules[0].taus[0].valid_ns == roundtrip_frame.schedules[0].taus[0].valid_ns);
        assert(frame.schedules[0].taus[0].expiry_ns == roundtrip_frame.schedules[0].taus[0].expiry_ns);
        assert(std.mem.eql(u8, frame.schedules[0].taus[0].diff, roundtrip_frame.schedules[0].taus[0].diff));
        std.debug.print("Frame characteristics verified via in-memory roundtrip.\n", .{});
    } else {
        std.debug.print("Error: No data read back from engine.\n", .{});
        return error.NoDataReadBack;
    }

    std.debug.print("Sanity check complete.\n", .{});
}

pub fn main() !void {
    masthead("0.1.0");

    const allocator = std.heap.page_allocator;
    try sanity(allocator);

    std.debug.print("\nShutting down gracefully...\n", .{});
}
