//! A module defining a Lens structure which represents a calculation or transformation over schedules.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const primitives = @import("mod.zig");
const Tau = primitives.Tau;
const Schedule = primitives.Schedule;
const Frame = primitives.Frame;
const ULID = @import("ulid").ULID;
const lens_expr = @import("lens_expression.zig");

/// Errors that can occur during lens evaluation.
pub const LensError = error{
    MissingData,
};

/// A lens represents a calculation or transformation identified by a unique id.
pub const Lens = struct {
    id: []const u8, // Unique identifier (ULID string)
    name: []const u8,
    description: []const u8,
    expression: []const u8,

    // Map variable names to input schedules by name
    input_schedules: std.StringHashMap(*const Schedule),

    /// Frees heap-allocated strings and map.
    pub fn deinit(self: *Lens, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.expression);
        self.input_schedules.deinit();
    }

    /// Creates a new Lens with auto-generated ID
    pub fn create(allocator: Allocator, name: []const u8, description: []const u8, expression: []const u8) !Lens {
        assert(name.len > 0);
        assert(description.len > 0);
        assert(expression.len > 0);

        const ulid = try ULID.create();
        const id = ulid.toString();
        const lens_name = try allocator.dupe(u8, name);
        const lens_description = try allocator.dupe(u8, description);
        const lens_expression = try allocator.dupe(u8, expression);

        const lens = Lens{
            .id = id,
            .name = lens_name,
            .description = lens_description,
            .expression = lens_expression,
            .input_schedules = std.StringHashMap(*const Schedule).init(allocator),
        };

        assert(lens.name.len > 0);
        assert(lens.description.len > 0);
        assert(lens.expression.len > 0);
        return lens;
    }

    /// Adds an input schedule to the lens, mapping variable name to schedule.
    pub fn addInput(self: *Lens, allocator: Allocator, var_name: []const u8, schedule: *const Schedule) !void {
        try self.input_schedules.put(allocator, var_name, schedule);
    }

    /// Applies lens transformation across all input schedules, creating a new schedule.
    /// Aligns taus by time and evaluates expression for each time point.
    pub fn apply(self: *Lens, allocator: Allocator) !Schedule {
        assert(self.name.len > 0);
        assert(self.expression.len > 0);
        assert(self.input_schedules.count() > 0);

        // Find the schedule with the most taus to determine output size
        var max_taus: usize = 0;
        var schedule_iter = self.input_schedules.iterator();
        while (schedule_iter.next()) |entry| {
            if (entry.value_ptr.*.taus.len > max_taus) {
                max_taus = entry.value_ptr.*.taus.len;
            }
        }

        var output_taus = std.ArrayList(Tau).initCapacity(allocator, max_taus);
        defer output_taus.deinit();

        // Process each time point by index (assume schedules are aligned)
        for (0..max_taus) |i| {
            if (try self.processTimePoint(allocator, i)) |tau| {
                try output_taus.append(allocator, tau);
            } else |err| switch (err) {
                error.MissingData => {
                    // Skip this time point if any input is missing (policy 3)
                    continue;
                },
                else => return err,
            }
        }

        const new_schedule = try Schedule.create(allocator, self.name, output_taus.items);
        return new_schedule;
    }

    /// Processes a single time point across all input schedules.
    /// Returns MissingData if any required variable is missing at this time point.
    fn processTimePoint(self: *const Lens, allocator: Allocator, time_index: usize) !?Tau {
        var vars = std.ArrayList(lens_expr.Variable).init(allocator);
        defer vars.deinit();

        // Collect values for all variables in expression
        var schedule_iter = self.input_schedules.iterator();
        while (schedule_iter.next()) |entry| {
            const var_name = entry.key_ptr.*;
            const schedule = entry.value_ptr.*;

            // Handle special time variables
            if (std.mem.eql(u8, var_name, "vt")) {
                // Find a schedule that has time data for vt
                if (time_index < schedule.taus.len) {
                    const tau = schedule.taus[time_index];
                    try vars.append(allocator, .{ .name = var_name, .value = @as(f64, @floatFromInt(tau.valid_ns)) });
                } else {
                    return error.MissingData;
                }
            } else if (std.mem.eql(u8, var_name, "et")) {
                if (time_index < schedule.taus.len) {
                    const tau = schedule.taus[time_index];
                    try vars.append(allocator, .{ .name = var_name, .value = @as(f64, @floatFromInt(tau.expiry_ns)) });
                } else {
                    return error.MissingData;
                }
            } else {
                // Regular variable - get diff value from corresponding schedule
                if (time_index < schedule.taus.len) {
                    const tau = schedule.taus[time_index];
                    try vars.append(allocator, .{ .name = var_name, .value = tau.diff });
                } else {
                    return error.MissingData;
                }
            }
        }

        // Evaluate expression
        const result = try lens_expr.evaluate(self.expression, allocator, vars.items);

        // Create output tau using timing from first input schedule
        const first_schedule = self.input_schedules.values()[0];
        if (time_index >= first_schedule.taus.len) {
            return error.MissingData;
        }

        const base_tau = first_schedule.taus[time_index];
        return try Tau.create(allocator, result, base_tau.valid_ns, base_tau.expiry_ns);
    }

    /// Applies the lens transformation to a frame, creating a new frame with
    /// all schedules transformed. Each schedule in the frame is transformed
    /// using the lens and added to the new frame.
    pub fn applyToFrame(self: *Lens, allocator: Allocator, frame: Frame) !Frame {
        assert(self.name.len > 0);
        assert(self.input_schedules.count() > 0);

        // Apply lens once to get transformed schedule
        const transformed_schedule = try self.apply(allocator);
        defer transformed_schedule.deinit();

        // Create new frame with single transformed schedule
        const transformed_schedules = try allocator.alloc(Schedule, 1);
        transformed_schedules[0] = transformed_schedule;

        const new_frame = try Frame.create(allocator, transformed_schedules);
        allocator.free(transformed_schedules);

        assert(new_frame.schedules.len == 1);
        assert(new_frame.id != frame.id);
        return new_frame;
    }
};

