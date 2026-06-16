const std = @import("std");

pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});
    const tsan = builder.option(bool, "tsan", "Build the test suite with ThreadSanitizer") orelse false;

    const arc_module = builder.addModule("arc", .{
        .root_source_file = builder.path("src/arc.zig"),
        .target = target,
    });

    const io = builder.graph.io;

    var tests_dir = builder.build_root.handle.openDir(io, "tests", .{ .iterate = true }) catch {
        return;
    };
    defer tests_dir.close(io);

    const exe_module = builder.createModule(.{
        .root_source_file = builder.path("examples/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_module.addImport("arc", arc_module);

    const exe = builder.addExecutable(.{
        .name = "arc",
        .root_module = exe_module,
    });

    builder.installArtifact(exe);

    const run_step = builder.step("run", "Run the application");
    const run_cmd = builder.addRunArtifact(exe);

    run_cmd.step.dependOn(builder.getInstallStep());

    if (builder.args) |args| {
        run_cmd.addArgs(args);
    }

    run_step.dependOn(&run_cmd.step);

    const test_step = builder.step("test", "Run unit tests");

    var test_files: std.ArrayList([]const u8) = .empty;
    defer test_files.deinit(builder.allocator);

    var it = tests_dir.iterate();

    while (it.next(io) catch |err| {
        std.debug.panic("failed to iterate tests directory: {}", .{err});
    }) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "test_")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const full_path = std.fmt.allocPrint(builder.allocator, "tests/{s}", .{entry.name}) catch |err| {
            std.debug.panic("failed to allocate test path: {}", .{err});
        };

        test_files.append(builder.allocator, full_path) catch |err| {
            std.debug.panic("failed to append test path: {}", .{err});
        };
    }

    std.mem.sort([]const u8, test_files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    for (test_files.items) |test_file| {
        const t_module = builder.createModule(.{
            .root_source_file = builder.path(test_file),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = if (tsan) true else null,
        });
        t_module.addImport("arc", arc_module);

        const t = builder.addTest(.{
            .root_module = t_module,
        });

        const run_t = builder.addRunArtifact(t);
        run_t.step.name = test_file;

        test_step.dependOn(&run_t.step);
    }

    const bench_module = builder.createModule(.{
        .root_source_file = builder.path("benchmarks/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    bench_module.addImport("arc", arc_module);

    const bench_exe = builder.addExecutable(.{
        .name = "bench",
        .root_module = bench_module,
    });

    const bench_step = builder.step("bench", "Run benchmarks");
    const run_bench = builder.addRunArtifact(bench_exe);
    bench_step.dependOn(&run_bench.step);

    const soak_module = builder.createModule(.{
        .root_source_file = builder.path("benchmarks/soak.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });

    soak_module.addImport("arc", arc_module);

    const soak_exe = builder.addExecutable(.{
        .name = "soak",
        .root_module = soak_module,
    });

    const soak_step = builder.step("soak", "Run soak test");
    const run_soak = builder.addRunArtifact(soak_exe);

    soak_step.dependOn(&run_soak.step);

    const fuzz_module = builder.createModule(.{
        .root_source_file = builder.path("benchmarks/fuzz.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });

    fuzz_module.addImport("arc", arc_module);

    const fuzz_exe = builder.addExecutable(.{
        .name = "fuzz",
        .root_module = fuzz_module,
    });

    const fuzz_step = builder.step("fuzz", "Run the brute-force encoder fuzzer");
    const run_fuzz = builder.addRunArtifact(fuzz_exe);
    fuzz_step.dependOn(&run_fuzz.step);
}
