const std = @import("std");
const arc = @import("arc");

const assert = std.debug.assert;

const Clock = arc.Clock;
const Config = arc.Config;
const Logger = arc.Logger;

const thread_count: u32 = 8;
const thread_events_count: u64 = 625_000;
const oversize_entry_interval: u64 = 100_000;

comptime {
    assert(thread_count > 0);
    assert(thread_events_count > 0);
    assert(oversize_entry_interval > 0);
    assert(oversize_entry_interval < thread_events_count);
}

const Worker = struct {
    logger: *Logger,
    oversized: []const u8,

    fn run(self: *Worker) void {
        assert(self.oversized.len > 0);

        var index: u64 = 0;

        while (index < thread_events_count) : (index += 1) {
            if (index % oversize_entry_interval == 0) {
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
    return (thread_events_count - 1) / oversize_entry_interval + 1;
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

    run_workers(&worker);

    const end_ns = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    const elapsed_ns: u64 = @intCast(end_ns - start_ns);
    const entries_total: u64 = @as(u64, thread_count) * thread_events_count;

    verify_drops(drops.load(.monotonic));
    report(elapsed_ns, entries_total, drops.load(.monotonic));
}

fn run_workers(worker: *Worker) void {
    assert(worker.oversized.len > 0);

    var threads: [thread_count]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = std.Thread.spawn(.{}, Worker.run, .{worker}) catch |spawn_error| {
            std.debug.print("soak FAIL: spawn error {s}\n", .{@errorName(spawn_error)});

            std.process.exit(1);
        };
    }

    for (&threads) |*thread| {
        thread.join();
    }
}

fn verify_drops(observed_drops: u64) void {
    assert(thread_count > 0);

    const expected_drops: u64 = @as(u64, thread_count) * injections_per_thread();

    if (observed_drops == expected_drops) {
        return;
    }

    std.debug.print(
        "soak FAIL: drops {d} != expected {d}\n",
        .{ observed_drops, expected_drops },
    );

    std.process.exit(1);
}

fn report(elapsed_ns: u64, entries_total: u64, observed_drops: u64) void {
    assert(entries_total > 0);
    assert(observed_drops <= entries_total);

    const ns_per_op = if (entries_total > 0) elapsed_ns / entries_total else 0;
    const ops_per_sec = if (ns_per_op > 0) 1_000_000_000 / ns_per_op else 0;

    std.debug.print(
        "soak OK: threads={d} entries={d} elapsed_ms={d} ns/op={d} ops/sec={d} drops={d}\n",
        .{
            thread_count,
            entries_total,
            elapsed_ns / 1_000_000,
            ns_per_op,
            ops_per_sec,
            observed_drops,
        },
    );
}
