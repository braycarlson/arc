const std = @import("std");
const arc = @import("arc");

const Buffer = arc.buffer_mod.Buffer;
const Clock = arc.Clock;
const Config = arc.Config;
const Logger = arc.Logger;

fn truncation_logger(output: *Buffer) Logger {
    var logger = Logger.init_with_config(
        std.testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = output })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    return logger;
}

fn count_byte(text: []const u8, byte: u8) u32 {
    var total: u32 = 0;

    for (text) |character| {
        if (character == byte) total += 1;
    }

    return total;
}

test "oversized entry is replaced by a notice and counted as a drop" {
    var output = Buffer.init();
    var logger = truncation_logger(&output);

    var drops = std.atomic.Value(u64).init(0);
    logger.set_drop_counter(&drops);

    var oversized: [16384]u8 = undefined;
    @memset(&oversized, 'x');

    logger.info(&oversized, &.{}, @src());

    try std.testing.expectEqual(@as(u64, 1), drops.load(.monotonic));
    try std.testing.expect(output.contains("arc_truncated"));
    try std.testing.expect(!output.is_empty());
    try std.testing.expect(output.len() <= arc.buffer_mod.buffer_max);

    std.debug.assert(drops.load(.monotonic) == 1);
}

test "truncation notice is brace-balanced json" {
    var output = Buffer.init();
    var logger = truncation_logger(&output);

    var oversized: [16384]u8 = undefined;
    @memset(&oversized, 'y');

    logger.info(&oversized, &.{}, @src());

    const text = output.contents();

    try std.testing.expectEqual(count_byte(text, '{'), count_byte(text, '}'));
    try std.testing.expect(count_byte(text, '{') >= 1);

    std.debug.assert(count_byte(text, '{') == count_byte(text, '}'));
}

test "normal entry neither truncates nor counts a drop" {
    var output = Buffer.init();
    var logger = truncation_logger(&output);

    var drops = std.atomic.Value(u64).init(0);
    logger.set_drop_counter(&drops);

    logger.info("small message", &.{arc.string("key", "value")}, @src());

    try std.testing.expectEqual(@as(u64, 0), drops.load(.monotonic));
    try std.testing.expect(!output.contains("arc_truncated"));
    try std.testing.expect(output.contains("small message"));

    std.debug.assert(drops.load(.monotonic) == 0);
}

test "oversized field value truncates but keeps balanced output" {
    var output = Buffer.init();
    var logger = truncation_logger(&output);

    var drops = std.atomic.Value(u64).init(0);
    logger.set_drop_counter(&drops);

    var oversized: [16384]u8 = undefined;
    @memset(&oversized, 'z');

    logger.info("payload", &.{arc.string("body", &oversized)}, @src());

    const text = output.contents();

    try std.testing.expectEqual(@as(u64, 1), drops.load(.monotonic));
    try std.testing.expectEqual(count_byte(text, '{'), count_byte(text, '}'));

    std.debug.assert(drops.load(.monotonic) == 1);
}
