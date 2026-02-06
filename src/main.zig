const std = @import("std");
const tau = @import("tau");
const entities = tau.entities;

const log = std.log.scoped(.main);

fn to_volts(raw: u16) f64 {
    return @as(f64, @floatFromInt(raw)) * 0.001;
}

fn to_millivolts(volts: f64) f64 {
    return volts * 1000.0;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const label = [_]u8{0} ** 32;

    var series = entities.Series(u16).init(
        allocator,
        label,
        1024,
    );
    defer series.deinit();

    try series.append(1, 1000);
    try series.append(2, 2000);

    const volts_lens = entities.Lens(f64).init(
        u16,
        &series,
        to_volts,
    );
    const millivolts_lens = volts_lens.compose(
        f64,
        to_millivolts,
    );

    log.info("Volts at t=1: {d:.3}V", .{volts_lens.at(1).?});
    log.info(
        "Millivolts at t=1: {d:.1}mV",
        .{millivolts_lens.at(1).?},
    );

    series.segments.items[0].values[0] = 5000;

    log.info(
        "Updated Volts at t=1: {d:.3}V",
        .{volts_lens.at(1).?},
    );
    log.info(
        "Updated Millivolts at t=1: {d:.1}mV",
        .{millivolts_lens.at(1).?},
    );
}
