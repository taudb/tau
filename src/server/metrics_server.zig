//! Prometheus-compatible metrics server.
//!
//! Runs a minimal HTTP responder on a separate port that serves
//! GET /metrics in Prometheus text exposition format. No routing,
//! no request parsing beyond detecting a complete HTTP request.

const std = @import("std");
const config = @import("tau").config;
const catalog_mod = @import("catalog");

const log = std.log.scoped(.metrics);

pub const Counters = struct {
    connections_active: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    connections_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    requests_connect: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    requests_disconnect: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    requests_ping: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    requests_create_series: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    requests_drop_series: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    requests_append: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    requests_query_point: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    requests_create_lens: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    requests_drop_lens: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    requests_query_lens: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    requests_compose_lens: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    requests_list_lenses: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    errors_bad_magic: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors_bad_version: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors_bad_opcode: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors_payload_too_large: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors_not_authenticated: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors_auth_failed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors_series_not_found: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors_series_already_exists: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors_invalid_payload: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors_internal_error: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors_out_of_order: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors_lens_not_found: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors_lens_already_exists: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    start_time_ms: i64 = 0,

    pub fn init() Counters {
        return .{
            .start_time_ms = std.time.milliTimestamp(),
        };
    }

    pub fn inc_request(self: *Counters, opcode: @import("protocol").Opcode) void {
        switch (opcode) {
            .connect => _ = self.requests_connect.fetchAdd(1, .monotonic),
            .disconnect => _ = self.requests_disconnect.fetchAdd(1, .monotonic),
            .ping => _ = self.requests_ping.fetchAdd(1, .monotonic),
            .create_series => _ = self.requests_create_series.fetchAdd(1, .monotonic),
            .drop_series => _ = self.requests_drop_series.fetchAdd(1, .monotonic),
            .append => _ = self.requests_append.fetchAdd(1, .monotonic),
            .query_point => _ = self.requests_query_point.fetchAdd(1, .monotonic),
            .create_lens => _ = self.requests_create_lens.fetchAdd(1, .monotonic),
            .drop_lens => _ = self.requests_drop_lens.fetchAdd(1, .monotonic),
            .query_lens => _ = self.requests_query_lens.fetchAdd(1, .monotonic),
            .compose_lens => _ = self.requests_compose_lens.fetchAdd(1, .monotonic),
            .list_lenses => _ = self.requests_list_lenses.fetchAdd(1, .monotonic),
            else => {},
        }
    }

    pub fn inc_error(self: *Counters, status: @import("protocol").StatusCode) void {
        switch (status) {
            .bad_magic => _ = self.errors_bad_magic.fetchAdd(1, .monotonic),
            .bad_version => _ = self.errors_bad_version.fetchAdd(1, .monotonic),
            .bad_opcode => _ = self.errors_bad_opcode.fetchAdd(1, .monotonic),
            .payload_too_large => _ = self.errors_payload_too_large.fetchAdd(1, .monotonic),
            .not_authenticated => _ = self.errors_not_authenticated.fetchAdd(1, .monotonic),
            .auth_failed => _ = self.errors_auth_failed.fetchAdd(1, .monotonic),
            .series_not_found => _ = self.errors_series_not_found.fetchAdd(1, .monotonic),
            .series_already_exists => _ = self.errors_series_already_exists.fetchAdd(1, .monotonic),
            .invalid_payload => _ = self.errors_invalid_payload.fetchAdd(1, .monotonic),
            .internal_error => _ = self.errors_internal_error.fetchAdd(1, .monotonic),
            .out_of_order => _ = self.errors_out_of_order.fetchAdd(1, .monotonic),
            .lens_not_found => _ = self.errors_lens_not_found.fetchAdd(1, .monotonic),
            .lens_already_exists => _ = self.errors_lens_already_exists.fetchAdd(1, .monotonic),
            .success => {},
        }
    }

    pub fn connection_opened(self: *Counters) void {
        _ = self.connections_active.fetchAdd(1, .monotonic);
        _ = self.connections_total.fetchAdd(1, .monotonic);
    }

    pub fn connection_closed(self: *Counters) void {
        _ = self.connections_active.fetchSub(1, .monotonic);
    }
};

