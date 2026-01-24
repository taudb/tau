//! Expression evaluator for lens expressions.
//! Basic math engine supporting variables and arithmetic operations.

const std = @import("std");
const Allocator = std.mem.Allocator;

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
        const tokens = try tokenize(allocator, expression);
        return ExprEvaluator{
            .tokens = tokens,
            .position = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ExprEvaluator) void {
        for (self.tokens) |token| {
            self.allocator.free(token.value);
        }
        self.allocator.free(self.tokens);
    }

    pub fn evaluate(self: *ExprEvaluator, vars: []const Variable) ExprError!f64 {
        self.position = 0;
        return self.parseExpression(vars);
    }

    fn parseExpression(self: *ExprEvaluator, vars: []const Variable) ExprError!f64 {
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
        if (self.position >= self.tokens.len) {
            return Token{ .type = .eof, .value = "", .number = 0.0 };
        }
        return self.tokens[self.position];
    }

    fn advance(self: *ExprEvaluator) void {
        self.position += 1;
    }
};

fn tokenize(allocator: std.mem.Allocator, expression: []const u8) ![]ExprEvaluator.Token {
    var tokens_list = std.ArrayList(ExprEvaluator.Token).initCapacity(allocator, 0);
    defer {
        for (tokens_list.items) |token| {
            allocator.free(token.value);
        }
        tokens_list.deinit();
    }

    var i: usize = 0;
    while (i < expression.len) {
        const c = expression[i];

        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }

        switch (c) {
            '+' => {
                const value = try allocator.dupe(u8, "+");
                try tokens_list.append(allocator, .{ .type = .plus, .value = value, .number = 0.0 });
                i += 1;
            },
            '-' => {
                const value = try allocator.dupe(u8, "-");
                try tokens_list.append(allocator, .{ .type = .minus, .value = value, .number = 0.0 });
                i += 1;
            },
            '*' => {
                const value = try allocator.dupe(u8, "*");
                try tokens_list.append(allocator, .{ .type = .multiply, .value = value, .number = 0.0 });
                i += 1;
            },
            '/' => {
                const value = try allocator.dupe(u8, "/");
                try tokens_list.append(allocator, .{ .type = .divide, .value = value, .number = 0.0 });
                i += 1;
            },
            '(' => {
                const value = try allocator.dupe(u8, "(");
                try tokens_list.append(allocator, .{ .type = .lparen, .value = value, .number = 0.0 });
                i += 1;
            },
            ')' => {
                const value = try allocator.dupe(u8, ")");
                try tokens_list.append(allocator, .{ .type = .rparen, .value = value, .number = 0.0 });
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
                    const value = try allocator.dupe(u8, number_str);
                    try tokens_list.append(allocator, .{ .type = .number, .value = value, .number = number });
                } else if (std.ascii.isAlphabetic(c)) {
                    const start = i;
                    while (i < expression.len and std.ascii.isAlphabetic(expression[i])) {
                        i += 1;
                    }
                    const var_name = expression[start..i];
                    const value = try allocator.dupe(u8, var_name);
                    try tokens_list.append(allocator, .{ .type = .variable, .value = value, .number = 0.0 });
                } else {
                    return ExprError.InvalidCharacter;
                }
            },
        }
    }

    const eof_value = try allocator.dupe(u8, "");
    try tokens_list.append(allocator, .{ .type = .eof, .value = eof_value, .number = 0.0 });

    return try tokens_list.toOwnedSlice(allocator);
}

/// Convenience function to evaluate an expression without managing evaluator.
pub fn evaluate(expr: []const u8, allocator: std.mem.Allocator, vars: []const Variable) !f64 {
    var evaluator = try ExprEvaluator.init(allocator, expr);
    defer evaluator.deinit();
    return evaluator.evaluate(vars) catch |err| switch (err) {
        ExprError.DivisionByZero,
        ExprError.UndefinedVariable,
        ExprError.UnexpectedToken,
        ExprError.InvalidCharacter,
        => err,
    };
}
