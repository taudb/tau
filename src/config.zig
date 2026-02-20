//! Tau configuration module.
//! configuration is code, code is configuration.

const std = @import("std");
const assert = std.debug.assert;

// Server Configuration

pub const server = struct {
    /// TCP port to listen on.
    pub const port: u16 = 7701;

    /// IP address to bind to (127.0.0.1 = localhost only).
    pub const address: [4]u8 = .{ 127, 0, 0, 1 };

    /// Pre-shared certificate for authentication (32 bytes).
    /// Generate with: head -c 32 /dev/urandom | xxd -p -c 64
    /// CHANGE THIS IN PRODUCTION.
    pub const certificate: [32]u8 = .{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    };

    /// Maximum concurrent connections.
    pub const max_connections: u32 = 1024;

    /// Connection timeout in milliseconds.
    pub const connection_timeout_ms: u32 = 30_000;

    /// Maximum request payload size in bytes.
    pub const max_payload_bytes: u32 = 1024 * 1024; // 1 MB

    /// Catalog capacity (maximum series count).
    pub const catalog_capacity: u32 = 10_000;

    /// Default segment capacity for new series.
    pub const default_segment_capacity: u32 = 1024;
};

// Simulation Configuration

pub const simulation = struct {
    /// Default master seed for reproducibility.
    /// Set to 0 to use system time as seed.
    pub const default_seed: u64 = 0;

    /// Default number of scenarios to run.
    pub const default_scenarios: u32 = 100;

    /// Default simulation mode.
    pub const default_mode: Mode = .quick;

    pub const Mode = enum {
        quick,
        standard,
        century,
        chaos,
    };

    /// Quick mode configuration.
    pub const quick = struct {
        pub const duration_years: u32 = 1;
        pub const ops_per_day: u32 = 100;
        pub const invariant_check_interval: u32 = 1000;
        pub const max_operations: u64 = 100_000;
    };

    /// Standard mode configuration.
    pub const standard = struct {
        pub const duration_years: u32 = 10;
        pub const ops_per_day: u32 = 500;
        pub const invariant_check_interval: u32 = 5000;
        pub const max_operations: u64 = 10_000_000;
    };

    /// Century mode configuration.
    pub const century = struct {
        pub const duration_years: u32 = 100;
        pub const ops_per_day: u32 = 25_000;
        pub const invariant_check_interval: u32 = 10_000;
        pub const max_operations: u64 = 100_000_000;
    };

    /// Chaos mode configuration.
    pub const chaos = struct {
        pub const duration_years: u32 = 10;
        pub const ops_per_day: u32 = 2000;
        pub const invariant_check_interval: u32 = 1000;
        pub const max_operations: u64 = 50_000_000;
    };

    /// Shadow state capacity for verification.
    pub const shadow_capacity: u32 = 500_000;

    /// Operation history capacity.
    pub const history_capacity: u32 = 10_000;

    /// Maximum tracked failure seeds.
    pub const max_tracked_failures: u32 = 100;
};

// Fault Injection Configuration (parts per million)

