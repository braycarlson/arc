const std = @import("std");
const arc = @import("arc");

const Buffer = arc.buffer_mod.Buffer;
const BufferedWriter = arc.BufferedWriter;
const Clock = arc.Clock;
const Config = arc.Config;
const HookSet = arc.HookSet;
const Logger = arc.Logger;

const thread_count: u32 = 8;
const per_thread: u32 = 200;

const Worker = struct {
    logger: *Logger,
    iterations: u32,

    fn run(self: *Worker) void {
        var index: u32 = 0;

        while (index < self.iterations) : (index += 1) {
            self.logger.info("concurrent", &.{arc.int("index", @intCast(index))}, @src());
        }
    }
};

const DropWorker = struct {
    logger: *Logger,
    oversized: []const u8,
    iterations: u32,

    fn run(self: *DropWorker) void {
        var index: u32 = 0;

        while (index < self.iterations) : (index += 1) {
            self.logger.info(self.oversized, &.{}, @src());
        }
    }
};

test "concurrent logging through a thread-safe core loses no writes" {
    var counter = std.atomic.Value(u64).init(0);

    var logger = Logger.init_with_config(
        std.testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .nop = {} })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(true)
            .with_stacktrace_level(.fatal),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    var hooks = HookSet.init();
    hooks.add(.{ .counter = &counter });
    logger.set_hooks(hooks);

    var worker = Worker{ .logger = &logger, .iterations = per_thread };

    var threads: [thread_count]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    }

    for (&threads) |*thread| {
        thread.join();
    }

    const expected: u64 = @as(u64, thread_count) * @as(u64, per_thread);

    try std.testing.expectEqual(expected, counter.load(.monotonic));

    std.debug.assert(counter.load(.monotonic) == expected);
}

test "buffered writer flush thread starts, flushes, and stops cleanly" {
    var output = Buffer.init();
    var buffered = BufferedWriter.init(.{ .buffer = &output });

    try buffered.start_flusher(std.testing.io, 1_000_000);

    try buffered.write(std.testing.io, "first line\n");
    try buffered.write(std.testing.io, "second line\n");

    buffered.stop_flusher(std.testing.io);

    try std.testing.expect(output.contains("first line"));
    try std.testing.expect(output.contains("second line"));
    try std.testing.expectEqual(@as(u64, 0), buffered.error_count());

    std.debug.assert(buffered.error_count() == 0);
}

test "concurrent oversized entries accumulate the shared drop counter" {
    var drops = std.atomic.Value(u64).init(0);

    var logger = Logger.init_with_config(
        std.testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .nop = {} })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(true)
            .with_stacktrace_level(.fatal),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));
    logger.set_drop_counter(&drops);

    var oversized: [16384]u8 = undefined;
    @memset(&oversized, 'x');

    const drops_per_thread: u32 = 50;

    var worker = DropWorker{
        .logger = &logger,
        .oversized = &oversized,
        .iterations = drops_per_thread,
    };

    var threads: [thread_count]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, DropWorker.run, .{&worker});
    }

    for (&threads) |*thread| {
        thread.join();
    }

    const expected: u64 = @as(u64, thread_count) * @as(u64, drops_per_thread);

    try std.testing.expectEqual(expected, drops.load(.monotonic));

    std.debug.assert(drops.load(.monotonic) == expected);
}

test "concurrent writes through a thread-safe core are never interleaved" {
    var output = Buffer.init();

    var logger = Logger.init_with_config(
        std.testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(true)
            .with_stacktrace_level(.fatal),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    const lines_per_thread: u32 = 10;

    var worker = Worker{ .logger = &logger, .iterations = lines_per_thread };

    var threads: [thread_count]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    }

    for (&threads) |*thread| {
        thread.join();
    }

    try std.testing.expect(!output.was_truncated());

    var line_count: u32 = 0;
    var iterator = std.mem.splitScalar(u8, output.contents(), '\n');

    while (iterator.next()) |line| {
        if (line.len == 0) {
            continue;
        }

        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();

        try std.testing.expect(parsed.value == .object);
        line_count += 1;
    }

    const expected: u32 = thread_count * lines_per_thread;

    try std.testing.expectEqual(expected, line_count);

    std.debug.assert(line_count == expected);
}
