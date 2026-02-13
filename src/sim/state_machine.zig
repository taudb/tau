//! State machine wrapper for the Tau temporal database under simulation.

const std = @import("std");
const assert = std.debug.assert;

const tau = @import("tau");
const config = tau.config;
const Series = tau.entities.Series;
const Timestamp = tau.entities.Timestamp;
const TimeDomain = tau.entities.TimeDomain;

const file_backend_mod = tau.file_backend;
const backend = config.storage.default_backend;

const Clock = @import("clock.zig").Clock;
const FaultInjector = @import("faults.zig").FaultInjector;
const StorageFault = @import("faults.zig").StorageFault;
const PRNG = @import("prng.zig").PRNG;

const log = std.log.scoped(.state_machine);

// Types

/// Operation types for the state machine.
pub const Operation = enum(u8) {
    append,
    lookup,
    verify_domain,
    verify_count,
    verify_invariants,
    noop,
};

/// Result of applying an operation.
pub const OpResult = enum(u8) {
    success,
    error_out_of_order,
    error_segment_full,
    error_fault_injected,
    error_invariant_violated,
    skipped,
};

/// A recorded operation for replay and verification.
pub const OpRecord = struct {
    tick: u64,
    timestamp: Timestamp,
    operation: Operation,
    result: OpResult,
    value_before: ?i64,
    value_after: ?i64,
};

// State Machine

/// File backend type alias for the file-backed backend.
const FileBackend = file_backend_mod.FileBackedSegment(i64);