pub fn format_metrics(
    counters: *Counters,
    catalog: *catalog_mod.Catalog,
    buf: []u8,
) ![]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const w = stream.writer();

    try w.writeAll("# HELP tau_connections_active Current open connections.\n");
    try w.writeAll("# TYPE tau_connections_active gauge\n");
    try std.fmt.format(w, "tau_connections_active {d}\n", .{
        counters.connections_active.load(.monotonic),
    });

    try w.writeAll("# HELP tau_connections_total Total accepted connections.\n");
    try w.writeAll("# TYPE tau_connections_total counter\n");
    try std.fmt.format(w, "tau_connections_total {d}\n", .{
        counters.connections_total.load(.monotonic),
    });

    try w.writeAll("# HELP tau_requests_total Total requests by opcode.\n");
    try w.writeAll("# TYPE tau_requests_total counter\n");
    const req_fields = .{
        .{ "connect", &counters.requests_connect },
        .{ "disconnect", &counters.requests_disconnect },
        .{ "ping", &counters.requests_ping },
        .{ "create_series", &counters.requests_create_series },
        .{ "drop_series", &counters.requests_drop_series },
        .{ "append", &counters.requests_append },
        .{ "query_point", &counters.requests_query_point },
        .{ "create_lens", &counters.requests_create_lens },
        .{ "drop_lens", &counters.requests_drop_lens },
        .{ "query_lens", &counters.requests_query_lens },
        .{ "compose_lens", &counters.requests_compose_lens },
        .{ "list_lenses", &counters.requests_list_lenses },
    };
    inline for (req_fields) |entry| {
        try std.fmt.format(w, "tau_requests_total{{op=\"{s}\"}} {d}\n", .{
            entry[0],
            entry[1].load(.monotonic),
        });
    }

    try w.writeAll("# HELP tau_errors_total Error responses by status code.\n");
    try w.writeAll("# TYPE tau_errors_total counter\n");
    const err_fields = .{
        .{ "bad_magic", &counters.errors_bad_magic },
        .{ "bad_version", &counters.errors_bad_version },
        .{ "bad_opcode", &counters.errors_bad_opcode },
        .{ "payload_too_large", &counters.errors_payload_too_large },
        .{ "not_authenticated", &counters.errors_not_authenticated },
        .{ "auth_failed", &counters.errors_auth_failed },
        .{ "series_not_found", &counters.errors_series_not_found },
        .{ "series_already_exists", &counters.errors_series_already_exists },
        .{ "invalid_payload", &counters.errors_invalid_payload },
        .{ "internal_error", &counters.errors_internal_error },
        .{ "out_of_order", &counters.errors_out_of_order },
        .{ "lens_not_found", &counters.errors_lens_not_found },
        .{ "lens_already_exists", &counters.errors_lens_already_exists },
    };
    inline for (err_fields) |entry| {
        try std.fmt.format(w, "tau_errors_total{{status=\"{s}\"}} {d}\n", .{
            entry[0],
            entry[1].load(.monotonic),
        });
    }

    // Catalog metrics (read under existing RwLock).
    catalog.lock.lockShared();
    const series_count = catalog.actor_map.count();
    
    // Actor pool metrics
    var actor_pool_size: u32 = 0;
    var messages_processed: u64 = 0;
    var worker_iterations: u64 = 0;
    var worker_idle_iterations: u64 = 0;
    
    if (catalog.actor_pool) |*pool| {
        const pool_stats = pool.get_stats();
        actor_pool_size = pool_stats.pool_size;
        messages_processed = pool_stats.messages_processed;
        worker_iterations = pool_stats.worker_iterations;
        worker_idle_iterations = pool_stats.worker_idle_iterations;
    }
    
    // Mailbox metrics (aggregate across all actors)
    var total_mailbox_messages_sent: u64 = 0;
    var total_mailbox_messages_received: u64 = 0;
    var total_mailbox_send_failures: u64 = 0;
    var total_mailbox_queue_depth: u64 = 0;
    var mailboxes_full: u32 = 0;
    var mailboxes_empty: u32 = 0;
    
    var actor_iterator = catalog.actor_map.iterator();
    while (actor_iterator.next()) |entry| {
        const actor = entry.value_ptr.*;
        if (!actor.is_alive.load(.monotonic)) continue;
        
        total_mailbox_messages_sent += actor.mailbox.messages_sent.load(.monotonic);
        total_mailbox_messages_received += actor.mailbox.messages_received.load(.monotonic);
        total_mailbox_send_failures += actor.mailbox.send_failures.load(.monotonic);
        
        const queue_depth = actor.mailbox.queue_depth();
        total_mailbox_queue_depth += queue_depth;
        
        if (queue_depth == actor.mailbox.capacity) {
            mailboxes_full += 1;
        }
        if (queue_depth == 0) {
            mailboxes_empty += 1;
        }
    }
    
    catalog.lock.unlockShared();

    try w.writeAll("# HELP tau_series_count Number of live series.\n");
    try w.writeAll("# TYPE tau_series_count gauge\n");
    try std.fmt.format(w, "tau_series_count {d}\n", .{series_count});
    
    // Actor pool metrics
    try w.writeAll("# HELP tau_actor_pool_size Number of worker threads in actor pool.\n");
    try w.writeAll("# TYPE tau_actor_pool_size gauge\n");
    try std.fmt.format(w, "tau_actor_pool_size {d}\n", .{actor_pool_size});
    
    try w.writeAll("# HELP tau_actor_messages_processed_total Total messages processed by actor pool.\n");
    try w.writeAll("# TYPE tau_actor_messages_processed_total counter\n");
    try std.fmt.format(w, "tau_actor_messages_processed_total {d}\n", .{messages_processed});
    
    try w.writeAll("# HELP tau_actor_worker_iterations_total Total worker loop iterations.\n");
    try w.writeAll("# TYPE tau_actor_worker_iterations_total counter\n");
    try std.fmt.format(w, "tau_actor_worker_iterations_total {d}\n", .{worker_iterations});
    
    try w.writeAll("# HELP tau_actor_worker_idle_iterations_total Total idle worker iterations.\n");
    try w.writeAll("# TYPE tau_actor_worker_idle_iterations_total counter\n");
    try std.fmt.format(w, "tau_actor_worker_idle_iterations_total {d}\n", .{worker_idle_iterations});
    
    // Mailbox metrics
    try w.writeAll("# HELP tau_mailbox_messages_sent_total Total messages sent to mailboxes.\n");
    try w.writeAll("# TYPE tau_mailbox_messages_sent_total counter\n");
    try std.fmt.format(w, "tau_mailbox_messages_sent_total {d}\n", .{total_mailbox_messages_sent});
    
    try w.writeAll("# HELP tau_mailbox_messages_received_total Total messages received from mailboxes.\n");
    try w.writeAll("# TYPE tau_mailbox_messages_received_total counter\n");
    try std.fmt.format(w, "tau_mailbox_messages_received_total {d}\n", .{total_mailbox_messages_received});
    
    try w.writeAll("# HELP tau_mailbox_send_failures_total Total mailbox send failures (mailbox full).\n");
    try w.writeAll("# TYPE tau_mailbox_send_failures_total counter\n");
    try std.fmt.format(w, "tau_mailbox_send_failures_total {d}\n", .{total_mailbox_send_failures});
    
    try w.writeAll("# HELP tau_mailbox_queue_depth_total Sum of all mailbox queue depths.\n");
    try w.writeAll("# TYPE tau_mailbox_queue_depth_total gauge\n");
    try std.fmt.format(w, "tau_mailbox_queue_depth_total {d}\n", .{total_mailbox_queue_depth});
    
    try w.writeAll("# HELP tau_mailbox_full_count Number of mailboxes that are full.\n");
    try w.writeAll("# TYPE tau_mailbox_full_count gauge\n");
    try std.fmt.format(w, "tau_mailbox_full_count {d}\n", .{mailboxes_full});
    
    try w.writeAll("# HELP tau_mailbox_empty_count Number of mailboxes that are empty.\n");
    try w.writeAll("# TYPE tau_mailbox_empty_count gauge\n");
    try std.fmt.format(w, "tau_mailbox_empty_count {d}\n", .{mailboxes_empty});

    // Process metrics.
    const uptime_ms = std.time.milliTimestamp() - counters.start_time_ms;
    const uptime_s: f64 = @as(f64, @floatFromInt(uptime_ms)) / 1000.0;

    try w.writeAll("# HELP tau_uptime_seconds Time since server start.\n");
    try w.writeAll("# TYPE tau_uptime_seconds gauge\n");
    try std.fmt.format(w, "tau_uptime_seconds {d:.3}\n", .{uptime_s});

    return stream.getWritten();
}

