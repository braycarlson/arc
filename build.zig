const std = @import("std");

const assert = std.debug.assert;

const Artifact = struct {
    name: []const u8,
    optimize: ?std.lang.Optimize,
    root: []const u8,
};

const Context = struct {
    bounded: *std.Build.Module,
    builder: *std.Build,
    filters: []const []const u8,
    json: *std.Build.Module,
    module: *std.Build.Module,
    optimize: std.lang.Optimize,
    sanitize_thread: bool,
    steps: Steps,
    target: std.Build.ResolvedTarget,
};

const Steps = struct {
    bench: *std.Build.Step,
    check: *std.Build.Step,
    continuous_integration: *std.Build.Step,
    example: *std.Build.Step,
    fuzz: *std.Build.Step,
    fuzz_build: *std.Build.Step,
    fuzz_smoke: *std.Build.Step,
    soak: *std.Build.Step,
    test_all: *std.Build.Step,
    test_format: *std.Build.Step,
    test_unit: *std.Build.Step,
};

const artifact_bench: Artifact = .{
    .name = "bench",
    .optimize = .fast,
    .root = "benchmarks/bench.zig",
};

const artifact_example: Artifact = .{
    .name = "log",
    .optimize = null,
    .root = "examples/log.zig",
};

const artifact_fuzz: Artifact = .{
    .name = "fuzz",
    .optimize = null,
    .root = "src/fuzz_tests.zig",
};

const artifact_soak: Artifact = .{
    .name = "soak",
    .optimize = .safe,
    .root = "benchmarks/soak.zig",
};

const format_paths = [_][]const u8{ "benchmarks", "build.zig", "examples", "src" };
const module_root = "src/arc.zig";
const unit_tests_root = "src/unit_tests.zig";

const supported_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

comptime {
    assert(format_paths.len == 4);
    assert(supported_targets.len == 3);
}

pub fn build(builder: *std.Build) void {
    assert(builder.graph.host.result.ptrBitWidth() == 64);

    const filters = builder.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};

    const sanitize_thread = builder.option(
        bool,
        "tsan",
        "Build the unit tests with ThreadSanitizer",
    ) orelse false;

    const bounded = builder.dependency("bounded", .{}).module("bounded");
    const json = builder.dependency("json", .{}).module("json");

    const module = builder.addModule("arc", .{
        .root_source_file = builder.path(module_root),
        .imports = &.{
            .{ .name = "bounded", .module = bounded },
            .{ .name = "json", .module = json },
        },
    });

    const context = Context{
        .bounded = bounded,
        .builder = builder,
        .filters = filters,
        .json = json,
        .module = module,
        .optimize = builder.standardOptimizeOption(.{ .preferred_optimize_mode = null }),
        .sanitize_thread = sanitize_thread,
        .steps = steps_declare(builder),
        .target = builder.standardTargetOptions(.{ .whitelist = null, .default_target = .{} }),
    };

    add_bench(&context);
    add_check(&context);
    add_example(&context);
    add_format(&context);
    add_fuzz(&context);
    add_soak(&context);
    add_unit_tests(&context);

    context.steps.continuous_integration.dependOn(context.steps.check);
    context.steps.continuous_integration.dependOn(context.steps.example);
    context.steps.continuous_integration.dependOn(context.steps.fuzz_smoke);
    context.steps.continuous_integration.dependOn(context.steps.test_all);

    builder.default_step.dependOn(context.steps.check);
}

fn steps_declare(builder: *std.Build) Steps {
    assert(builder.graph.host.result.ptrBitWidth() == 64);

    const result = Steps{
        .bench = builder.step("bench", "Run the benchmark suite built with --release=fast"),
        .check = builder.step("check", "Compile every artifact for Linux, macOS, and Windows"),
        .continuous_integration = builder.step("ci", "Run every check, test, and fuzz smoke"),
        .example = builder.step("example", "Build and run the example against the module"),
        .fuzz = builder.step("fuzz", "Run a fuzzer: zig build fuzz -- <fuzzer> [seed] [events]"),
        .fuzz_build = builder.step("fuzz:build", "Compile the fuzzers without running them"),
        .fuzz_smoke = builder.step("fuzz:smoke", "Run every fuzzer briefly with a fixed seed"),
        .soak = builder.step("soak", "Run the multi-threaded soak built with --release=safe"),
        .test_all = builder.step("test", "Run every test suite and the format check"),
        .test_format = builder.step("test:fmt", "Check that every source file is formatted"),
        .test_unit = builder.step("test:unit", "Run the unit tests and the tidy check"),
    };

    assert(result.check != result.test_all);
    assert(result.fuzz != result.fuzz_smoke);

    return result;
}