pub const faults = struct {
    /// No faults (baseline testing).
    pub const none = FaultRates{};

    /// Mild faults (occasional errors).
    pub const mild = FaultRates{
        .storage_read_error_ppm = 100,
        .storage_write_error_ppm = 100,
        .storage_bitflip_ppm = 10,
        .network_drop_ppm = 1000,
        .network_delay_ppm = 5000,
    };

    /// Aggressive faults (stress testing).
    pub const aggressive = FaultRates{
        .storage_read_error_ppm = 10_000,
        .storage_write_error_ppm = 10_000,
        .storage_bitflip_ppm = 1000,
        .storage_lost_write_ppm = 5000,
        .storage_gray_failure_ppm = 5000,
        .network_drop_ppm = 50_000,
        .network_reorder_ppm = 30_000,
        .network_duplicate_ppm = 10_000,
        .network_corrupt_ppm = 1000,
        .network_delay_ppm = 20_000,
        .memory_corrupt_ppm = 100,
        .clock_skew_ppm = 10_000,
    };

    /// Chaos faults (maximum fault injection).
    pub const chaos = FaultRates{
        .storage_read_error_ppm = 100_000,
        .storage_write_error_ppm = 100_000,
        .storage_bitflip_ppm = 10_000,
        .storage_lost_write_ppm = 50_000,
        .storage_gray_failure_ppm = 50_000,
        .network_drop_ppm = 200_000,
        .network_reorder_ppm = 100_000,
        .network_duplicate_ppm = 50_000,
        .network_corrupt_ppm = 10_000,
        .network_delay_ppm = 100_000,
        .memory_corrupt_ppm = 1000,
        .memory_alloc_fail_ppm = 5000,
        .clock_skew_ppm = 50_000,
    };

    /// Maximum network delay in ticks.
    pub const max_network_delay_ticks: u32 = 100;

    /// Maximum clock skew in nanoseconds.
    pub const max_clock_skew_ns: i64 = 1_000_000_000;

    pub const FaultRates = struct {
        storage_read_error_ppm: u32 = 0,
        storage_write_error_ppm: u32 = 0,
        storage_bitflip_ppm: u32 = 0,
        storage_lost_write_ppm: u32 = 0,
        storage_gray_failure_ppm: u32 = 0,
        network_drop_ppm: u32 = 0,
        network_reorder_ppm: u32 = 0,
        network_duplicate_ppm: u32 = 0,
        network_corrupt_ppm: u32 = 0,
        network_delay_ppm: u32 = 0,
        memory_corrupt_ppm: u32 = 0,
        memory_alloc_fail_ppm: u32 = 0,
        clock_skew_ppm: u32 = 0,
    };
};

// Benchmark Configuration

pub const benchmark = struct {
    /// Default iterations per scenario.
    pub const default_iterations: u32 = 10;

    /// Ingest benchmark: number of points to append.
    pub const ingest_point_count: u32 = 100_000;

    /// Query benchmark: number of lookups.
    pub const query_count: u32 = 10_000;

    /// Auth benchmark: number of verifications.
    pub const auth_verify_count: u32 = 100_000;
};

// Storage Configuration

pub const storage = struct {
    /// Maximum segment capacity (points per segment).
    pub const segment_capacity_max: u32 = 1 << 20;

    /// Default segment capacity.
    pub const segment_capacity_default: u32 = 1024;

    /// Series label length in bytes.
    pub const label_length: u32 = 32;

    /// File backend header size in bytes (page-aligned).
    pub const file_backend_header_size: u32 = 4096;

    /// Storage backend selection.
    pub const Backend = enum {
        segment,
        file,
    };

    /// Active storage backend. Change to switch the server
    /// and catalog between in-memory segments and file-backed
    /// columnar storage. Requires recompile.
    pub const default_backend: Backend = .file;

    /// Data directory for file-backed backends.
    pub const data_dir: []const u8 = "tau-data";
};

// Time Constants

pub const time = struct {
    pub const ns_per_us: i64 = 1_000;
    pub const ns_per_ms: i64 = 1_000_000;
    pub const ns_per_sec: i64 = 1_000_000_000;
    pub const ns_per_min: i64 = 60 * ns_per_sec;
    pub const ns_per_hour: i64 = 60 * ns_per_min;
    pub const ns_per_day: i64 = 24 * ns_per_hour;
    pub const ns_per_year: i64 = 365 * ns_per_day;
    pub const ns_per_century: i64 = 100 * ns_per_year;
};

// Metrics Server
pub const metrics = struct {
    pub const enabled: bool = true;
    pub const port: u16 = 7702;
    pub const address: [4]u8 = .{ 127, 0, 0, 1 };
};

// Compile-Time Validation