pub const MetricsServer = struct {
    counters: *Counters,
    catalog: *catalog_mod.Catalog,
    server: ?std.net.Server,
    thread: ?std.Thread,

    const Self = @This();

    pub fn init(
        counters: *Counters,
        catalog: *catalog_mod.Catalog,
    ) Self {
        return .{
            .counters = counters,
            .catalog = catalog,
            .server = null,
            .thread = null,
        };
    }

    pub fn start(self: *Self) !void {
        const address = std.net.Address.initIp4(
            config.metrics.address,
            config.metrics.port,
        );

        self.server = std.net.Address.listen(
            address,
            .{ .reuse_address = true },
        ) catch |err| {
            log.err("metrics bind failed: {s}", .{@errorName(err)});
            return err;
        };

        self.thread = try std.Thread.spawn(.{}, accept_loop, .{self});

        log.info("metrics listening on port {d}", .{config.metrics.port});
    }

    pub fn deinit(self: *Self) void {
        if (self.server) |*s| {
            s.deinit();
        }
    }

    fn accept_loop(self: *Self) void {
        while (true) {
            const connection = self.server.?.accept() catch |err| {
                log.err("metrics accept failed: {s}", .{@errorName(err)});
                continue;
            };
            self.handle_connection(connection.stream);
        }
    }

    fn handle_connection(self: *Self, stream: std.net.Stream) void {
        defer stream.close();

        var req_buf: [1024]u8 = undefined;
        var filled: usize = 0;
        while (filled < req_buf.len) {
            const n = stream.read(req_buf[filled..]) catch return;
            if (n == 0) return;
            filled += n;

            if (std.mem.indexOf(u8, req_buf[0..filled], "\r\n\r\n") != null) break;
        }

        var body_buf: [16384]u8 = undefined;
        const body = format_metrics(
            self.counters,
            self.catalog,
            &body_buf,
        ) catch {
            const err_resp = "HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\n\r\n";
            _ = stream.write(err_resp) catch {};
            return;
        };

        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(
            &header_buf,
            "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/plain; version=0.0.4\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Connection: close\r\n" ++
                "\r\n",
            .{body.len},
        ) catch return;

        _ = stream.write(header) catch return;
        _ = stream.write(body) catch return;
    }
};

