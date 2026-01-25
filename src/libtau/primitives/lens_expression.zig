//! Expression evaluator for lens expressions.
//! Basic math engine supporting variables and arithmetic operations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Variable binding for expression evaluation.
pub const Variable = struct {
    name: []const u8,
    value: f64,
};

/// Errors that can occur during expression evaluation.
pub const ExprError = error{
    DivisionByZero,
    UndefinedVariable,
    UnexpectedToken,
    InvalidCharacter,
};

/// Simple expression evaluator for basic math operations.
pub const ExprEvaluator = struct {
    tokens: []Token,
    position: usize,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    const Token = struct {
        type: TokenType,
        value: []const u8,
        number: f64,

        const TokenType = enum {
            number,
            variable,
            plus,
            minus,
            multiply,
            divide,
            lparen,
            rparen,
            eof,
        };
    };

    pub fn init(allocator: std.mem.Allocator, expression: []const u8) !ExprEvaluator {
        // Preconditions
        assert(allocator != null);
        assert(expression.len > 0);

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const tokens = try tokenize(arena.allocator(), expression);

        // Postconditions
        assert(tokens.len > 0); // At least EOF token

        return ExprEvaluator{
            .tokens = tokens,
            .position = 0,
            .allocator = allocator,
            .arena = arena,
        };
    }

    pub fn deinit(self: *ExprEvaluator) void {
        // Preconditions
        assert(self != null);

        self.arena.deinit();
    }

    pub fn evaluate(self: *ExprEvaluator, vars: []const Variable) ExprError!f64 {
        // Preconditions
        assert(self != null);
        assert(self.tokens.len > 0);

        self.position = 0;
        const result = try self.parseExpression(vars);

        // Postconditions
        assert(std.math.isFinite(result));

        return result;
    }

    fn parseExpression(self: *ExprEvaluator, vars: []const Variable) ExprError!f64 {
        // Preconditions
        assert(self.position < self.tokens.len + 1); // Allow for EOF

        var result = try self.parseTerm(vars);

        while (self.current().type == .plus or self.current().type == .minus) {
            const op = self.current().type;
            self.advance();
            const right = try self.parseTerm(vars);

            switch (op) {
                .plus => result += right,
                .minus => result -= right,
                else => unreachable,
            }
        }

        return result;
    }

    fn parseTerm(self: *ExprEvaluator, vars: []const Variable) ExprError!f64 {
        // Preconditions
        assert(self.position < self.tokens.len + 1); // Allow for EOF

        var result = try self.parseFactor(vars);

        while (self.current().type == .multiply or self.current().type == .divide) {
            const op = self.current().type;
            self.advance();
            const right = try self.parseFactor(vars);

            switch (op) {
                .multiply => result *= right,
                .divide => {
                    if (right == 0.0) {
                        return ExprError.DivisionByZero;
                    }
                    result /= right;
                },
                else => unreachable,
            }
        }

        return result;
    }

    fn parseFactor(self: *ExprEvaluator, vars: []const Variable) ExprError!f64 {
        // Preconditions
        assert(self.position < self.tokens.len);

        const token = self.current();

        switch (token.type) {
            .number => {
                self.advance();
                return token.number;
            },
            .variable => {
                self.advance();
                for (vars) |var_item| {
                    if (std.mem.eql(u8, var_item.name, token.value)) {
                        return var_item.value;
                    }
                }
                return ExprError.UndefinedVariable;
            },
            .lparen => {
                self.advance();
                const result = try self.parseExpression(vars);
                if (self.current().type != .rparen) {
                    return ExprError.UnexpectedToken;
                }
                self.advance();
                return result;
            },
            else => return ExprError.UnexpectedToken,
        }
    }

    fn current(self: *const ExprEvaluator) Token {
        // Preconditions
        assert(self != null);

        if (self.position >= self.tokens.len) {
            return Token{ .type = .eof, .value = "", .number = 0.0 };
        }
        return self.tokens[self.position];
    }

    fn advance(self: *ExprEvaluator) void {
        // Preconditions
        assert(self != null);

        self.position += 1;

        // Postcondition
        assert(self.position <= self.tokens.len + 1);
    }
};

fn tokenize(allocator: std.mem.Allocator, expression: []const u8) ![]ExprEvaluator.Token {
    // Preconditions
    assert(allocator != null);
    assert(expression.len > 0);

    var tokens_list = std.ArrayList(ExprEvaluator.Token).initCapacity(allocator, 16);
    defer tokens_list.deinit();

    var i: usize = 0;
    while (i < expression.len) {
        const c = expression[i];

        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }

        switch (c) {
            '+' => {
                try tokens_list.append(allocator, .{ .type = .plus, .value = "+", .number = 0.0 });
                i += 1;
            },
            '-' => {
                try tokens_list.append(allocator, .{ .type = .minus, .value = "-", .number = 0.0 });
                i += 1;
            },
            '*' => {
                try tokens_list.append(allocator, .{ .type = .multiply, .value = "*", .number = 0.0 });
                i += 1;
            },
            '/' => {
                try tokens_list.append(allocator, .{ .type = .divide, .value = "/", .number = 0.0 });
                i += 1;
            },
            '(' => {
                try tokens_list.append(allocator, .{ .type = .lparen, .value = "(", .number = 0.0 });
                i += 1;
            },
            ')' => {
                try tokens_list.append(allocator, .{ .type = .rparen, .value = ")", .number = 0.0 });
                i += 1;
            },
            else => {
                if (std.ascii.isDigit(c) or c == '.') {
                    const start = i;
                    while (i < expression.len and (std.ascii.isDigit(expression[i]) or expression[i] == '.')) {
                        i += 1;
                    }
                    const number_str = expression[start..i];
                    const number = try std.fmt.parseFloat(f64, number_str);
                    try tokens_list.append(allocator, .{ .type = .number, .value = number_str, .number = number });
                } else if (std.ascii.isAlphabetic(c)) {
                    const start = i;
                    while (i < expression.len and std.ascii.isAlphabetic(expression[i])) {
                        i += 1;
                    }
                    const var_name = expression[start..i];
                    try tokens_list.append(allocator, .{ .type = .variable, .value = var_name, .number = 0.0 });
                } else {
                    return ExprError.InvalidCharacter;
                }
            },
        }
    }

    // Always add EOF token
    try tokens_list.append(allocator, .{ .type = .eof, .value = "", .number = 0.0 });

    const result = try tokens_list.toOwnedSlice(allocator);

    // Postconditions
    assert(result.len > 0); // At least EOF token
    assert(result[result.len - 1].type == .eof);

    return result;
}

/// Convenience function to evaluate an expression without managing evaluator.
pub fn evaluate(expr: []const u8, allocator: std.mem.Allocator, vars: []const Variable) !f64 {
    // Preconditions
    assert(expr.len > 0);
    assert(allocator != null);

    var evaluator = try ExprEvaluator.init(allocator, expr);
    defer evaluator.deinit();

    const result = try evaluator.evaluate(vars);

    // Postconditions
    assert(std.math.isFinite(result));

    return result;
}