test "Lens creation with valid parameters" {
    const allocator = std.testing.allocator;

    const name = "Test Lens";
    const description = "A lens for testing purposes.";
    const expression = "x + y";

    var lens = try Lens.create(allocator, name, description, expression);
    defer lens.deinit(allocator);

    try std.testing.expect(std.mem.eql(u8, lens.name, name));
    try std.testing.expect(std.mem.eql(u8, lens.description, description));
    try std.testing.expect(std.mem.eql(u8, lens.expression, expression));
    try std.testing.expect(lens.id.len == 26); // ULID is 26 chars
}

test "Lens creation with invalid parameters" {
    const allocator = std.testing.allocator;

    // Test empty name
    try std.testing.expectError(error.AssertFailed, Lens.create(allocator, "", "description", "expression"));

    // Test empty description
    try std.testing.expectError(error.AssertFailed, Lens.create(allocator, "name", "", "expression"));

    // Test empty expression
    try std.testing.expectError(error.AssertFailed, Lens.create(allocator, "name", "description", ""));
}

test "Lens memory management" {
    const allocator = std.testing.allocator;

    const name = "Test Lens Name";
    const description = "Test Lens Description";
    const expression = "test_expression";

    var lens = try Lens.create(allocator, name, description, expression);

    // Test that strings are properly allocated
    try std.testing.expect(std.mem.eql(u8, lens.name, name));
    try std.testing.expect(std.mem.eql(u8, lens.description, description));
    try std.testing.expect(std.mem.eql(u8, lens.expression, expression));

    // Test deinit doesn't crash
    lens.deinit(allocator);
}

test "Lens string content handling" {
    const allocator = std.testing.allocator;

    // Test various string formats and edge cases
    const test_cases = [_]struct { name: []const u8, description: []const u8, expression: []const u8 }{
        .{ .name = "Simple", .description = "Simple desc", .expression = "x" },
        .{ .name = "Name with spaces", .description = "Desc with spaces", .expression = "a + b" },
        .{ .name = "Name-with-dashes", .description = "Desc-with-dashes", .expression = "x-y" },
        .{ .name = "Name_with_underscores", .description = "Desc_with_underscores", .expression = "x_y" },
        .{ .name = "Name123", .description = "Desc123", .expression = "x123" },
        .{ .name = "A", .description = "B", .expression = "C" }, // Single characters
        .{ .name = "Very long name with many characters to test string handling", .description = "Very long description with many characters to test string handling capabilities", .expression = "very_long_expression_with_many_characters" },
    };

    for (test_cases) |case| {
        const lens = try Lens.create(allocator, case.name, case.description, case.expression);
        defer lens.deinit(allocator);

        try std.testing.expect(std.mem.eql(u8, lens.name, case.name));
        try std.testing.expect(std.mem.eql(u8, lens.description, case.description));
        try std.testing.expect(std.mem.eql(u8, lens.expression, case.expression));
    }
}

