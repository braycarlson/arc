const std = @import("std");
const arc = @import("arc");

const Clock = arc.Clock;
const Config = arc.Config;
const Logger = arc.Logger;

const thread_count: u32 = 8;
const per_thread: u64 = 625_000;
const oversize_interval: u64 = 100_000;

const Worker = struct {
    logger: *Logger,
    oversized: []const u8,

    fn run(self: *Worker) void {
        var index: u64 = 0;

        while (index < per_thread) : (index += 1) {
            if (index % oversize_interval == 0) {
                self.logger.info(self.oversized, &.{}, @src());
            } else {
                self.logger.info("soak steady-state entry", &.{
                    arc.int("index", @intCast(index % 1000)),
                    arc.string("phase", "steady-state"),
                    arc.boolean("ok", true),
                }, @src());
            }
        }
    }
};

fn injections_per_thread() u64 {
    return (per_thread - 1) / oversize_interval + 1;
}

pub fn main() void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();

    const io = threaded.io();

    var logger = Logger.init_with_config(
        io,
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

    var drops = std.atomic.Value(u64).init(0);
    logger.set_drop_counter(&drops);

    var oversized: [16384]u8 = undefined;
    @memset(&oversized, 'x');

    var worker = Worker{ .logger = &logger, .oversized = &oversized };

    const start_ns = std.Io.Timestamp.now(io, .awake).toNanoseconds();

    var threads: [thread_count]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = std.Thread.spawn(.{}, Worker.run, .{&worker}) catch |err| {
            std.debug.print("soak FAIL: spawn error {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    }

    for (&threads) |*thread| {
        thread.join();
    }

    const end_ns = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    const elapsed_ns: u64 = @intCast(end_ns - start_ns);

    const entries_total: u64 = @as(u64, thread_count) * per_thread;
    const expected_drops: u64 = @as(u64, thread_count) * injections_per_thread();
    const observed_drops = drops.load(.monotonic);

    if (observed_drops != expected_drops) {
        std.debug.print(
            "soak FAIL: drops {d} != expected {d}\n",
            .{ observed_drops, expected_drops },
        );
        std.process.exit(1);
    }

    const ns_per_op = if (entries_total > 0) elapsed_ns / entries_total else 0;
    const ops_per_sec = if (ns_per_op > 0) 1_000_000_000 / ns_per_op else 0;

    std.debug.print(
        "soak OK: threads={d} entries={d} elapsed_ms={d} ns/op={d} ops/sec={d} drops={d}\n",
        .{ thread_count, entries_total, elapsed_ns / 1_000_000, ns_per_op, ops_per_sec, observed_drops },
    );
}
