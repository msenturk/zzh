const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the core application executable
    const exe = b.addExecutable(.{
        .name = "zzh",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // Run Step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // End-to-end Tests
    const e2e_exe = b.addExecutable(.{
        .name = "test-e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test-e2e.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_e2e = b.addRunArtifact(e2e_exe);
    const e2e_step = b.step("e2e", "Run end-to-end tests");
    e2e_step.dependOn(&run_e2e.step);
}
