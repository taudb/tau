//! Per-connection request handler.
//!
//! Each client connection runs in its own thread. The handler
//! reads framed messages, enforces the authentication gate,
//! dispatches to the catalog, and writes responses.

const std = @import("std");
const protocol = @import("protocol");
const auth_mod = @import("auth.zig");
const catalog_mod = @import("catalog");
const metrics_mod = @import("metrics");

const Header = protocol.Header;
const Opcode = protocol.Opcode;
const StatusCode = protocol.StatusCode;

const log = std.log.scoped(.handler);

pub const Handler = struct {
    stream: std.net.Stream,
    catalog: *catalog_mod.Catalog,
    session: auth_mod.Session,
    server_certificate: *const [auth_mod.certificate_length]u8,
    counters: *metrics_mod.Counters,

    const Self = @This();

    pub fn init(
        stream: std.net.Stream,
        address: std.net.Address,
        catalog: *catalog_mod.Catalog,
        server_certificate: *const [auth_mod.certificate_length]u8,
        counters: *metrics_mod.Counters,
    ) Self {
        return .{
            .stream = stream,
            .catalog = catalog,
            .session = auth_mod.Session.init(address),
            .server_certificate = server_certificate,
            .counters = counters,
        };
    }

    pub fn run(self: *Self) void {
        self.serve() catch |serve_error| {
            log.err(
                "connection error: {s}",
                .{@errorName(serve_error)},
            );
        };
        self.stream.close();
    }

    fn serve(self: *Self) !void {
        while (true) {
            var header_buffer: [protocol.header_length]u8 = undefined;
            self.read_exact(&header_buffer) catch return;

            const header = Header.decode(&header_buffer) catch |decode_error| {
                const status = switch (decode_error) {
                    error.BadMagic => StatusCode.bad_magic,
                    error.BadVersion => StatusCode.bad_version,
                    error.BadOpcode => StatusCode.bad_opcode,
                    error.PayloadTooLarge => StatusCode.payload_too_large,
                };
                self.counters.inc_error(status);
                try self.send_error(status);
                return;
            };

            var payload_buffer: [protocol.payload_length_max]u8 = undefined;
            if (header.payload_length > 0) {
                const payload_slice = payload_buffer[0..header.payload_length];
                self.read_exact(payload_slice) catch return;
            }
            const payload = payload_buffer[0..header.payload_length];

            self.counters.inc_request(header.opcode);

            if (header.opcode == .disconnect) {
                self.session.disconnect();
                try self.send_ok(&.{});
                return;
            }

            if (header.opcode == .connect) {
                try self.handle_connect(payload);
                continue;
            }

            if (!self.session.authenticated) {
                self.counters.inc_error(.not_authenticated);
                try self.send_error(.not_authenticated);
                return;
            }

            switch (header.opcode) {
                .ping => try self.handle_ping(),
                .create_series => try self.handle_create(payload),
                .drop_series => try self.handle_drop(payload),
                .append => try self.handle_append(payload),
                .query_point => try self.handle_query_point(payload),
                .create_lens => try self.handle_create_lens(payload),
                .drop_lens => try self.handle_drop_lens(payload),
                .query_lens => try self.handle_query_lens(payload),
                .compose_lens => try self.handle_compose_lens(payload),
                .list_lenses => try self.handle_list_lenses(payload),
                else => try self.send_error(.bad_opcode),
            }
        }
    }

    fn handle_connect(self: *Self, payload: []const u8) !void {
        if (payload.len != auth_mod.certificate_length) {
            self.counters.inc_error(.invalid_payload);
            try self.send_error(.invalid_payload);
            return;
        }

        const client_cert: *const [auth_mod.certificate_length]u8 =
            payload[0..auth_mod.certificate_length];

        self.session.authenticate(
            client_cert,
            self.server_certificate,
        ) catch {
            self.counters.inc_error(.auth_failed);
            try self.send_error(.auth_failed);
            return;
        };

        try self.send_ok(&.{});
    }

    fn handle_ping(self: *Self) !void {
        try self.send_response(.pong, &.{});
    }

    fn handle_create(self: *Self, payload: []const u8) !void {
        if (payload.len != catalog_mod.label_length) {
            self.counters.inc_error(.invalid_payload);
            try self.send_error(.invalid_payload);
            return;
        }

        const label: [catalog_mod.label_length]u8 =
            payload[0..catalog_mod.label_length].*;

        self.catalog.create_series(label) catch |create_error| {
            const status: StatusCode = switch (create_error) {
                error.SeriesAlreadyExists => .series_already_exists,
                else => .internal_error,
            };
            self.counters.inc_error(status);
            try self.send_error(status);
            return;
        };

        try self.send_ok(&.{});
    }

    fn handle_drop(self: *Self, payload: []const u8) !void {
        if (payload.len != catalog_mod.label_length) {
            self.counters.inc_error(.invalid_payload);
            try self.send_error(.invalid_payload);
            return;
        }

        const label: [catalog_mod.label_length]u8 =
            payload[0..catalog_mod.label_length].*;

        self.catalog.drop_series(label) catch {
            self.counters.inc_error(.series_not_found);
            try self.send_error(.series_not_found);
            return;
        };

        try self.send_ok(&.{});
    }

    // Append payload: [32 bytes label][8 bytes timestamp][8 bytes f64 value].
    const append_payload_length: u32 = catalog_mod.label_length + 8 + 8;

    fn handle_append(self: *Self, payload: []const u8) !void {
        if (payload.len != append_payload_length) {
            self.counters.inc_error(.invalid_payload);
            try self.send_error(.invalid_payload);
            return;
        }

        const label_end = catalog_mod.label_length;
        const label: [catalog_mod.label_length]u8 =
            payload[0..label_end].*;
        const timestamp: i64 = std.mem.readInt(
            i64,
            payload[label_end..][0..8],
            .big,
        );
        const value: f64 = @bitCast(std.mem.readInt(
            u64,
            payload[label_end + 8 ..][0..8],
            .big,
        ));

        self.catalog.append(label, timestamp, value) catch |append_error| {
            const status: StatusCode = switch (append_error) {
                error.SeriesNotFound => .series_not_found,
                error.OutOfOrder => .out_of_order,
                else => .internal_error,
            };
            self.counters.inc_error(status);
            try self.send_error(status);
            return;
        };

        try self.send_ok(&.{});
    }

    // Point query payload: [32 bytes label][8 bytes timestamp].
    // Response payload: [1 byte found][8 bytes f64 value if found].
    const query_payload_length: u32 = catalog_mod.label_length + 8;

    fn handle_query_point(
        self: *Self,
        payload: []const u8,
    ) !void {
        if (payload.len != query_payload_length) {
            self.counters.inc_error(.invalid_payload);
            try self.send_error(.invalid_payload);
            return;
        }

        const label_end = catalog_mod.label_length;
        const label: [catalog_mod.label_length]u8 =
            payload[0..label_end].*;
        const timestamp: i64 = std.mem.readInt(
            i64,
            payload[label_end..][0..8],
            .big,
        );

        const result = self.catalog.query_point(
            label,
            timestamp,
        ) catch {
            self.counters.inc_error(.series_not_found);
            try self.send_error(.series_not_found);
            return;
        };

        if (result) |value| {
            var response: [9]u8 = undefined;
            response[0] = 1;
            std.mem.writeInt(
                u64,
                response[1..9],
                @bitCast(value),
                .big,
            );
            try self.send_ok(&response);
        } else {
            try self.send_ok(&[_]u8{0});
        }
    }

    fn handle_create_lens(self: *Self, payload: []const u8) !void {
        if (payload.len != catalog_mod.label_length * 2 + 32) {
            self.counters.inc_error(.invalid_payload);
            try self.send_error(.invalid_payload);
            return;
        }

        var label: [catalog_mod.label_length]u8 = undefined;
        var source_label: [catalog_mod.label_length]u8 = undefined;
        @memcpy(label[0..catalog_mod.label_length], payload[0..catalog_mod.label_length]);
        @memcpy(source_label[0..catalog_mod.label_length], payload[catalog_mod.label_length .. catalog_mod.label_length * 2]);

        const transform_name = payload[catalog_mod.label_length * 2 ..];
        const transform = catalog_mod.Catalog.get_transform_from_name(transform_name) orelse {
            self.counters.inc_error(.invalid_payload);
            try self.send_error(.invalid_payload);
            return;
        };

        self.catalog.create_lens(label, source_label, transform) catch |err| {
            const status: StatusCode = switch (err) {
                error.LensAlreadyExists => .lens_already_exists,
                error.LensFull => .internal_error,
                else => .internal_error,
            };
            self.counters.inc_error(status);
            try self.send_error(status);
            return;
        };

        try self.send_ok(&.{});
    }

    fn handle_drop_lens(self: *Self, payload: []const u8) !void {
        if (payload.len != catalog_mod.label_length) {
            self.counters.inc_error(.invalid_payload);
            try self.send_error(.invalid_payload);
            return;
        }

        const label: [catalog_mod.label_length]u8 = payload[0..catalog_mod.label_length].*;

        self.catalog.drop_lens(label) catch {
            self.counters.inc_error(.lens_not_found);
            try self.send_error(.lens_not_found);
            return;
        };

        try self.send_ok(&.{});
    }

    fn handle_query_lens(self: *Self, payload: []const u8) !void {
        if (payload.len != catalog_mod.label_length + 8) {
            self.counters.inc_error(.invalid_payload);
            try self.send_error(.invalid_payload);
            return;
        }

        const label: [catalog_mod.label_length]u8 = payload[0..catalog_mod.label_length].*;
        const timestamp: i64 = std.mem.readInt(i64, payload[catalog_mod.label_length..][0..8], .big);

        const result = self.catalog.query_lens(label, timestamp) catch |err| {
            const status: StatusCode = switch (err) {
                error.LensNotFound => .lens_not_found,
                error.SeriesNotFound => .series_not_found,
                else => .internal_error,
            };
            self.counters.inc_error(status);
            try self.send_error(status);
            return;
        };

        if (result) |value| {
            var response: [9]u8 = undefined;
            response[0] = 1;
            std.mem.writeInt(u64, response[1..9], @bitCast(value), .big);
            try self.send_ok(&response);
        } else {
            try self.send_ok(&[_]u8{0});
        }
    }

    fn handle_compose_lens(self: *Self, payload: []const u8) !void {
        if (payload.len != catalog_mod.label_length * 3) {
            self.counters.inc_error(.invalid_payload);
            try self.send_error(.invalid_payload);
            return;
        }

        var label: [catalog_mod.label_length]u8 = undefined;
        var lens1_label: [catalog_mod.label_length]u8 = undefined;
        var lens2_label: [catalog_mod.label_length]u8 = undefined;

        @memcpy(label[0..catalog_mod.label_length], payload[0..catalog_mod.label_length]);
        @memcpy(lens1_label[0..catalog_mod.label_length], payload[catalog_mod.label_length .. catalog_mod.label_length * 2]);
        @memcpy(lens2_label[0..catalog_mod.label_length], payload[catalog_mod.label_length * 2 ..]);

        self.catalog.compose_lens(label, lens1_label, lens2_label) catch |err| {
            const status: StatusCode = switch (err) {
                error.LensAlreadyExists => .lens_already_exists,
                error.LensNotFound => .lens_not_found,
                error.LensFull => .internal_error,
                else => .internal_error,
            };
            self.counters.inc_error(status);
            try self.send_error(status);
            return;
        };

        try self.send_ok(&.{});
    }

    fn handle_list_lenses(self: *Self, payload: []const u8) !void {
        _ = payload;

        const lenses = self.catalog.list_lenses();
        defer self.catalog.allocator.free(lenses);

        var response = self.catalog.allocator.alloc(u8, lenses.len * catalog_mod.label_length) catch {
            try self.send_error(.internal_error);
            return;
        };
        defer self.catalog.allocator.free(response);

        for (lenses, 0..) |lens_label, i| {
            @memcpy(response[i * catalog_mod.label_length .. (i + 1) * catalog_mod.label_length], &lens_label);
        }

        try self.send_ok(response);
    }

    fn send_ok(self: *Self, payload: []const u8) !void {
        try self.send_response(.ok, payload);
    }

    fn send_error(self: *Self, status: StatusCode) !void {
        try self.send_response(.err, &[_]u8{
            @intFromEnum(status),
        });
    }

    fn send_response(
        self: *Self,
        opcode: Opcode,
        payload: []const u8,
    ) !void {
        std.debug.assert(payload.len <= protocol.payload_length_max);

        var header_buffer: [protocol.header_length]u8 = undefined;
        const header = Header{
            .opcode = opcode,
            .flags = 0,
            .payload_length = @intCast(payload.len),
        };
        header.encode(&header_buffer);

        _ = try self.stream.write(&header_buffer);
        if (payload.len > 0) {
            _ = try self.stream.write(payload);
        }
    }

    fn read_exact(self: *Self, buffer: []u8) !void {
        var filled: usize = 0;
        while (filled < buffer.len) {
            const bytes_read = self.stream.read(
                buffer[filled..],
            ) catch return error.ConnectionClosed;

            if (bytes_read == 0) return error.ConnectionClosed;
            filled += bytes_read;
        }
    }
};
