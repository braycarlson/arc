const std = @import("std");

const assert = std.debug.assert;

const Steps = struct {
    bench: *std.Build.Step,
    check: *std.Build.Step,
    ci: *std.Build.Step,
    fuzz: *std.Build.Step,
    fuzz_build: *std.Build.Step,
    fuzz_smoke: *std.Build.Step,
    run: *std.Build.Step,
    soak: *std.Build.Step,
    test_all: *std.Build.Step,
    test_fmt: *std.Build.Step,
    test_integration: *std.Build.Step,
    test_unit: *std.Build.Step,
};

const format_paths = [_][]const u8{ "build.zig", "benchmarks", "examples", "src" };

comptime {
    assert(format_paths.len > 0);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tsan = b.option(bool, "tsan", "Build the test suites with ThreadSanitizer") orelse false;

    const steps = Steps{
        .bench = b.step("bench", "Run the benchmark suite"),
        .check = b.step("check", "Compile every artifact without running it"),
        .ci = b.step("ci", "Run formatting, compilation, and every test suite"),
        .fuzz = b.step("fuzz", "Run a fuzzer: -- <fuzzer> [seed] [events]"),
        .fuzz_build = b.step("fuzz:build", "Compile the fuzzer without running it"),
        .fuzz_smoke = b.step("fuzz:smoke", "Run every fuzzer briefly with a fixed seed"),
        .run = b.step("run", "Run the example application"),
        .soak = b.step("soak", "Run the long-running soak test"),
        .test_all = b.step("test", "Run every test suite and the formatting check"),
        .test_fmt = b.step("test:fmt", "Check that every source file is formatted"),
        .test_integration = b.step("test:integration", "Run the cross-cutting test suites"),
        .test_unit = b.step("test:unit", "Run the colocated unit tests and the tidy law"),
    };

    const module = add_module(b, target, optimize);

    add_format(b, &steps);
    add_example(b, &steps, module, target, optimize);
    add_unit_tests(b, &steps, target, optimize, tsan);
    add_integration_tests(b, &steps, module, target, optimize, tsan);
    add_bench(b, &steps, module, target, optimize);
    add_soak(b, &steps, module, target, optimize);
    add_fuzz(b, &steps, target, optimize);

    steps.ci.dependOn(steps.test_fmt);
    steps.ci.dependOn(steps.check);
    steps.ci.dependOn(steps.test_unit);
    steps.ci.dependOn(steps.test_integration);
    steps.ci.dependOn(steps.fuzz_smoke);

    b.default_step.dependOn(steps.check);
}

fn add_module(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.addModule("arc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
}

fn add_format(b: *std.Build, steps: *const Steps) void {
    const fmt = b.addFmt(.{
        .paths = &format_paths,
        .check = true,
    });

    steps.test_fmt.dependOn(&fmt.step);
    steps.test_all.dependOn(&fmt.step);
}

fn add_example(
    b: *std.Build,
    steps: *const Steps,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = b.addExecutable(.{
        .name = "arc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "arc", .module = module }},
        }),
    });

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);

    run.setCwd(b.path("."));
    run.step.dependOn(b.getInstallStep());

    if (b.args) |args| run.addArgs(args);

    steps.run.dependOn(&run.step);
    steps.check.dependOn(&exe.step);
}

fn add_unit_tests(
    b: *std.Build,
    steps: *const Steps,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tsan: bool,
) void {
    const unit = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unit_tests.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = if (tsan) true else null,
        }),
        .filters = b.args orelse &.{},
    });

    const run = b.addRunArtifact(unit);

    run.setCwd(b.path("."));

    steps.test_unit.dependOn(&run.step);
    steps.test_all.dependOn(&run.step);
    steps.check.dependOn(&unit.step);
}

fn add_integration_tests(
    b: *std.Build,
    steps: *const Steps,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tsan: bool,
) void {
    const integration = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_tests.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = if (tsan) true else null,
            .imports = &.{.{ .name = "arc", .module = module }},
        }),
        .filters = b.args orelse &.{},
    });

    const run = b.addRunArtifact(integration);

    run.setCwd(b.path("."));

    steps.test_integration.dependOn(&run.step);
    steps.test_all.dependOn(&run.step);
    steps.check.dependOn(&integration.step);
}

fn add_bench(
    b: *std.Build,
    steps: *const Steps,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "arc", .module = module }},
        }),
    });

    const run = b.addRunArtifact(exe);

    run.setCwd(b.path("."));

    steps.bench.dependOn(&run.step);
    steps.check.dependOn(&exe.step);
}

fn add_soak(
    b: *std.Build,
    steps: *const Steps,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = b.addExecutable(.{
        .name = "soak",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/soak.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "arc", .module = module }},
        }),
    });

    const run = b.addRunArtifact(exe);

    run.setCwd(b.path("."));

    steps.soak.dependOn(&run.step);
    steps.check.dependOn(&exe.step);
}

fn add_fuzz(
    b: *std.Build,
    steps: *const Steps,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run = b.addRunArtifact(exe);

    run.setCwd(b.path("."));

    if (b.args) |args| run.addArgs(args);

    const smoke = b.addRunArtifact(exe);

    smoke.setCwd(b.path("."));
    smoke.addArg("smoke");

    steps.fuzz.dependOn(&run.step);
    steps.fuzz_build.dependOn(&exe.step);
    steps.fuzz_smoke.dependOn(&smoke.step);
    steps.check.dependOn(&exe.step);
}