/// State machine wrapping a Series(i64) or FileBackedSegment(i64) for simulation testing.
pub const StateMachine = struct {
    // Configuration Constants (from config.zig)

    const segment_capacity: u32 = config.server.default_segment_capacity;
    const history_capacity: u32 = config.simulation.history_capacity;
    const shadow_capacity: u32 = config.simulation.shadow_capacity;
    const label = [_]u8{ 's', 'i', 'm' } ++ ([_]u8{0} ** 29);

    // Fields

    /// The series under test (segment backend).
    series: Series(i64),
    /// The file backend under test (file backend).
    file_backend_ptr: ?*FileBackend,
    /// Temporary directory for file-backed storage isolation.
    tmp_dir: ?std.testing.TmpDir,
    /// Allocator for file backend lifecycle.
    allocator: std.mem.Allocator,

    /// Virtual clock.
    clock: *Clock,

    /// Fault injector.
    faults: *FaultInjector,

    /// Shadow state for verification.
    shadow: ShadowState,

    /// Operation history.
    history: OpHistory,

    /// Statistics.
    stats: Stats,

    // Shadow State

    /// Shadow state for verification - stores expected values.
    const ShadowState = struct {
        timestamps: []Timestamp,
        values: []i64,
        count: u32,
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator) !ShadowState {
            const timestamps = try allocator.alloc(Timestamp, shadow_capacity);
            errdefer allocator.free(timestamps);

            const values = try allocator.alloc(i64, shadow_capacity);

            return .{
                .timestamps = timestamps,
                .values = values,
                .count = 0,
                .allocator = allocator,
            };
        }

        fn deinit(self: *ShadowState) void {
            self.allocator.free(self.timestamps);
            self.allocator.free(self.values);
            self.* = undefined;
        }

        fn append(self: *ShadowState, ts: Timestamp, val: i64) !void {
            // Assert precondition.
            assert(self.count < shadow_capacity);

            // Assert monotonic timestamps.
            if (self.count > 0) {
                assert(ts > self.timestamps[self.count - 1]);
            }

            self.timestamps[self.count] = ts;
            self.values[self.count] = val;
            self.count += 1;

            // Assert postcondition.
            assert(self.count <= shadow_capacity);
        }

        fn lookup(self: *const ShadowState, ts: Timestamp) ?i64 {
            if (self.count == 0) return null;

            // Binary search.
            var lo: u32 = 0;
            var hi: u32 = self.count;

            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (self.timestamps[mid] == ts) {
                    return self.values[mid];
                }
                if (self.timestamps[mid] < ts) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return null;
        }

        fn domain(self: *const ShadowState) TimeDomain {
            if (self.count == 0) return TimeDomain.empty();
            return .{
                .start = self.timestamps[0],
                .end = self.timestamps[self.count - 1],
            };
        }
    };

    // Operation History

    /// Ring buffer for operation history.
    const OpHistory = struct {
        records: [history_capacity]OpRecord,
        head: u32,
        len: u32,

        fn init() OpHistory {
            return .{
                .records = undefined,
                .head = 0,
                .len = 0,
            };
        }

        fn push(self: *OpHistory, record: OpRecord) void {
            self.records[self.head] = record;
            self.head = (self.head + 1) % history_capacity;
            if (self.len < history_capacity) {
                self.len += 1;
            }

            // Assert invariants.
            assert(self.head < history_capacity);
            assert(self.len <= history_capacity);
        }

        fn last(self: *const OpHistory) ?OpRecord {
            if (self.len == 0) return null;
            const idx = if (self.head == 0) history_capacity - 1 else self.head - 1;
            return self.records[idx];
        }
    };

    // Statistics

    pub const Stats = struct {
        operations_total: u64 = 0,
        operations_success: u64 = 0,
        operations_error: u64 = 0,
        operations_skipped: u64 = 0,
        appends: u64 = 0,
        lookups: u64 = 0,
        invariant_checks: u64 = 0,
        invariant_violations: u64 = 0,
        faults_encountered: u64 = 0,
    };

    // Lifecycle

    /// Create a new state machine.
    pub fn init(
        allocator: std.mem.Allocator,
        clock: *Clock,
        faults_injector: *FaultInjector,
    ) !StateMachine {
        // Assert preconditions.
        assert(clock.now() >= 0);

        const shadow = try ShadowState.init(allocator);

        var self = StateMachine{
            .series = Series(i64).init(allocator, label, segment_capacity),
            .file_backend_ptr = null,
            .tmp_dir = null,
            .allocator = allocator,
            .clock = clock,
            .faults = faults_injector,
            .shadow = shadow,
            .history = OpHistory.init(),
            .stats = Stats{},
        };

        // Initialise file backend if selected.
        if (backend == .file) {
            self.tmp_dir = std.testing.tmpDir(.{});
            const fb = allocator.create(FileBackend) catch return error.OutOfMemory;
            fb.* = FileBackend.init(allocator, self.tmp_dir.?.dir, label, segment_capacity) catch {
                allocator.destroy(fb);
                return error.OutOfMemory;
            };
            self.file_backend_ptr = fb;
        }

        // Assert postconditions.
        assert(self.shadow.count == 0);
        assert(self.history.len == 0);
        assert(self.stats.operations_total == 0);

        return self;
    }

    /// Cleanup resources.
    pub fn deinit(self: *StateMachine) void {
        if (backend == .file) {
            if (self.file_backend_ptr) |fb| {
                fb.deinit();
                self.allocator.destroy(fb);
            }
            if (self.tmp_dir) |*td| {
                td.cleanup();
            }
        }
        self.series.deinit();
        self.shadow.deinit();
        self.* = undefined;
    }

    // Operations

    /// Apply an append operation.
    pub fn apply_append(self: *StateMachine, timestamp: Timestamp, value: i64) OpResult {
        // Assert precondition: timestamp is reasonable.
        assert(timestamp >= std.math.minInt(i64) / 2);
        assert(timestamp <= std.math.maxInt(i64) / 2);

        const tick = self.clock.ticks();
        self.stats.operations_total += 1;
        self.stats.appends += 1;

        // Check for fault injection.
        const fault = self.faults.maybe_storage_write_fault();
        if (fault != .none) {
            self.stats.faults_encountered += 1;
            self.stats.operations_error += 1;

            self.history.push(.{
                .tick = tick,
                .timestamp = timestamp,
                .operation = .append,
                .result = .error_fault_injected,
                .value_before = null,
                .value_after = null,
            });

            return .error_fault_injected;
        }

        // Apply to real storage backend.
        if (backend == .segment) {
            self.series.append(timestamp, value) catch |err| {
                self.stats.operations_error += 1;

                const result: OpResult = switch (err) {
                    error.OutOfOrder => .error_out_of_order,
                    error.SegmentFull => .error_segment_full,
                    else => .error_invariant_violated,
                };

                self.history.push(.{
                    .tick = tick,
                    .timestamp = timestamp,
                    .operation = .append,
                    .result = result,
                    .value_before = null,
                    .value_after = null,
                });

                return result;
            };
        } else if (backend == .file) {
            self.file_backend_ptr.?.append(timestamp, value) catch |err| {
                self.stats.operations_error += 1;

                const result: OpResult = switch (err) {
                    error.OutOfOrder => .error_out_of_order,
                    error.SegmentFull => .error_segment_full,
                    else => .error_invariant_violated,
                };

                self.history.push(.{
                    .tick = tick,
                    .timestamp = timestamp,
                    .operation = .append,
                    .result = result,
                    .value_before = null,
                    .value_after = null,
                });

                return result;
            };
        }

        // Apply to shadow state.
        self.shadow.append(timestamp, value) catch {
            self.stats.operations_skipped += 1;
            return .skipped;
        };

        self.stats.operations_success += 1;

        self.history.push(.{
            .tick = tick,
            .timestamp = timestamp,
            .operation = .append,
            .result = .success,
            .value_before = null,
            .value_after = value,
        });

        // Assert postcondition: storage and shadow agree.
        const storage_count = if (backend == .segment) self.series.count() else self.file_backend_ptr.?.count;
        assert(storage_count == self.shadow.count);

        return .success;
    }

    /// Apply a lookup operation and verify against shadow.
    pub fn apply_lookup(self: *StateMachine, timestamp: Timestamp) OpResult {
        const tick = self.clock.ticks();
        self.stats.operations_total += 1;
        self.stats.lookups += 1;

        // Check for fault injection.
        const fault = self.faults.maybe_storage_read_fault();
        if (fault != .none) {
            self.stats.faults_encountered += 1;
            self.stats.operations_error += 1;

            self.history.push(.{
                .tick = tick,
                .timestamp = timestamp,
                .operation = .lookup,
                .result = .error_fault_injected,
                .value_before = null,
                .value_after = null,
            });

            return .error_fault_injected;
        }

        // Lookup in both.
        const series_value = if (backend == .segment) self.series.at(timestamp) else self.file_backend_ptr.?.at(timestamp);
        const shadow_value = self.shadow.lookup(timestamp);

        // Verify match.
        const values_match = blk: {
            if (series_value == null and shadow_value == null) break :blk true;
            if (series_value != null and shadow_value != null) {
                break :blk series_value.? == shadow_value.?;
            }
            break :blk false;
        };

        if (!values_match) {
            self.stats.operations_error += 1;
            self.stats.invariant_violations += 1;

            self.history.push(.{
                .tick = tick,
                .timestamp = timestamp,
                .operation = .lookup,
                .result = .error_invariant_violated,
                .value_before = shadow_value,
                .value_after = series_value,
            });

            return .error_invariant_violated;
        }

        self.stats.operations_success += 1;

        self.history.push(.{
            .tick = tick,
            .timestamp = timestamp,
            .operation = .lookup,
            .result = .success,
            .value_before = shadow_value,
            .value_after = series_value,
        });

        return .success;
    }

    /// Verify all invariants hold.
    pub fn verify_invariants(self: *StateMachine) OpResult {
        const tick = self.clock.ticks();
        self.stats.operations_total += 1;
        self.stats.invariant_checks += 1;

        // Invariant 1: counts match.
        const storage_count = if (backend == .segment) self.series.count() else self.file_backend_ptr.?.count;
        if (storage_count != self.shadow.count) {
            self.stats.invariant_violations += 1;
            self.history.push(.{
                .tick = tick,
                .timestamp = 0,
                .operation = .verify_invariants,
                .result = .error_invariant_violated,
                .value_before = @as(i64, self.shadow.count),
                .value_after = @as(i64, storage_count),
            });
            return .error_invariant_violated;
        }

        // Invariant 2: domains match.
        const series_domain = self.storageDomain();
        const shadow_domain = self.shadow.domain();

        if (series_domain.start != shadow_domain.start or
            series_domain.end != shadow_domain.end)
        {
            self.stats.invariant_violations += 1;
            self.history.push(.{
                .tick = tick,
                .timestamp = 0,
                .operation = .verify_invariants,
                .result = .error_invariant_violated,
                .value_before = shadow_domain.start,
                .value_after = series_domain.start,
            });
            return .error_invariant_violated;
        }

        self.stats.operations_success += 1;

        self.history.push(.{
            .tick = tick,
            .timestamp = 0,
            .operation = .verify_invariants,
            .result = .success,
            .value_before = null,
            .value_after = null,
        });

        return .success;
    }

    // Accessors

    /// Get the current count of items.
    pub fn count(self: *const StateMachine) u32 {
        const series_count = if (backend == .segment) self.series.count() else self.file_backend_ptr.?.count;
        const shadow_count = self.shadow.count;

        // Assert invariant.
        assert(series_count == shadow_count);

        return series_count;
    }

    /// Get the current storage domain.
    pub fn storageDomain(self: *const StateMachine) TimeDomain {
        if (backend == .segment) {
            return self.series.domain;
        } else {
            const fb = self.file_backend_ptr.?;
            if (fb.count == 0) return TimeDomain.empty();
            return .{ .start = fb.header.min_timestamp, .end = fb.header.max_timestamp };
        }
    }

    /// Get current statistics.
    pub fn get_stats(self: *const StateMachine) Stats {
        return self.stats;
    }

    /// Get last operation record.
    pub fn last_op(self: *const StateMachine) ?OpRecord {
        return self.history.last();
    }

    /// Check if shadow state is full.
    pub fn is_shadow_full(self: *const StateMachine) bool {
        return self.shadow.count >= shadow_capacity;
    }
};

