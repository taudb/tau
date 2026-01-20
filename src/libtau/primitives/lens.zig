//! A module defining a Lens structure which represents a calculation or transformation over schedules.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const primitives = @import("mod.zig");
const Tau = primitives.Tau;
const Schedule = primitives.Schedule;
const Frame = primitives.Frame;
const ULID = @import("ulid").ULID;

/// A lens represents a calculation or transformation identified by a unique id.
pub const Lens = struct {
    id: []const u8, // Unique identifier (ULID string)
    name: []const u8,
    description: []const u8,
    expression: []const u8,

    /// Frees the heap-allocated strings.
    pub fn deinit(self: Lens, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.expression);
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
        };

        assert(lens.name.len > 0);
        assert(lens.description.len > 0);
        assert(lens.expression.len > 0);
        return lens;
    }

    /// Applies the lens transformation to a schedule, creating a new schedule.
    /// Currently performs identity transform (deep copy) as expression evaluation
    /// will be implemented by a separate query engine.
    pub fn applyToSchedule(self: Lens, allocator: Allocator, schedule: Schedule) !Schedule {
        assert(self.name.len > 0);
        assert(self.expression.len > 0);
        assert(schedule.taus.len > 0);

        const transformed_taus = try self.transformTaus(allocator, schedule.taus);
        errdefer {
            for (transformed_taus) |t| t.deinit(allocator);
            allocator.free(transformed_taus);
        }

        const new_schedule = try Schedule.create(allocator, self.name, transformed_taus);

        for (transformed_taus) |t| t.deinit(allocator);
        allocator.free(transformed_taus);

        assert(new_schedule.name.len > 0);
        assert(new_schedule.taus.len == schedule.taus.len);
        assert(std.mem.eql(u8, new_schedule.name, self.name));
        assert(new_schedule.id != schedule.id);
        return new_schedule;
    }

    /// Applies the lens transformation to a frame, creating a new frame with
    /// all schedules transformed. Each schedule in the frame is transformed
    /// using the lens and added to the new frame.
    pub fn applyToFrame(self: Lens, allocator: Allocator, frame: Frame) !Frame {
        assert(self.name.len > 0);
        assert(frame.schedules.len > 0);

        const transformed_schedules = try allocator.alloc(Schedule, frame.schedules.len);
        errdefer {
            for (transformed_schedules) |s| s.deinit(allocator);
            allocator.free(transformed_schedules);
        }

        for (frame.schedules, 0..) |schedule, i| {
            assert(schedule.taus.len > 0);
            transformed_schedules[i] = try self.applyToSchedule(allocator, schedule);
        }

        const new_frame = try Frame.create(allocator, transformed_schedules);

        for (transformed_schedules) |s| s.deinit(allocator);
        allocator.free(transformed_schedules);

        assert(new_frame.schedules.len == frame.schedules.len);
        assert(new_frame.id != frame.id);
        return new_frame;
    }

    /// Internal helper: Transforms a slice of taus using the lens expression.
    /// Currently performs identity transform (deep copy) - actual expression
    /// evaluation will be implemented by a separate query engine.
    fn transformTaus(_: Lens, allocator: Allocator, taus: []const Tau) ![]Tau {
        assert(taus.len > 0);

        const result = try allocator.alloc(Tau, taus.len);
        errdefer {
            for (result) |t| t.deinit(allocator);
            allocator.free(result);
        }

        for (taus, 0..) |tau, i| {
            assert(tau.diff.len > 0);
            result[i] = try Tau.create(allocator, tau.diff, tau.valid_ns, tau.expiry_ns);
        }

        assert(result.len == taus.len);
        return result;
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