fn executable(
    context: *const Context,
    target: std.Build.ResolvedTarget,
    artifact: *const Artifact,
) *std.Build.Step.Compile {
    assert(target.result.ptrBitWidth() == 64);
    assert(artifact.name.len > 0);
    assert(std.mem.endsWith(u8, artifact.root, ".zig"));

    return context.builder.addExecutable(.{
        .name = artifact.name,
        .root_module = context.builder.createModule(.{
            .root_source_file = context.builder.path(artifact.root),
            .target = target,
            .optimize = artifact.optimize orelse context.optimize,
            .omit_frame_pointer = false,
            .imports = &.{
                .{ .name = "arc", .module = context.module },
                .{ .name = "bounded", .module = context.bounded },
                .{ .name = "json", .module = context.json },
            },
        }),
    });
}

fn add_bench(context: *const Context) void {
    assert(context.steps.bench != context.steps.check);
    assert(artifact_bench.optimize == .fast);

    const compiled = executable(context, context.target, &artifact_bench);
    const run = context.builder.addRunArtifact(compiled);

    run.has_side_effects = true;

    context.steps.bench.dependOn(&run.step);
}

fn add_check(context: *const Context) void {
    assert(supported_targets.len > 0);
    assert(context.steps.check != context.steps.test_all);

    const artifacts = [_]*const Artifact{
        &artifact_bench,
        &artifact_example,
        &artifact_fuzz,
        &artifact_soak,
    };

    for (supported_targets) |query| {
        const resolved = context.builder.resolveTargetQuery(query);

        for (artifacts) |artifact| {
            const compiled = executable(context, resolved, artifact);

            context.steps.check.dependOn(&compiled.step);
        }

        context.steps.check.dependOn(&unit_tests(context, resolved).step);
    }
}

fn add_example(context: *const Context) void {
    assert(context.steps.example != context.steps.check);
    assert(artifact_example.root.len > 0);

    const compiled = executable(context, context.target, &artifact_example);
    const run = context.builder.addRunArtifact(compiled);

    run.has_side_effects = true;

    context.steps.example.dependOn(&run.step);
}

fn add_format(context: *const Context) void {
    assert(format_paths.len > 0);
    assert(context.steps.test_format != context.steps.test_all);

    const format = context.builder.addFmt(.{
        .paths = context.builder.pathList(&format_paths),
        .check = true,
    });

    context.steps.test_format.dependOn(&format.step);
    context.steps.test_all.dependOn(&format.step);
}

fn add_fuzz(context: *const Context) void {
    assert(context.steps.fuzz != context.steps.fuzz_smoke);
    assert(artifact_fuzz.root.len > 0);

    const fuzz = executable(context, context.target, &artifact_fuzz);
    const fuzz_run = context.builder.addRunArtifact(fuzz);
    const fuzz_smoke = context.builder.addRunArtifact(fuzz);

    const fuzz_install = context.builder.addInstallArtifact(fuzz, .{
        .dest_dir = .default,
        .pdb_dir = .default,
        .compiler_rt_dyn_lib_dir = .default,
        .h_dir = .default,
        .implib_dir = .default,
        .dylib_symlinks = null,
        .dest_sub_path = null,
    });

    fuzz_run.addPassthruArgs();
    fuzz_smoke.addArg("smoke");

    context.steps.fuzz.dependOn(&fuzz_run.step);
    context.steps.fuzz_build.dependOn(&fuzz_install.step);
    context.steps.fuzz_smoke.dependOn(&fuzz_smoke.step);
}

fn add_soak(context: *const Context) void {
    assert(context.steps.soak != context.steps.check);
    assert(artifact_soak.optimize == .safe);

    const compiled = executable(context, context.target, &artifact_soak);
    const run = context.builder.addRunArtifact(compiled);

    run.has_side_effects = true;

    context.steps.soak.dependOn(&run.step);
}

fn unit_tests(context: *const Context, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    assert(target.result.ptrBitWidth() == 64);
    assert(context.filters.len < 64);

    return context.builder.addTest(.{
        .name = "unit_tests",
        .root_module = context.builder.createModule(.{
            .root_source_file = context.builder.path(unit_tests_root),
            .target = target,
            .optimize = context.optimize,
            .sanitize_thread = context.sanitize_thread,
            .imports = &.{
                .{ .name = "bounded", .module = context.bounded },
                .{ .name = "json", .module = context.json },
            },
        }),
        .filters = context.filters,
    });
}

fn add_unit_tests(context: *const Context) void {
    assert(context.steps.test_unit != context.steps.test_all);
    assert(unit_tests_root.len > 0);

    const suite = unit_tests(context, context.target);
    const run = context.builder.addRunArtifact(suite);

    run.setCwd(context.builder.path("."));
    run.has_side_effects = true;

    context.steps.test_unit.dependOn(&run.step);
    context.steps.test_all.dependOn(&run.step);
}