test "Lens expression format examples" {
    const allocator = std.testing.allocator;

    // Test various mathematical/logical expressions
    const expressions = [_][]const u8{
        "x + y",
        "a * b + c",
        "sqrt(x^2 + y^2)",
        "if x > 0 then x else -x",
        "sum(array)",
        "average(values)",
        "price * quantity",
        "max(min, max(value, min))",
        "x != null ? x : default",
        "for i in range(10): i * 2",
    };

    for (expressions) |expr| {
        const lens = try Lens.create(allocator, "Test", "Test expression", expr);
        defer lens.deinit(allocator);

        try std.testing.expect(std.mem.eql(u8, lens.expression, expr));
        try std.testing.expect(lens.expression.len > 0);
    }
}

test "Lens domain-specific examples" {
    const allocator = std.testing.allocator;

    // Financial domain examples
    const financial_lens = try Lens.create(allocator, "Moving Average", "Calculates 20-period moving average of price", "sma(price, 20)");
    defer financial_lens.deinit(allocator);

    try std.testing.expect(std.mem.eql(u8, financial_lens.name, "Moving Average"));
    try std.testing.expect(std.mem.eql(u8, financial_lens.description, "Calculates 20-period moving average of price"));
    try std.testing.expect(std.mem.eql(u8, financial_lens.expression, "sma(price, 20)"));

    // Technical analysis example
    const rsi_lens = try Lens.create(allocator, "RSI", "Relative Strength Index indicator", "rsi(close, 14)");
    defer rsi_lens.deinit(allocator);

    try std.testing.expect(std.mem.eql(u8, rsi_lens.name, "RSI"));
    try std.testing.expect(std.mem.eql(u8, rsi_lens.description, "Relative Strength Index indicator"));
    try std.testing.expect(std.mem.eql(u8, rsi_lens.expression, "rsi(close, 14)"));
}

test "Lens Unicode and special characters" {
    const allocator = std.testing.allocator;

    const name = "Calculateur Δ"; // Delta symbol
    const description = "Cálculo de diferencia"; // Spanish characters
    const expression = "α + β - γ"; // Greek letters

    const lens = try Lens.create(allocator, name, description, expression);
    defer lens.deinit(allocator);

    try std.testing.expect(std.mem.eql(u8, lens.name, name));
    try std.testing.expect(std.mem.eql(u8, lens.description, description));
    try std.testing.expect(std.mem.eql(u8, lens.expression, expression));
}

test "Lens invariants and assertions" {
    const allocator = std.testing.allocator;

    const lens = try Lens.create(allocator, "Test Lens", "Test Description", "test + expression");
    defer lens.deinit(allocator);

    // Test core invariants
    try std.testing.expect(lens.name.len > 0);
    try std.testing.expect(lens.description.len > 0);
    try std.testing.expect(lens.expression.len > 0);
    try std.testing.expect(lens.id.len == 26); // ULID is 26 chars
}

test "Lens multiple instances" {
    const allocator = std.testing.allocator;

    const lenses_count = 10;
    const lenses = try allocator.alloc(Lens, lenses_count);
    defer allocator.free(lenses);

    for (lenses, 0..) |*lens, i| {
        const name = try std.fmt.allocPrint(allocator, "Lens {d}", .{i});
        const description = try std.fmt.allocPrint(allocator, "Description for lens {d}", .{i});
        const expression = try std.fmt.allocPrint(allocator, "expression_{d}", .{i});

        lens.* = try Lens.create(allocator, name, description, expression);

        allocator.free(name);
        allocator.free(description);
        allocator.free(expression);
    }
    defer for (lenses) |lens| lens.deinit(allocator);
}
