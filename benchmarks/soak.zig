const std = @import("std");

const arc = @import("arc");

const assert = std.debug.assert;

const Core = arc.Core;
const Logger = arc.Logger;

const Result = struct {
    drop_count: u64,
    elapsed_ns: u64,
};

const Soak = struct {
    core: Core,
    oversized: [oversized_bytes]u8,
    threads: [thread_count]std.Thread,
};

const event_count: u64 = 625_000;
const oversized_bytes: u32 = 16 * 1024;
const oversized_interval: u64 = 100_000;
const thread_count: u32 = 8;

const spawn_config: std.Thread.SpawnConfig = .{
    .allocator = null,
    .stack_size = std.Thread.SpawnConfig.default_stack_size,
};

comptime {
    assert(thread_count > 0);
    assert(oversized_interval < event_count);
    assert(oversized_bytes > arc.limits.entry_bytes_max);
}

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len > 0);

    const soak = try init.gpa.create(Soak);
    defer init.gpa.destroy(soak);

    soak.oversized = @splat('x');

    soak.core.init(init.io, &.{
        .caller = false,
        .clock = .{ .fixed_ns = 1_700_000_000 * std.time.ns_per_s },
        .error_output = .discard,
        .level = .debug,
        .sampling = null,
        .sinks = &.{.{ .encoding = .production, .level = .debug, .writer = .discard }},
        .terminal_development_panic = .none,
        .terminal_fatal = .exit,
        .thread_safe = true,
    });

    const start = std.Io.Timestamp.now(init.io, .awake).nanoseconds;

    for (&soak.threads) |*thread| {
        thread.* = try std.Thread.spawn(spawn_config, worker_run, .{soak});
    }

    for (&soak.threads) |*thread| thread.join();

    const end = std.Io.Timestamp.now(init.io, .awake).nanoseconds;

    assert(end > start);

    const result: Result = .{
        .drop_count = soak.core.truncated_count.load(.monotonic),
        .elapsed_ns = @intCast(end - start),
    };

    try drops_verify(result.drop_count);
    report(&result);
}

fn worker_run(soak: *const Soak) void {
    assert(soak.oversized.len > arc.limits.entry_bytes_max);
    assert(soak.core.thread_safe);

    const logger = &soak.core.logger;

    for (0..event_count) |index| {
        if (@rem(index, oversized_interval) == 0) {
            logger.information(&soak.oversized, &.{}, &@src());

            continue;
        }

        logger.information(
            "soak steady-state entry",
            &.{
                .{ .key = "index", .value = .{ .unsigned = @rem(index, 1_000) } },
                .{ .key = "phase", .value = .{ .string = "steady-state" } },
                .{ .key = "ok", .value = .{ .boolean = true } },
            },
            &@src(),
        );
    }
}

fn drops_verify(drop_count: u64) error{DropsDiverged}!void {
    assert(drop_count <= thread_count * event_count);
    assert(event_count > 0);

    const per_thread = @divFloor(event_count - 1, oversized_interval) + 1;
    const expected = thread_count * per_thread;
    if (drop_count == expected) return;

    std.debug.print("soak failed: drops {d} != expected {d}\n", .{ drop_count, expected });

    return error.DropsDiverged;
}

fn report(result: *const Result) void {
    assert(result.elapsed_ns > 0);
    assert(result.drop_count > 0);

    const entry_count = thread_count * event_count;
    const per_entry_ns = @divFloor(result.elapsed_ns, entry_count);

    std.debug.print(
        "soak passed: threads={d} entries={d} elapsed_ms={d} ns/op={d} drops={d}\n",
        .{
            thread_count,
            entry_count,
            @divFloor(result.elapsed_ns, std.time.ns_per_ms),
            per_entry_ns,
            result.drop_count,
        },
    );
}
