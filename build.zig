const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // libtau module (root of library code)
    const libtau_mod = b.createModule(.{
        .root_source_file = b.path("src/libtau/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // tau main executable
    const tau_exe = b.addExecutable(.{
        .name = "tau",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "libtau", .module = libtau_mod },
            },
        }),
    });
    b.installArtifact(tau_exe);

    const run_step = b.step("run", "Run the tau database server");
    const run_cmd = b.addRunArtifact(tau_exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test - libtau (library)
    const libtau_tests = b.addTest(.{
        .root_module = libtau_mod,
    });
    const test_libtau_step = b.step("test-libtau", "Run libtau tests");
    const run_libtau_tests = b.addRunArtifact(libtau_tests);
    test_libtau_step.dependOn(&run_libtau_tests.step);

    // Test - server
    const server_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "libtau", .module = libtau_mod },
            },
        }),
    });
    const test_server_step = b.step("test-server", "Run server tests");
    const run_server_tests = b.addRunArtifact(server_tests);
    test_server_step.dependOn(&run_server_tests.step);

    // Aggregate (optional) - test all
    const test_step = b.step("test", "Run all tau project tests");
    test_step.dependOn(&run_libtau_tests.step);
    test_step.dependOn(&run_server_tests.step);
}