const testing = std.testing;

test "Counters.init sets start time" {
    const counters = Counters.init();
    try testing.expect(counters.start_time_ms > 0);
}

test "Counters.inc_request increments correct counter" {
    var counters = Counters.init();
    counters.inc_request(.append);
    counters.inc_request(.append);
    counters.inc_request(.ping);

    try testing.expectEqual(@as(u64, 2), counters.requests_append.load(.monotonic));
    try testing.expectEqual(@as(u64, 1), counters.requests_ping.load(.monotonic));
    try testing.expectEqual(@as(u64, 0), counters.requests_connect.load(.monotonic));
}

test "Counters.inc_error increments correct counter" {
    var counters = Counters.init();

    counters.inc_error(.auth_failed);
    counters.inc_error(.series_not_found);
    counters.inc_error(.series_not_found);

    try testing.expectEqual(@as(u64, 1), counters.errors_auth_failed.load(.monotonic));
    try testing.expectEqual(@as(u64, 2), counters.errors_series_not_found.load(.monotonic));
    try testing.expectEqual(@as(u64, 0), counters.errors_bad_magic.load(.monotonic));
}

test "Counters.connection_opened and connection_closed" {
    var counters = Counters.init();

    counters.connection_opened();
    counters.connection_opened();
    try testing.expectEqual(@as(u64, 2), counters.connections_active.load(.monotonic));
    try testing.expectEqual(@as(u64, 2), counters.connections_total.load(.monotonic));

    counters.connection_closed();
    try testing.expectEqual(@as(u64, 1), counters.connections_active.load(.monotonic));
    try testing.expectEqual(@as(u64, 2), counters.connections_total.load(.monotonic));
}

test "format_metrics produces valid Prometheus text" {
    var counters = Counters.init();
    var catalog = catalog_mod.Catalog.init(testing.allocator);
    defer catalog.deinit();

    counters.inc_request(.append);
    counters.inc_error(.auth_failed);
    counters.connection_opened();

    var buf: [16384]u8 = undefined;
    const output = try format_metrics(&counters, &catalog, &buf);

    try testing.expect(std.mem.indexOf(u8, output, "tau_connections_active 1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "tau_connections_total 1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "tau_requests_total{op=\"append\"} 1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "tau_errors_total{status=\"auth_failed\"} 1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "tau_series_count 0") != null);
    try testing.expect(std.mem.indexOf(u8, output, "tau_uptime_seconds") != null);
    try testing.expect(std.mem.indexOf(u8, output, "# TYPE tau_connections_active gauge") != null);
    try testing.expect(std.mem.indexOf(u8, output, "# TYPE tau_requests_total counter") != null);
}
