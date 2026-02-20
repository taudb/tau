//! TCP listener. Accepts connections and spawns a handler
//! thread per client.

const std = @import("std");
const handler_mod = @import("handler.zig");
const catalog_mod = @import("catalog");
const auth_mod = @import("auth.zig");
const metrics_mod = @import("metrics");

const log = std.log.scoped(.listener);

pub const Config = struct {
    port: u16,
    address: [4]u8,
    certificate: [auth_mod.certificate_length]u8,
};

pub const Listener = struct {
    config: Config,
    catalog: catalog_mod.Catalog,
    server: ?std.net.Server,
    counters: metrics_mod.Counters,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        config: Config,
    ) Self {
        return .{
            .config = config,
            .catalog = catalog_mod.Catalog.init(allocator),
            .server = null,
            .counters = metrics_mod.Counters.init(),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.server) |*server| {
            server.deinit();
        }
        self.catalog.deinit();
    }

    pub fn start(self: *Self) !void {
        // Start the actor pool now that the Catalog is at its final
        // memory address (self is a stable pointer from main's stack).
        self.catalog.start();

        const address = std.net.Address.initIp4(
            self.config.address,
            self.config.port,
        );

        self.server = std.net.Address.listen(
            address,
            .{ .reuse_address = true },
        ) catch |listen_error| {
            log.err(
                "failed to bind: {s}",
                .{@errorName(listen_error)},
            );
            return listen_error;
        };

        log.info(
            "listening on port {d}",
            .{self.config.port},
        );

        self.accept_loop();
    }

    fn accept_loop(self: *Self) void {
        while (true) {
            const connection = self.server.?.accept() catch |accept_error| {
                log.err(
                    "accept failed: {s}",
                    .{@errorName(accept_error)},
                );
                continue;
            };

            const thread = std.Thread.spawn(
                .{},
                handle_connection,
                .{
                    self,
                    connection.stream,
                    connection.address,
                },
            ) catch |spawn_error| {
                log.err(
                    "thread spawn failed: {s}",
                    .{@errorName(spawn_error)},
                );
                connection.stream.close();
                continue;
            };
            thread.detach();
        }
    }

    fn handle_connection(
        self: *Self,
        stream: std.net.Stream,
        address: std.net.Address,
    ) void {
        self.counters.connection_opened();
        defer self.counters.connection_closed();

        log.info("connection accepted", .{});

        var handler = handler_mod.Handler.init(
            stream,
            address,
            &self.catalog,
            &self.config.certificate,
            &self.counters,
        );
        handler.run();

        log.info("connection closed", .{});
    }
};
