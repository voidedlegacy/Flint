const std = @import("std");

// zig build                    -> zig-out/bin/flint
// zig build run -- file.fl     -> compile a Flint program
// zig build test               -> unit tests + every examples/*.fl
// zig build examples           -> only the examples
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "flint",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // zig build run -- file.fl
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();
    run_cmd.step.dependOn(b.getInstallStep());
    b.step("run", "Compile a Flint program").dependOn(&run_cmd.step);

    // Unit tests in every src/*.zig file.
    const unit_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_unit = b.addRunArtifact(unit_tests);

    // The example runner: compiles each examples/*.fl with the flint we
    // just built, in a scratch copy, and checks exit codes and messages.
    const runner = b.addExecutable(.{
        .name = "run-examples",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/run_examples.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_examples = b.addRunArtifact(runner);
    run_examples.addArtifactArg(exe);
    run_examples.addDirectoryArg(b.path("examples"));
    run_examples.addDirectoryArg(b.path("tests/expected"));
    _ = run_examples.addOutputDirectoryArg("examples-out");
    run_examples.has_side_effects = true; // always rerun: it calls clang

    const examples_step = b.step("examples", "Compile and check every examples/*.fl");
    examples_step.dependOn(&run_examples.step);

    const test_step = b.step("test", "Run unit tests and the example runner");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&run_examples.step);
}
