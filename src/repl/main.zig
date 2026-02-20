//! Tau REPL client for connecting to a server.

const std = @import("std");
const tau = @import("tau");
const protocol = @import("protocol");

const Header = protocol.Header;
const Opcode = protocol.Opcode;
const StatusCode = protocol.StatusCode;

const config = tau.config;

const repl_prompt = "tau> ";

const Client = struct {
    allocator: std.mem.Allocator,
    stream: ?std.net.Stream,

    fn init(allocator: std.mem.Allocator) Client {
        return .{
            .allocator = allocator,
            .stream = null,
        };
    }

    fn deinit(self: *Client) void {
        if (self.stream) |*s| {
            s.close();
        }
        self.stream = null;
    }

    fn is_connected(self: *const Client) bool {
        return self.stream != null;
    }

    fn connect(self: *Client, address: std.net.Address) !void {
        if (self.stream) |*s| {
            s.close();
        }

        var stream = try std.net.tcpConnectToAddress(address);
        errdefer stream.close();

        const cert = config.server.certificate;
        var payload: [config.server.certificate.len]u8 = cert;

        try send_request(&stream, .connect, &payload);
        try expect_ok(&stream);

        self.stream = stream;
    }

    fn disconnect(self: *Client) !void {
        if (self.stream) |*s| {
            try send_request(s, .disconnect, &.{});
            _ = read_response(s) catch {};
            s.close();
            self.stream = null;
        }
    }

    fn ping(self: *Client) !void {
        var stream = self.stream orelse return error.NotConnected;
        try send_request(&stream, .ping, &.{});
        const resp = try read_response(&stream);
        switch (resp.opcode) {
            .pong, .ok => {},
            .err => return error.RemoteError,
            else => return error.BadResponse,
        }
    }

    fn create_series(self: *Client, label: []const u8) !void {
        var stream = self.stream orelse return error.NotConnected;
        var payload = label_payload(label);
        try send_request(&stream, .create_series, &payload);
        try expect_ok(&stream);
    }

    fn drop_series(self: *Client, label: []const u8) !void {
        var stream = self.stream orelse return error.NotConnected;
        var payload = label_payload(label);
        try send_request(&stream, .drop_series, &payload);
        try expect_ok(&stream);
    }

    fn append_point(self: *Client, label: []const u8, timestamp: i64, value: f64) !void {
        var stream = self.stream orelse return error.NotConnected;
        var payload: [32 + 8 + 8]u8 = undefined;
        const label_bytes = label_payload(label);
        @memcpy(payload[0..32], label_bytes[0..32]);
        std.mem.writeInt(i64, payload[32..40], timestamp, .big);
        std.mem.writeInt(u64, payload[40..48], @bitCast(value), .big);
        try send_request(&stream, .append, &payload);
        try expect_ok(&stream);
    }

    fn query_point(self: *Client, label: []const u8, timestamp: i64) !?f64 {
        var stream = self.stream orelse return error.NotConnected;
        var payload: [32 + 8]u8 = undefined;
        const label_bytes = label_payload(label);
        @memcpy(payload[0..32], label_bytes[0..32]);
        std.mem.writeInt(i64, payload[32..40], timestamp, .big);
        try send_request(&stream, .query_point, &payload);
        const resp = try read_response(&stream);
        switch (resp.opcode) {
            .ok => {
                if (resp.payload.len == 1 and resp.payload[0] == 0) return null;
                if (resp.payload.len == 9 and resp.payload[0] == 1) {
                    const bits = std.mem.readInt(u64, resp.payload[1..9], .big);
                    return @bitCast(bits);
                }
                return error.BadResponse;
            },
            .err => return error.RemoteError,
            else => return error.BadResponse,
        }
    }
};

const Response = struct {
    opcode: Opcode,
    payload: []const u8,
};

fn label_payload(label: []const u8) [32]u8 {
    var payload = [_]u8{0} ** 32;
    const copy_len = @min(label.len, payload.len);
    @memcpy(payload[0..copy_len], label[0..copy_len]);
    return payload;
}

fn send_request(stream: *std.net.Stream, opcode: Opcode, payload: []const u8) !void {
    std.debug.assert(payload.len <= protocol.payload_length_max);

    var header_buf: [protocol.header_length]u8 = undefined;
    const header = Header{
        .opcode = opcode,
        .flags = 0,
        .payload_length = @intCast(payload.len),
    };
    header.encode(&header_buf);

    _ = try stream.write(&header_buf);
    if (payload.len > 0) {
        _ = try stream.write(payload);
    }
}

fn read_response(stream: *std.net.Stream) !Response {
    var header_buf: [protocol.header_length]u8 = undefined;
    try read_exact(stream, &header_buf);
    const header = try Header.decode(&header_buf);

    var payload_buf: [protocol.payload_length_max]u8 = undefined;
    if (header.payload_length > 0) {
        const slice = payload_buf[0..header.payload_length];
        try read_exact(stream, slice);
        return Response{ .opcode = header.opcode, .payload = slice };
    }

    return Response{ .opcode = header.opcode, .payload = &.{} };
}

fn expect_ok(stream: *std.net.Stream) !void {
    const resp = try read_response(stream);
    if (resp.opcode == .ok) return;
    if (resp.opcode == .err and resp.payload.len >= 1) {
        const status = std.meta.intToEnum(StatusCode, resp.payload[0]) catch StatusCode.internal_error;
        _ = status;
        return error.RemoteError;
    }
    return error.BadResponse;
}