// Tests

test "StateMachine.init creates empty machine" {
    var clock = Clock.init_zero();
    var faults_injector = FaultInjector.init(12345, @import("faults.zig").FaultConfig.none());

    var sm = try StateMachine.init(std.testing.allocator, &clock, &faults_injector);
    defer sm.deinit();

    try std.testing.expectEqual(@as(u32, 0), sm.count());
    try std.testing.expectEqual(@as(u64, 0), sm.stats.operations_total);
}

test "StateMachine.apply_append adds to series and shadow" {
    var clock = Clock.init_zero();
    var faults_injector = FaultInjector.init(12345, @import("faults.zig").FaultConfig.none());

    var sm = try StateMachine.init(std.testing.allocator, &clock, &faults_injector);
    defer sm.deinit();

    try std.testing.expectEqual(OpResult.success, sm.apply_append(100, 42));
    try std.testing.expectEqual(OpResult.success, sm.apply_append(200, 84));

    try std.testing.expectEqual(@as(u32, 2), sm.count());
    try std.testing.expectEqual(@as(u64, 2), sm.stats.appends);
}

test "StateMachine.apply_append rejects out-of-order" {
    var clock = Clock.init_zero();
    var faults_injector = FaultInjector.init(12345, @import("faults.zig").FaultConfig.none());

    var sm = try StateMachine.init(std.testing.allocator, &clock, &faults_injector);
    defer sm.deinit();

    try std.testing.expectEqual(OpResult.success, sm.apply_append(200, 42));
    try std.testing.expectEqual(OpResult.error_out_of_order, sm.apply_append(100, 84));

    try std.testing.expectEqual(@as(u32, 1), sm.count());
}

