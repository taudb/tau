//! Actor-based concurrency model for series operations.
//!
//! Each series is an actor with its own mailbox. Messages are processed
//! sequentially per actor, eliminating locks on series data. Cross-series
//! operations proceed in full parallel via a worker thread pool.

const std = @import("std");
const tau = @import("tau");
const tau_entities = tau.entities;
const tau_config = tau.config;
const file_backend_mod = tau.file_backend;

const Timestamp = tau_entities.Timestamp;
const Series = tau_entities.Series(f64);
const FileBackend = file_backend_mod.FileBackedSegment(f64);
const backend = tau_config.storage.default_backend;

const log = std.log.scoped(.actor);

// Configuration constants
const mailbox_capacity: u32 = tau_config.server.mailbox_capacity;

fn get_actor_pool_size() u32 {
    if (tau_config.server.actor_pool_size == 0) {
        return @as(u32, @intCast(std.Thread.getCpuCount() catch 8));
    } else {
        return tau_config.server.actor_pool_size;
    }
}

// ResponseSlot: Futex-based one-shot channel for synchronous responses

const ResultUnion = union(enum) {
    ok: void,
    value: f64,
    err: ResponseSlot.Error,
};

pub const ResponseSlot = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(@intFromEnum(State.waiting)),
    result: ResultUnion = .{ .ok = {} },

    const State = enum(u32) {
        waiting = 0,
        ready = 1,
        consumed = 2,
    };

    pub const Error = error{
        SeriesNotFound,
        OutOfOrder,
        OutOfMemory,
        CatalogFull,
        SeriesAlreadyExists,
    };

    pub fn init() ResponseSlot {
        return ResponseSlot{};
    }

    /// Block until result is ready, then consume it.
    pub fn wait(self: *ResponseSlot) Error!?f64 {
        // Wait for ready state
        while (true) {
            const current_raw = self.state.load(.acquire);
            const current = @as(State, @enumFromInt(current_raw));
            if (current == .ready) break;
            if (current == .consumed) {
                std.debug.panic("ResponseSlot.wait called twice", .{});
            }
            std.Thread.Futex.wait(&self.state, @intFromEnum(State.waiting));
        }

        // Consume result
        self.state.store(@intFromEnum(State.consumed), .release);

        switch (self.result) {
            .ok => return null,
            .value => |v| return v,
            .err => |e| return e,
        }
    }

    /// Write result and wake waiting thread.
    pub fn complete(self: *ResponseSlot, result: ResultUnion) void {
        self.result = result;
        self.state.store(@intFromEnum(State.ready), .release);
        std.Thread.Futex.wake(&self.state, 1);
    }

    /// Check if the result is ready without blocking.
    pub fn is_ready(self: *const ResponseSlot) bool {
        const current_raw = self.state.load(.acquire);
        const current = @as(State, @enumFromInt(current_raw));
        return current == .ready;
    }
};

// Message: tagged union for actor messages

pub const Message = union(enum) {
    append: struct {
        timestamp: Timestamp,
        value: f64,
        response: *ResponseSlot,
    },
    query_point: struct {
        timestamp: Timestamp,
        response: *ResponseSlot,
    },
    create: struct {
        response: *ResponseSlot,
    },
    drop: struct {
        response: *ResponseSlot,
    },

    pub fn process(self: Message, actor: *SeriesActor) void {
        switch (self) {
            .append => |msg| {
                const result = if (backend == .segment)
                    actor.series.append(msg.timestamp, msg.value)
                else
                    actor.file_backend.?.append(msg.timestamp, msg.value);

                if (result) |_| {
                    msg.response.complete(.{ .ok = {} });
                } else |err| {
                    const actor_err = switch (err) {
                        error.OutOfOrder => ResponseSlot.Error.OutOfOrder,
                        else => ResponseSlot.Error.OutOfMemory,
                    };
                    msg.response.complete(.{ .err = actor_err });
                }
            },
            .query_point => |msg| {
                const value = if (backend == .segment)
                    actor.series.at(msg.timestamp)
                else
                    actor.file_backend.?.at(msg.timestamp);

                if (value) |v| {
                    msg.response.complete(.{ .value = v });
                } else {
                    msg.response.complete(.{ .ok = {} });
                }
            },
            .create => |msg| {
                // Create is handled by Catalog, not actor
                msg.response.complete(.{ .ok = {} });
            },
            .drop => |msg| {
                // Drop is handled by Catalog, not actor
                msg.response.complete(.{ .ok = {} });
            },
        }
    }
};