fn read_exact(stream: *std.net.Stream, buffer: []u8) !void {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const n = stream.read(buffer[filled..]) catch return error.ConnectionClosed;
        if (n == 0) return error.ConnectionClosed;
        filled += n;
    }
}

fn print_help() void {
    std.debug.print(
        "Commands:\n" ++
            "  connect [host] [port]\n" ++
            "  disconnect\n" ++
            "  ping\n" ++
            "  create <label>\n" ++
            "  drop <label>\n" ++
            "  append <label> <timestamp> <value>\n" ++
            "  query <label> <timestamp>\n" ++
            "  help\n" ++
            "  quit\n",
        .{},
    );
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = Client.init(allocator);
    defer client.deinit();

    const stdin_file = std.fs.File.stdin();
    const stdout_file = std.fs.File.stdout();

    print_help();

    var line_buf: [1024]u8 = undefined;
    while (true) {
        try stdout_file.writeAll(repl_prompt);
        const line = try read_line(stdin_file, &line_buf);
        if (line == null) break;
        const trimmed = std.mem.trim(u8, line.?, " \t\r\n");
        if (trimmed.len == 0) continue;

        var iter = std.mem.splitScalar(u8, trimmed, ' ');
        const cmd = iter.next().?;

        if (std.mem.eql(u8, cmd, "help")) {
            print_help();
            continue;
        }
        if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "exit")) {
            break;
        }

        if (std.mem.eql(u8, cmd, "connect")) {
            const host = iter.next() orelse "127.0.0.1";
            const port_str = iter.next() orelse "7701";
            const port = std.fmt.parseInt(u16, port_str, 10) catch {
                std.debug.print("bad port: {s}\n", .{port_str});
                continue;
            };
            const address = std.net.Address.parseIp(host, port) catch {
                std.debug.print("bad host: {s}\n", .{host});
                continue;
            };
            client.connect(address) catch |err| {
                std.debug.print("connect failed: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("connected to {s}:{d}\n", .{host, port});
            continue;
        }

        if (std.mem.eql(u8, cmd, "disconnect")) {
            client.disconnect() catch |err| {
                std.debug.print("disconnect failed: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("disconnected\n", .{});
            continue;
        }

        if (!client.is_connected()) {
            std.debug.print("not connected (use: connect [host] [port])\n", .{});
            continue;
        }

        if (std.mem.eql(u8, cmd, "ping")) {
            client.ping() catch |err| {
                std.debug.print("ping failed: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("pong\n", .{});
            continue;
        }

        if (std.mem.eql(u8, cmd, "create")) {
            const label = iter.next() orelse {
                std.debug.print("usage: create <label>\n", .{});
                continue;
            };
            client.create_series(label) catch |err| {
                std.debug.print("create failed: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("ok\n", .{});
            continue;
        }

        if (std.mem.eql(u8, cmd, "drop")) {
            const label = iter.next() orelse {
                std.debug.print("usage: drop <label>\n", .{});
                continue;
            };
            client.drop_series(label) catch |err| {
                std.debug.print("drop failed: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("ok\n", .{});
            continue;
        }

        if (std.mem.eql(u8, cmd, "append")) {
            const label = iter.next() orelse {
                std.debug.print("usage: append <label> <timestamp> <value>\n", .{});
                continue;
            };
            const ts_str = iter.next() orelse {
                std.debug.print("usage: append <label> <timestamp> <value>\n", .{});
                continue;
            };
            const value_str = iter.next() orelse {
                std.debug.print("usage: append <label> <timestamp> <value>\n", .{});
                continue;
            };
            const timestamp = std.fmt.parseInt(i64, ts_str, 10) catch {
                std.debug.print("bad timestamp: {s}\n", .{ts_str});
                continue;
            };
            const value = std.fmt.parseFloat(f64, value_str) catch {
                std.debug.print("bad value: {s}\n", .{value_str});
                continue;
            };
            client.append_point(label, timestamp, value) catch |err| {
                std.debug.print("append failed: {s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("ok\n", .{});
            continue;
        }

        if (std.mem.eql(u8, cmd, "query")) {
            const label = iter.next() orelse {
                std.debug.print("usage: query <label> <timestamp>\n", .{});
                continue;
            };
            const ts_str = iter.next() orelse {
                std.debug.print("usage: query <label> <timestamp>\n", .{});
                continue;
            };
            const timestamp = std.fmt.parseInt(i64, ts_str, 10) catch {
                std.debug.print("bad timestamp: {s}\n", .{ts_str});
                continue;
            };
            const result = client.query_point(label, timestamp) catch |err| {
                std.debug.print("query failed: {s}\n", .{@errorName(err)});
                continue;
            };
            if (result) |value| {
                std.debug.print("value: {d}\n", .{value});
            } else {
                std.debug.print("not found\n", .{});
            }
            continue;
        }

        std.debug.print("unknown command: {s}\n", .{cmd});
    }
}

fn read_line(file: std.fs.File, buffer: []u8) !?[]const u8 {
    var idx: usize = 0;
    var byte_buf: [1]u8 = undefined;
    while (idx < buffer.len) {
        const n = file.read(&byte_buf) catch return error.ConnectionClosed;
        if (n == 0) {
            if (idx == 0) return null;
            return buffer[0..idx];
        }
        const b = byte_buf[0];
        if (b == '\n') {
            return buffer[0..idx];
        }
        buffer[idx] = b;
        idx += 1;
    }
    return buffer[0..idx];
}
