//! Parser for commands

const std = @import("std");

const CommandType = enum {
    CreateSchedule,
    Append,
    Range,
    At,
};

pub const Command = union(CommandType) {
    CreateSchedule: struct {
        name: []const u8,
    },
    Append: struct {
        name: []const u8,
        text: []const u8,
    },
    Range: struct {
        name: []const u8,
        start_ts: u64,
        end_ts: u64,
    },
    At: struct {
        name: []const u8,
        ts: u64,
    },
};

pub const ParseError = error{
    EmptyInput,
    UnknownCommand,
    MissingArgs,
    TooManyArgs,
};

const CommandMap = [_]struct {
    name: []const u8,
    tag: CommandType,
}{
    .{ .name = "create_schedule", .tag = .CreateSchedule },
    .{ .name = "append", .tag = .Append },
    .{ .name = "range", .tag = .Range },
    .{ .name = "at", .tag = .At },
};

fn parseCommandType(s: []const u8) ?CommandType {
    inline for (CommandMap) |entry| {
        if (std.mem.eql(u8, s, entry.name))
            return entry.tag;
    }
    return null;
}

pub fn parseCommand(input: []const u8) ParseError!Command {
    const trimmed = std.mem.trim(u8, input, " \t\n\r");
    if (trimmed.len == 0) return error.EmptyInput;

    // Find command
    const cmd_end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
    const cmd_str = trimmed[0..cmd_end];
    const cmd_type = parseCommandType(cmd_str) orelse return error.UnknownCommand;

    const remaining = trimmed[cmd_end..];
    const trimmed_remaining = std.mem.trim(u8, remaining, " \t\n\r");

    return switch (cmd_type) {
        .CreateSchedule => {
            if (trimmed_remaining.len == 0) return error.MissingArgs;
            // Find name (everything until next space or end)
            const name_end = std.mem.indexOfScalar(u8, trimmed_remaining, ' ') orelse trimmed_remaining.len;
            const name = trimmed_remaining[0..name_end];
            const after_name = trimmed_remaining[name_end..];
            if (std.mem.trim(u8, after_name, " \t\n\r").len > 0) return error.TooManyArgs;

            return Command{
                .CreateSchedule = .{
                    .name = name,
                },
            };
        },
        .Append => {
            if (trimmed_remaining.len == 0) return error.MissingArgs;
            // Find name
            const name_end = std.mem.indexOfScalar(u8, trimmed_remaining, ' ') orelse return error.MissingArgs;
            const name = trimmed_remaining[0..name_end];
            const text_start = name_end + 1;
            if (text_start >= trimmed_remaining.len) return error.MissingArgs;
            const text = std.mem.trim(u8, trimmed_remaining[text_start..], " \t\n\r");
            if (text.len == 0) return error.MissingArgs;

            return Command{
                .Append = .{
                    .name = name,
                    .text = text,
                },
            };
        },
        .Range => {
            if (trimmed_remaining.len == 0) return error.MissingArgs;
            // Parse: name start_ts end_ts
            const space1 = std.mem.indexOfScalar(u8, trimmed_remaining, ' ') orelse return error.MissingArgs;
            const name = trimmed_remaining[0..space1];

            var remaining1 = trimmed_remaining[space1 + 1 ..];
            if (remaining1.len == 0) return error.MissingArgs;

            const space2 = std.mem.indexOfScalar(u8, remaining1, ' ') orelse return error.MissingArgs;
            const start_ts_str = remaining1[0..space2];

            const end_ts_str = remaining1[space2 + 1 ..];
            if (end_ts_str.len == 0) return error.MissingArgs;

            const start_ts = std.fmt.parseInt(u64, start_ts_str, 10) catch return error.MissingArgs;
            const end_ts = std.fmt.parseInt(u64, end_ts_str, 10) catch return error.MissingArgs;

            return Command{
                .Range = .{
                    .name = name,
                    .start_ts = start_ts,
                    .end_ts = end_ts,
                },
            };
        },
        .At => {
            if (trimmed_remaining.len == 0) return error.MissingArgs;
            // Parse: name ts
            const space = std.mem.indexOfScalar(u8, trimmed_remaining, ' ') orelse return error.MissingArgs;
            const name = trimmed_remaining[0..space];

            const ts_str = trimmed_remaining[space + 1 ..];
            if (ts_str.len == 0) return error.MissingArgs;

            const ts = std.fmt.parseInt(u64, ts_str, 10) catch return error.MissingArgs;

            return Command{
                .At = .{
                    .name = name,
                    .ts = ts,
                },
            };
        },
    };
}

test "parse create_schedule command" {
    const input = "create_schedule MySchedule";
    const cmd = parseCommand(input) catch unreachable;

    switch (cmd) {
        .CreateSchedule => |cs| {
            try std.testing.expect(std.mem.eql(u8, cs.name, "MySchedule"));
        },
        else => try std.testing.expect(false),
    }
}

test "parse range command" {
    const input = "range MySchedule 1000 2000";
    const cmd = parseCommand(input) catch unreachable;

    switch (cmd) {
        .Range => |r| {
            try std.testing.expect(std.mem.eql(u8, r.name, "MySchedule"));
            try std.testing.expect(r.start_ts == 1000);
            try std.testing.expect(r.end_ts == 2000);
        },
        else => try std.testing.expect(false),
    }
}

test "parse at command" {
    const input = "at MySchedule 1500";
    const cmd = parseCommand(input) catch unreachable;

    switch (cmd) {
        .At => |a| {
            try std.testing.expect(std.mem.eql(u8, a.name, "MySchedule"));
            try std.testing.expect(a.ts == 1500);
        },
        else => try std.testing.expect(false),
    }
}
