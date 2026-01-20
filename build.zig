const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const primitives_module = b.createModule(.{
        .root_source_file = b.path("src/libtau/primitives/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .module = b.createModule(.{
                .root_source_file = b.path("src/libtau/ulid/mod.zig"),
                .target = target,
                .optimize = optimize,
            }), .name = "ulid" },
        },
    });

    const libtau_module = b.createModule(.{
        .root_source_file = b.path("src/libtau/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .module = primitives_module, .name = "primitives" },
        },
    });

    const exe = b.addExecutable(.{
        .name = "tau",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .module = libtau_module, .name = "libtau" },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .module = libtau_module, .name = "libtau" },
            },
        }),
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
