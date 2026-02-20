const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("tau", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tau", .module = mod },
            },
        }),
    });

    b.installArtifact(bench_exe);

    const bench_step = b.step("bench", "Run benchmarks");
    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_cmd.step);
    bench_cmd.step.dependOn(b.getInstallStep());

    const catalog_mod_build = b.addModule("catalog", .{
        .root_source_file = b.path("src/server/catalog.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "tau", .module = mod },
        },
    });

    const protocol_mod_build = b.addModule("protocol", .{
        .root_source_file = b.path("src/server/protocol.zig"),
        .target = target,
    });

    const metrics_mod_build = b.addModule("metrics", .{
        .root_source_file = b.path("src/server/metrics_server.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "tau", .module = mod },
            .{ .name = "catalog", .module = catalog_mod_build },
            .{ .name = "protocol", .module = protocol_mod_build },
        },
    });

    const server_exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tau", .module = mod },
                .{ .name = "catalog", .module = catalog_mod_build },
                .{ .name = "metrics", .module = metrics_mod_build },
                .{ .name = "protocol", .module = protocol_mod_build },
            },
        }),
    });

    b.installArtifact(server_exe);

    const serve_step = b.step("server", "Run the database server");
    const serve_cmd = b.addRunArtifact(server_exe);
    serve_step.dependOn(&serve_cmd.step);
    serve_cmd.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    const server_tests = b.addTest(.{
        .root_module = server_exe.root_module,
    });
    const run_server_tests = b.addRunArtifact(server_tests);
    test_step.dependOn(&run_server_tests.step);

    const sim_exe = b.addExecutable(.{
        .name = "sim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tau", .module = mod },
                .{ .name = "catalog", .module = catalog_mod_build },
                .{ .name = "metrics", .module = metrics_mod_build },
                .{ .name = "protocol", .module = protocol_mod_build },
            },
        }),
    });

    b.installArtifact(sim_exe);
    const sim_step = b.step("sim", "Run the simulator");
    const sim_cmd = b.addRunArtifact(sim_exe);
    sim_step.dependOn(&sim_cmd.step);
    sim_cmd.step.dependOn(b.getInstallStep());

    const sim_tests = b.addTest(.{
        .root_module = sim_exe.root_module,
    });
    const run_sim_tests = b.addRunArtifact(sim_tests);
    test_step.dependOn(&run_sim_tests.step);
}
