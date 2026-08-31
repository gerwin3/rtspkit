const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // stdx lib

    const stdx_lib = b.createModule(.{
        .root_source_file = b.path("src/lib/stdx/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const stdx_unit_tests = b.addTest(.{ .root_module = stdx_lib });
    const stdx_unit_tests_run = b.addRunArtifact(stdx_unit_tests);

    // media lib

    const media_lib = b.createModule(.{
        .root_source_file = b.path("src/lib/media/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    media_lib.addImport("stdx", stdx_lib);
    const media_unit_tests = b.addTest(.{ .root_module = media_lib });
    const media_unit_tests_run = b.addRunArtifact(media_unit_tests);

    // exe

    const rtspq_mod = b.createModule(.{
        .root_source_file = b.path("src/rtspq/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    rtspq_mod.addImport("stdx", stdx_lib);
    rtspq_mod.addImport("media", media_lib);

    const exe = b.addExecutable(.{
        .name = "rtspq",
        .root_module = rtspq_mod,
    });

    b.installArtifact(exe);

    // Unit tests

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&stdx_unit_tests_run.step);
    test_step.dependOn(&media_unit_tests_run.step);

    // Check

    const check = b.step("check", "Check");
    check.dependOn(&exe.step);
}