// Mailbox: bounded MPSC ring buffer (mutex-protected)

pub const Mailbox = struct {
    messages: []Message,
    head: u32 = 0,
    tail: u32 = 0,
    capacity: u32,
    lock: std.Thread.Mutex = .{},
    messages_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    messages_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    send_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const messages = try allocator.alloc(Message, mailbox_capacity);
        return Self{
            .messages = messages,
            .head = 0,
            .tail = 0,
            .capacity = mailbox_capacity,
            .lock = .{},
            .messages_sent = std.atomic.Value(u64).init(0),
            .messages_received = std.atomic.Value(u64).init(0),
            .send_failures = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.messages);
        self.* = undefined;
    }

    /// Try to enqueue a message.
    /// Returns true if enqueued, false if mailbox full.
    pub fn try_send(self: *Self, message: Message) bool {
        self.lock.lock();
        defer self.lock.unlock();

        const tail = self.tail;
        const head = self.head;
        const next_tail = (tail + 1) % self.capacity;

        // Check if full
        if (next_tail == head) {
            _ = self.send_failures.fetchAdd(1, .monotonic);
            return false;
        }

        // Write message
        self.messages[tail] = message;
        self.tail = next_tail;
        _ = self.messages_sent.fetchAdd(1, .monotonic);

        return true;
    }

    /// Try to dequeue a message.
    /// Returns null if mailbox empty.
    pub fn try_recv(self: *Self) ?Message {
        self.lock.lock();
        defer self.lock.unlock();

        const head = self.head;
        const tail = self.tail;

        // Check if empty
        if (head == tail) {
            return null;
        }

        // Read message
        const message = self.messages[head];
        const next_head = (head + 1) % self.capacity;
        self.head = next_head;
        _ = self.messages_received.fetchAdd(1, .monotonic);

        return message;
    }
    
    /// Get current queue depth (number of pending messages).
    pub fn queue_depth(self: *Self) u32 {
        self.lock.lock();
        defer self.lock.unlock();

        const head = self.head;
        const tail = self.tail;
        if (tail >= head) {
            return tail - head;
        } else {
            return (self.capacity - head) + tail;
        }
    }

    /// Check if mailbox is empty.
    pub fn is_empty(self: *Self) bool {
        return self.queue_depth() == 0;
    }
};

// SeriesActor: owns series data and mailbox

pub const SeriesActor = struct {
    label: [32]u8,
    mailbox: Mailbox,
    series: Series,
    file_backend: ?*FileBackend,
    data_dir: ?std.fs.Dir,
    allocator: std.mem.Allocator,
    is_alive: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    processing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        label: [32]u8,
        data_dir: ?std.fs.Dir,
    ) !Self {
        const mailbox = try Mailbox.init(allocator);

        if (backend == .segment) {
            const series = Series.init(
                allocator,
                label,
                tau_config.storage.segment_capacity_default,
            );
            return Self{
                .label = label,
                .mailbox = mailbox,
                .series = series,
                .file_backend = null,
                .data_dir = null,
                .allocator = allocator,
            };
        } else {
            const dir = data_dir orelse return error.OutOfMemory;
            const fb = try allocator.create(FileBackend);
            fb.* = try FileBackend.init(
                allocator,
                dir,
                label,
                tau_config.storage.segment_capacity_default,
            );
            return Self{
                .label = label,
                .mailbox = mailbox,
                .series = undefined,
                .file_backend = fb,
                .data_dir = null,
                .allocator = allocator,
            };
        }
    }

    pub fn deinit(self: *Self) void {
        self.is_alive.store(false, .release);
        self.mailbox.deinit(self.allocator);
        if (backend == .segment) {
            self.series.deinit();
        } else {
            if (self.file_backend) |fb| {
                fb.deinit();
                self.allocator.destroy(fb);
            }
        }
        self.* = undefined;
    }

    /// Prevent new processing and wait for in-flight processing to finish.
    pub fn stop(self: *Self) void {
        self.is_alive.store(false, .release);
        while (self.processing.cmpxchgStrong(false, true, .acq_rel, .acquire)) |_| {
            std.Thread.yield() catch {};
        }
    }

    /// Process one message from mailbox (non-blocking).
    /// Returns true if a message was processed, false if mailbox empty.
    pub fn process_one(self: *Self) bool {
        if (self.processing.cmpxchgStrong(false, true, .acq_rel, .acquire)) |_| {
            return false;
        }
        defer self.processing.store(false, .release);

        const message = self.mailbox.try_recv() orelse return false;
        message.process(self);
        return true;
    }
};

