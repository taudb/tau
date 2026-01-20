//! This is the database server (single-node)

const std = @import("std");
const assert = std.debug.assert;
const libtau = @import("libtau");
const primitives = libtau.primitives;

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
    std.debug.print("Running sanity check...\n", .{});

    var tmp_dir = blk: {
        if (std.fs.cwd().openDir("tmpdata", .{})) |dir| {
            break :blk dir;
        } else |_| {
            std.debug.print("Creating tmpdata directory...\n", .{});
            try std.fs.cwd().makeDir("tmpdata");
            break :blk try std.fs.cwd().openDir("tmpdata", .{});
        }
    };
    defer tmp_dir.close();

    var tau = try primitives.Tau.create(allocator, "+1.5", 1000, 2000);
    defer (&tau).deinit(allocator);

    var taus = [_]primitives.Tau{tau};
    var schedule = try primitives.Schedule.create(allocator, "Test Schedule", taus[0..]);
    defer (&schedule).deinit(allocator);

    var schedules = [_]primitives.Schedule{schedule};
    var frame = try primitives.Frame.create(allocator, schedules[0..]);
    defer (&frame).deinit(allocator);

    const tau_file = try tmp_dir.createFile("sanity_tau.bin", .{});
    defer tau_file.close();
    const tau_serialized = try tau.serialize(allocator);
    defer allocator.free(tau_serialized);
    try tau_file.writeAll(tau_serialized);
    const tau_path = try tmp_dir.realpathAlloc(allocator, "sanity_tau.bin");
    defer allocator.free(tau_path);
    std.debug.print("Serialized tau to {s}\n", .{tau_path});

    const schedule_file = try tmp_dir.createFile("sanity_schedule.bin", .{});
    defer schedule_file.close();
    const schedule_serialized = try schedule.serialize(allocator);
    defer allocator.free(schedule_serialized);
    try schedule_file.writeAll(schedule_serialized);
    const schedule_path = try tmp_dir.realpathAlloc(allocator, "sanity_schedule.bin");
    defer allocator.free(schedule_path);
    std.debug.print("Serialized schedule to {s}\n", .{schedule_path});

    const frame_file = try tmp_dir.createFile("sanity_frame.bin", .{});
    defer frame_file.close();
    const frame_serialized = try frame.serialize(allocator);
    defer allocator.free(frame_serialized);
    try frame_file.writeAll(frame_serialized);
    const frame_path = try tmp_dir.realpathAlloc(allocator, "sanity_frame.bin");
    defer allocator.free(frame_path);
    std.debug.print("Serialized frame to {s}\n", .{frame_path});

    std.debug.print("Deserializing from disk...\n", .{});

    const tau_data = try tmp_dir.readFileAlloc(allocator, "sanity_tau.bin", 4096);
    defer allocator.free(tau_data);
    var deserialized_tau: primitives.Tau = undefined;
    try deserialized_tau.deserialize(allocator, tau_data);
    defer (&deserialized_tau).deinit(allocator);

    assert(tau.valid_ns == deserialized_tau.valid_ns);
    assert(tau.expiry_ns == deserialized_tau.expiry_ns);
    assert(std.mem.eql(u8, tau.diff, deserialized_tau.diff));
    std.debug.print("Tau characteristics verified\n", .{});

    const schedule_data = try tmp_dir.readFileAlloc(allocator, "sanity_schedule.bin", 8192);
    defer allocator.free(schedule_data);
    var deserialized_schedule: primitives.Schedule = undefined;
    try deserialized_schedule.deserialize(allocator, schedule_data);
    defer (&deserialized_schedule).deinit(allocator);

    assert(schedule.taus.len == deserialized_schedule.taus.len);
    assert(std.mem.eql(u8, schedule.name, deserialized_schedule.name));
    assert(schedule.taus[0].valid_ns == deserialized_schedule.taus[0].valid_ns);
    assert(schedule.taus[0].expiry_ns == deserialized_schedule.taus[0].expiry_ns);
    assert(std.mem.eql(u8, schedule.taus[0].diff, deserialized_schedule.taus[0].diff));
    std.debug.print("Schedule characteristics verified\n", .{});

    const frame_data = try tmp_dir.readFileAlloc(allocator, "sanity_frame.bin", 16384);
    defer allocator.free(frame_data);
    var deserialized_frame: primitives.Frame = undefined;
    try deserialized_frame.deserialize(allocator, frame_data);
    defer (&deserialized_frame).deinit(allocator);

    assert(frame.schedules.len == deserialized_frame.schedules.len);
    assert(frame.schedules[0].taus.len == deserialized_frame.schedules[0].taus.len);
    assert(std.mem.eql(u8, frame.schedules[0].name, deserialized_frame.schedules[0].name));
    assert(frame.schedules[0].taus[0].valid_ns == deserialized_frame.schedules[0].taus[0].valid_ns);
    assert(frame.schedules[0].taus[0].expiry_ns == deserialized_frame.schedules[0].taus[0].expiry_ns);
    assert(std.mem.eql(u8, frame.schedules[0].taus[0].diff, deserialized_frame.schedules[0].taus[0].diff));
    std.debug.print("Frame characteristics verified\n", .{});

    std.debug.print("Sanity check complete\n", .{});
}

pub fn main() !void {
    masthead("0.1.0");

    const allocator = std.heap.page_allocator;
    try sanity(allocator);

    std.debug.print("\nShutting down gracefully...\n", .{});
}
