//! Query executor (command->storage engine)

const std = @import("std");
const command = @import("../commands/mod.zig");
const storage_mod = @import("../storage/mod.zig");
const primitives = @import("../primitives/mod.zig");
const Engine = storage_mod.Engine;
const EngineCommand = storage_mod.EngineCommand;
const Schedule = primitives.Schedule;
const Tau = primitives.Tau;

pub const ExecutorError = error{
    NonExistent,
    StorageError,
    ParseError,
    InvalidSchedule,
    OutOfMemory,
    NoSpaceLeft,
    BackendNotInitialized,
    EndOfStream,
    InvalidCharacter,
};

fn makeScheduleKey(name: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "schedule:{s}", .{name});
}

fn parseFloat(text: []const u8) !f64 {
    return std.fmt.parseFloat(f64, text);
}

pub fn executeCommand(cmd: command.Command, engine: *Engine, allocator: std.mem.Allocator) ExecutorError!?[]u8 {
    return switch (cmd) {
        .CreateSchedule => |create_cmd| {
            // Create initial tau with diff=0 (placeholder)
            const now_ns = std.time.nanoTimestamp();
            const valid_ns = @as(u64, @intCast(now_ns));
            const expiry_ns = valid_ns + std.time.ns_per_hour; // 1 hour validity

            var initial_tau = try Tau.create(allocator, 0.0, valid_ns, expiry_ns);
            defer initial_tau.deinit(allocator);

            const schedule = try Schedule.create(allocator, create_cmd.name, &[_]Tau{initial_tau});
            defer schedule.deinit(allocator);

            const serialized = try schedule.serialize(allocator);
            defer allocator.free(serialized);

            const key = try makeScheduleKey(create_cmd.name, allocator);
            defer allocator.free(key);

            const result = try engine.execute(.Put, key, serialized);
            _ = result; // Put returns null
            return null;
        },
        .Append => |append_cmd| {
            const key = try makeScheduleKey(append_cmd.name, allocator);
            defer allocator.free(key);

            const existing_data = try engine.execute(.Get, key, "");
            if (existing_data == null or existing_data.?.len == 0) {
                return ExecutorError.NonExistent;
            }
            defer allocator.free(existing_data.?);

            var schedule: Schedule = undefined;
            try schedule.deserialize(allocator, existing_data.?);
            defer schedule.deinit(allocator);

            // Parse the text as float for diff
            const diff = try parseFloat(append_cmd.text);

            // Create new tau with current time
            const now_ns = std.time.nanoTimestamp();
            const valid_ns = @as(u64, @intCast(now_ns));
            const expiry_ns = valid_ns + std.time.ns_per_hour;

            var new_tau = try Tau.create(allocator, diff, valid_ns, expiry_ns);
            errdefer new_tau.deinit(allocator);

            try schedule.addTaus(allocator, &[_]Tau{new_tau});

            const serialized = try schedule.serialize(allocator);
            defer allocator.free(serialized);

            const result = try engine.execute(.Put, key, serialized);
            _ = result;
            return null;
        },
        .Range => |range_cmd| {
            const key = try makeScheduleKey(range_cmd.name, allocator);
            defer allocator.free(key);

            const existing_data = try engine.execute(.Get, key, "");
            if (existing_data == null or existing_data.?.len == 0) {
                return ExecutorError.NonExistent;
            }
            defer allocator.free(existing_data.?);

            var schedule: Schedule = undefined;
            try schedule.deserialize(allocator, existing_data.?);
            defer schedule.deinit(allocator);

            // Collect all diffs valid in the range [start_ts, end_ts)
            var valid_diffs = try std.ArrayList(f64).initCapacity(allocator, 0);
            defer valid_diffs.deinit(allocator);

            for (schedule.taus) |tau| {
                if (tau.valid_ns < range_cmd.end_ts and tau.expiry_ns > range_cmd.start_ts) {
                    try valid_diffs.append(allocator, tau.diff);
                }
            }

            // Return as JSON array
            var json_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
            defer json_buf.deinit(allocator);

            try json_buf.append(allocator, '[');
            for (valid_diffs.items, 0..) |diff, i| {
                if (i > 0) try json_buf.append(allocator, ',');
                try std.fmt.format(json_buf.writer(allocator), "{d}", .{diff});
            }
            try json_buf.append(allocator, ']');

            return try allocator.dupe(u8, json_buf.items);
        },
        .At => |at_cmd| {
            const key = try makeScheduleKey(at_cmd.name, allocator);
            defer allocator.free(key);

            const existing_data = try engine.execute(.Get, key, "");
            if (existing_data == null or existing_data.?.len == 0) {
                return ExecutorError.NonExistent;
            }
            defer allocator.free(existing_data.?);

            var schedule: Schedule = undefined;
            try schedule.deserialize(allocator, existing_data.?);
            defer schedule.deinit(allocator);

            // Collect all diffs valid at the specific timestamp
            var valid_diffs = try std.ArrayList(f64).initCapacity(allocator, 0);
            defer valid_diffs.deinit(allocator);

            for (schedule.taus) |tau| {
                if (tau.valid_ns <= at_cmd.ts and at_cmd.ts < tau.expiry_ns) {
                    try valid_diffs.append(allocator, tau.diff);
                }
            }

            // Return as JSON array
            var json_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
            defer json_buf.deinit(allocator);

            try json_buf.append(allocator, '[');
            for (valid_diffs.items, 0..) |diff, i| {
                if (i > 0) try json_buf.append(allocator, ',');
                try std.fmt.format(json_buf.writer(allocator), "{d}", .{diff});
            }
            try json_buf.append(allocator, ']');

            return try allocator.dupe(u8, json_buf.items);
        },
    };
}

// test "execute create_schedule command" {
//     const storage = std.testing.allocator; // Placeholder for actual storage engine
//     const cmd = command.Command{
//         .CreateSchedule = .{
//             .name = "meeting",
//         },
//     };
//     const result = try executeCommand(cmd, storage);
//     try std.testing.expect(result == null);
// }

// test "execute append command" {
//     const storage = std.testing.allocator; // Placeholder for actual storage engine
//     const cmd = command.Command{
//         .Append = .{
//             .name = "meeting",
//             .text = "Discuss project updates",
//         },
//     };
//     try executeCommand(cmd, storage);
// }
