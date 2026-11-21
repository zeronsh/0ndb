const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ondb_mod = b.addModule("ondb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "0ndb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ondb", .module = ondb_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run 0ndb");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const verify_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/verify.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ondb", .module = ondb_mod },
            },
        }),
    });

    const run_verify = b.addRunArtifact(verify_tests);
    const test_step = b.step("test", "Run verification");
    test_step.dependOn(&run_verify.step);
}
