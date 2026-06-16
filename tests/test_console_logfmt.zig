const std = @import("std");
const arc = @import("arc");

const Buffer = arc.buffer_mod.Buffer;
const Clock = arc.Clock;
const Config = arc.Config;
const EncoderConfig = arc.EncoderConfig;
const Logger = arc.Logger;

const Point = struct {
    x: i64,
    y: i64,

    pub fn marshal_log_object(self: *const Point, encoder: *arc.ObjectEncoder) void {
        encoder.add_int("x", self.x);
        encoder.add_int("y", self.y);
    }
};

const Pair = struct {
    a: i64,
    b: i64,
};

fn logfmt_logger(output: *Buffer) Logger {
    var logger = Logger.init_with_config(
        std.testing.io,
        Config.production()
            .with_level(.debug)
            .with_encoding(.console)
            .with_encoder_config(EncoderConfig.production().with_console_fields(.key_value))
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

fn contains(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}

test "logfmt console renders scalars as key=value" {
    var output = Buffer.init();
    var logger = logfmt_logger(&output);

    logger.info("hello", &.{
        arc.string("user", "alice"),
        arc.int("count", 5),
        arc.boolean("ok", true),
    }, @src());

    const text = output.contents();

    try std.testing.expect(contains(text, "user=\"alice\""));
    try std.testing.expect(contains(text, "count=5"));
    try std.testing.expect(contains(text, "ok=true"));
    try std.testing.expect(!contains(text, "{\"user\""));

    std.debug.assert(contains(text, "count=5"));
}

test "logfmt console flattens namespaces into dotted keys" {
    var output = Buffer.init();
    var logger = logfmt_logger(&output);

    logger.info("m", &.{
        arc.namespace("req"),
        arc.string("id", "x"),
        arc.int("code", 200),
    }, @src());

    const text = output.contents();

    try std.testing.expect(contains(text, "req.id=\"x\""));
    try std.testing.expect(contains(text, "req.code=200"));

    std.debug.assert(contains(text, "req.code=200"));
}

test "logfmt console renders lists as json arrays" {
    var output = Buffer.init();
    var logger = logfmt_logger(&output);

    logger.info("m", &.{arc.int_list("nums", &.{ 1, 2, 3 })}, @src());

    const text = output.contents();

    try std.testing.expect(contains(text, "nums=[1,2,3]"));

    std.debug.assert(contains(text, "nums=[1,2,3]"));
}

test "logfmt console renders dict, object, and reflect values as json" {
    var output = Buffer.init();
    var logger = logfmt_logger(&output);

    const point = Point{ .x = 1, .y = 2 };
    const pair = Pair{ .a = 3, .b = 4 };

    logger.info("m", &.{
        arc.dict("d", &.{arc.int("a", 1)}),
        arc.object("p", &point),
        arc.reflect("r", &pair),
    }, @src());

    const text = output.contents();

    try std.testing.expect(contains(text, "d={\"a\":1}"));
    try std.testing.expect(contains(text, "p={\"x\":1,\"y\":2}"));
    try std.testing.expect(contains(text, "r={\"a\":3,\"b\":4}"));

    std.debug.assert(contains(text, "p={\"x\":1,\"y\":2}"));
}

test "console defaults to the json field block" {
    var output = Buffer.init();
    var logger = Logger.init_with_config(
        std.testing.io,
        Config.production()
            .with_level(.debug)
            .with_encoding(.console)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    logger.info("m", &.{arc.string("k", "v")}, @src());

    const text = output.contents();

    try std.testing.expect(contains(text, "{\"k\":\"v\"}"));

    std.debug.assert(contains(text, "{\"k\":\"v\"}"));
}
