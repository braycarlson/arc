const std = @import("std");
const arc = @import("arc");

const Buffer = arc.buffer_mod.Buffer;
const Clock = arc.Clock;
const Config = arc.Config;
const EncoderConfig = arc.EncoderConfig;
const Field = arc.Field;
const Logger = arc.Logger;

const fixed_timestamp_s: i64 = 1_700_000_000;

fn base_config() Config {
    return Config.production()
        .with_encoding(.console)
        .with_level(.debug)
        .without_sampling()
        .without_caller()
        .with_error_output(.{ .nop = {} })
        .with_thread_safety(false)
        .with_stacktrace_level(.fatal);
}

fn console_logger(output: *Buffer, encoder_config: EncoderConfig) Logger {
    var logger = Logger.init_with_config(
        std.testing.io,
        base_config()
            .with_writer(.{ .buffer = output })
            .with_encoder_config(encoder_config),
    );

    logger.set_clock(Clock.init_fixed(fixed_timestamp_s));

    return logger;
}

fn expect_console(expected: []const u8, encoder_config: EncoderConfig, fields: []const Field) !void {
    var output = Buffer.init();
    var logger = console_logger(&output, encoder_config);

    logger.info("hello", fields, @src());

    try std.testing.expectEqualStrings(expected, output.contents());
}

test "golden console: minimal envelope" {
    try expect_console(
        "1700000000\tinfo\thello\n",
        EncoderConfig.production(),
        &.{},
    );
}

test "golden console: json fields wrapper" {
    try expect_console(
        "1700000000\tinfo\thello\t{\"k\":\"v\",\"n\":42}\n",
        EncoderConfig.production(),
        &.{ arc.string("k", "v"), arc.int("n", 42) },
    );
}

test "golden console: key_value single field" {
    try expect_console(
        "1700000000\tinfo\thello\tk=\"v\"\n",
        EncoderConfig.production().with_console_fields(.key_value),
        &.{arc.string("k", "v")},
    );
}

test "golden console: key_value multiple fields space separated" {
    try expect_console(
        "1700000000\tinfo\thello\ta=\"1\" b=2\n",
        EncoderConfig.production().with_console_fields(.key_value),
        &.{ arc.string("a", "1"), arc.int("b", 2) },
    );
}

test "golden console: key_value namespace prefix" {
    try expect_console(
        "1700000000\tinfo\thello\tns.a=\"1\"\n",
        EncoderConfig.production().with_console_fields(.key_value),
        &.{ arc.namespace("ns"), arc.string("a", "1") },
    );
}

test "golden console: level color" {
    try expect_console(
        "1700000000\t\x1b[34mINFO\x1b[0m\thello\n",
        EncoderConfig.production().with_level_encoding(.capital_color),
        &.{},
    );
}

test "golden console: iso8601 timestamp" {
    try expect_console(
        "2023-11-14T22:13:20Z\tinfo\thello\n",
        EncoderConfig.production().with_time_encoding(.iso8601),
        &.{},
    );
}

test "golden console: logger name segment" {
    var output = Buffer.init();
    var logger = console_logger(&output, EncoderConfig.production());

    var named = logger.named("svc");
    named.info("hello", &.{}, @src());

    try std.testing.expectEqualStrings("1700000000\tinfo\tsvc\thello\n", output.contents());
}

test "golden console: truncation notice" {
    var output = Buffer.init();
    var logger = console_logger(&output, EncoderConfig.production());

    logger.info("hello", &.{arc.string("big", "a" ** 9000)}, @src());

    try std.testing.expectEqualStrings(
        "info\tlog entry exceeded buffer capacity and was dropped\n",
        output.contents(),
    );
}