comptime {
    // Server validation.
    assert(server.port > 0);
    assert(server.port < 65535);
    assert(server.max_connections > 0);
    assert(server.max_connections <= 65535);
    assert(server.connection_timeout_ms > 0);
    assert(server.max_payload_bytes > 0);
    assert(server.catalog_capacity > 0);
    assert(server.default_segment_capacity > 0);
    assert(server.default_segment_capacity <= storage.segment_capacity_max);

    // Simulation validation.
    assert(simulation.quick.duration_years > 0);
    assert(simulation.quick.ops_per_day > 0);
    assert(simulation.shadow_capacity > 0);
    assert(simulation.history_capacity > 0);

    // Fault validation (all rates <= 1,000,000 ppm).
    const ppm_max: u32 = 1_000_000;
    assert(faults.aggressive.network_drop_ppm <= ppm_max);
    assert(faults.chaos.network_drop_ppm <= ppm_max);
    assert(faults.max_clock_skew_ns > 0);

    // Storage validation.
    assert(storage.segment_capacity_max > 0);
    assert(storage.segment_capacity_default > 0);
    assert(storage.segment_capacity_default <= storage.segment_capacity_max);
    assert(storage.label_length == 32);
    assert(storage.file_backend_header_size >= 4096);
    assert(storage.file_backend_header_size % 4096 == 0);
    assert(storage.data_dir.len > 0);

    // Time validation.
    assert(time.ns_per_sec == 1_000_000_000);
    assert(time.ns_per_day == 86_400_000_000_000);

    // Metrics validation.
    assert(metrics.port > 0);
    assert(metrics.port < 65535);
    assert(metrics.port != server.port);

    // Bench validation.
    assert(benchmark.default_iterations > 0);
    assert(benchmark.ingest_point_count > 0);
    assert(benchmark.query_count > 0);
    assert(benchmark.auth_verify_count > 0);
}

// Tests

test "server config is valid" {
    try std.testing.expect(server.port > 0);
    try std.testing.expect(server.certificate.len == 32);
    try std.testing.expect(server.max_connections > 0);
}

test "simulation config is valid" {
    try std.testing.expect(simulation.quick.duration_years < simulation.standard.duration_years);
    try std.testing.expect(simulation.standard.duration_years < simulation.century.duration_years);
    try std.testing.expect(simulation.shadow_capacity > 0);
}

test "fault rates are within bounds" {
    const ppm_max: u32 = 1_000_000;

    try std.testing.expect(faults.none.network_drop_ppm == 0);
    try std.testing.expect(faults.mild.network_drop_ppm < faults.aggressive.network_drop_ppm);
    try std.testing.expect(faults.aggressive.network_drop_ppm < faults.chaos.network_drop_ppm);
    try std.testing.expect(faults.chaos.network_drop_ppm <= ppm_max);
}

test "time constants are correct" {
    try std.testing.expectEqual(@as(i64, 1_000_000_000), time.ns_per_sec);
    try std.testing.expectEqual(@as(i64, 60_000_000_000), time.ns_per_min);
    try std.testing.expectEqual(@as(i64, 3_600_000_000_000), time.ns_per_hour);
}

test "storage config is valid" {
    try std.testing.expect(storage.segment_capacity_default <= storage.segment_capacity_max);
    try std.testing.expect(storage.label_length == 32);
    try std.testing.expect(storage.file_backend_header_size == 4096);
    try std.testing.expect(storage.data_dir.len > 0);
    try std.testing.expect(
        storage.default_backend == .segment or
            storage.default_backend == .file,
    );
}

test "benchmark config is valid" {
    try std.testing.expect(benchmark.default_iterations > 0);
    try std.testing.expect(benchmark.ingest_point_count > 0);
    try std.testing.expect(benchmark.query_count > 0);
    try std.testing.expect(benchmark.auth_verify_count > 0);
}

test "metrics config is valid" {
    try std.testing.expect(metrics.enabled == true);
    try std.testing.expect(metrics.port > 0);
    try std.testing.expect(metrics.port < 65535);
}