// ActorPool: worker thread pool

pub const ActorPool = struct {
    allocator: std.mem.Allocator,
    workers: []std.Thread,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    actors: *std.AutoArrayHashMapUnmanaged([32]u8, *SeriesActor),
    lock: *std.Thread.RwLock,
    messages_processed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    worker_iterations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    worker_idle_iterations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        actors: *std.AutoArrayHashMapUnmanaged([32]u8, *SeriesActor),
        lock: *std.Thread.RwLock,
    ) Self {
        return Self{
            .allocator = allocator,
            .workers = undefined,
            .should_stop = std.atomic.Value(bool).init(false),
            .actors = actors,
            .lock = lock,
        };
    }

    pub fn deinit(self: *Self) void {
        self.should_stop.store(true, .release);

        // Wake all workers
        for (self.workers) |*worker| {
            worker.join();
        }
        self.allocator.free(self.workers);
        self.* = undefined;
    }

    pub fn start(self: *Self) !void {
        const pool_size = get_actor_pool_size();
        self.workers = try self.allocator.alloc(std.Thread, pool_size);
        errdefer self.allocator.free(self.workers);

        for (0..pool_size) |i| {
            self.workers[i] = try std.Thread.spawn(.{}, worker_loop, .{self});
        }

        log.info("actor pool started with {d} workers", .{pool_size});
    }

    fn worker_loop(pool: *Self) void {
        while (!pool.should_stop.load(.acquire)) {
            _ = pool.worker_iterations.fetchAdd(1, .monotonic);
            var processed_any = false;

            // Iterate over all actors and process messages
            pool.lock.lockShared();
            var iterator = pool.actors.iterator();
            while (iterator.next()) |entry| {
                const actor = entry.value_ptr.*;
                if (!actor.is_alive.load(.acquire)) continue;

                if (actor.process_one()) {
                    processed_any = true;
                    _ = pool.messages_processed.fetchAdd(1, .monotonic);
                }
            }
            pool.lock.unlockShared();

            // If no work, sleep briefly to avoid busy-waiting
            if (!processed_any) {
                _ = pool.worker_idle_iterations.fetchAdd(1, .monotonic);
                std.Thread.sleep(1000); // 1 microsecond
            }
        }
    }
    
    /// Get actor pool statistics.
    pub fn get_stats(self: *const Self) struct {
        pool_size: u32,
        messages_processed: u64,
        worker_iterations: u64,
        worker_idle_iterations: u64,
    } {
        return .{
            .pool_size = @as(u32, @intCast(self.workers.len)),
            .messages_processed = self.messages_processed.load(.monotonic),
            .worker_iterations = self.worker_iterations.load(.monotonic),
            .worker_idle_iterations = self.worker_idle_iterations.load(.monotonic),
        };
    }
};

// Tests

const testing = std.testing;

test "ResponseSlot.wait blocks until complete" {
    var slot = ResponseSlot.init();
    var result: ?f64 = undefined;
    var done = std.atomic.Value(bool).init(false);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *ResponseSlot, d: *std.atomic.Value(bool)) void {
            std.time.sleep(10_000_000); // 10ms
            s.complete(.{ .value = 42.0 });
            d.store(true, .release);
        }
    }.run, .{ &slot, &done });

    result = try slot.wait();
    try testing.expectEqual(@as(?f64, 42.0), result);
    try testing.expect(done.load(.acquire));

    thread.join();
}

test "Mailbox.try_send and try_recv" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mailbox = try Mailbox.init(allocator);
    defer mailbox.deinit(allocator);

    var slot = ResponseSlot.init();
    const msg = Message{ .append = .{
        .timestamp = 100,
        .value = 42.0,
        .response = &slot,
    } };

    try testing.expect(mailbox.try_send(msg));
    try testing.expect(!mailbox.is_empty());

    const received = mailbox.try_recv();
    try testing.expect(received != null);
    try testing.expect(mailbox.is_empty());
}

test "SeriesActor processes messages" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const label = [_]u8{0} ** 32;
    var actor = try SeriesActor.init(allocator, label, null);
    defer actor.deinit();

    var slot = ResponseSlot.init();
    const msg = Message{ .append = .{
        .timestamp = 100,
        .value = 42.0,
        .response = &slot,
    } };

    try testing.expect(actor.mailbox.try_send(msg));
    try testing.expect(actor.process_one());
    const result = try slot.wait();
    try testing.expectEqual(@as(?f64, null), result);
}