test "StateMachine.apply_lookup matches shadow" {
    var clock = Clock.init_zero();
    var faults_injector = FaultInjector.init(12345, @import("faults.zig").FaultConfig.none());

    var sm = try StateMachine.init(std.testing.allocator, &clock, &faults_injector);
    defer sm.deinit();

    _ = sm.apply_append(100, 42);
    _ = sm.apply_append(200, 84);

    try std.testing.expectEqual(OpResult.success, sm.apply_lookup(100));
    try std.testing.expectEqual(OpResult.success, sm.apply_lookup(200));
    try std.testing.expectEqual(OpResult.success, sm.apply_lookup(150));
}

test "StateMachine.verify_invariants passes with consistent state" {
    var clock = Clock.init_zero();
    var faults_injector = FaultInjector.init(12345, @import("faults.zig").FaultConfig.none());

    var sm = try StateMachine.init(std.testing.allocator, &clock, &faults_injector);
    defer sm.deinit();

    _ = sm.apply_append(100, 1);
    _ = sm.apply_append(200, 2);
    _ = sm.apply_append(300, 3);

    try std.testing.expectEqual(OpResult.success, sm.verify_invariants());
}

test "StateMachine tracks history" {
    var clock = Clock.init_zero();
    var faults_injector = FaultInjector.init(12345, @import("faults.zig").FaultConfig.none());

    var sm = try StateMachine.init(std.testing.allocator, &clock, &faults_injector);
    defer sm.deinit();

    _ = sm.apply_append(100, 42);

    const op = sm.last_op().?;
    try std.testing.expectEqual(Operation.append, op.operation);
    try std.testing.expectEqual(OpResult.success, op.result);
    try std.testing.expectEqual(@as(Timestamp, 100), op.timestamp);
}

test "StateMachine tracks statistics correctly" {
    var clock = Clock.init_zero();
    var faults_injector = FaultInjector.init(12345, @import("faults.zig").FaultConfig.none());

    var sm = try StateMachine.init(std.testing.allocator, &clock, &faults_injector);
    defer sm.deinit();

    _ = sm.apply_append(100, 1);
    _ = sm.apply_append(200, 2);
    _ = sm.apply_lookup(100);
    _ = sm.apply_lookup(150);
    _ = sm.verify_invariants();

    try std.testing.expectEqual(@as(u64, 5), sm.stats.operations_total);
    try std.testing.expectEqual(@as(u64, 2), sm.stats.appends);
    try std.testing.expectEqual(@as(u64, 2), sm.stats.lookups);
    try std.testing.expectEqual(@as(u64, 1), sm.stats.invariant_checks);
    try std.testing.expectEqual(@as(u64, 0), sm.stats.invariant_violations);
}

test "StateMachine.is_shadow_full reports correctly" {
    var clock = Clock.init_zero();
    var faults_injector = FaultInjector.init(12345, @import("faults.zig").FaultConfig.none());

    var sm = try StateMachine.init(std.testing.allocator, &clock, &faults_injector);
    defer sm.deinit();

    try std.testing.expect(!sm.is_shadow_full());

    // Can't easily test full state without adding many items.
}
