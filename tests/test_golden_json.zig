const std = @import("std");
const arc = @import("arc");

const Buffer = arc.buffer_mod.Buffer;
const Clock = arc.Clock;
const Config = arc.Config;
const EncoderConfig = arc.EncoderConfig;
const Field = arc.Field;
const Level = arc.Level;
const Logger = arc.Logger;

const fixed_timestamp_s: i64 = 1_700_000_000;

fn base_config() Config {
    return Config.production()
        .with_level(.debug)
        .without_sampling()
        .without_caller()
        .with_error_output(.{ .nop = {} })
        .with_thread_safety(false)
        .with_stacktrace_level(.fatal);
}

fn buffer_logger(output: *Buffer) Logger {
    var logger = Logger.init_with_config(
        std.testing.io,
        base_config().with_writer(.{ .buffer = output }),
    );

    logger.set_clock(Clock.init_fixed(fixed_timestamp_s));

    return logger;
}

fn config_logger(output: *Buffer, encoder_config: EncoderConfig) Logger {
    var logger = Logger.init_with_config(
        std.testing.io,
        base_config()
            .with_writer(.{ .buffer = output })
            .with_encoder_config(encoder_config),
    );

    logger.set_clock(Clock.init_fixed(fixed_timestamp_s));

    return logger;
}

fn expect_json(expected: []const u8, fields: []const Field) !void {
    var output = Buffer.init();
    var logger = buffer_logger(&output);

    logger.info("hello", fields, @src());

    try std.testing.expectEqualStrings(expected, output.contents());
}

fn expect_json_config(expected: []const u8, encoder_config: EncoderConfig, fields: []const Field) !void {
    var output = Buffer.init();
    var logger = config_logger(&output, encoder_config);

    logger.info("hello", fields, @src());

    try std.testing.expectEqualStrings(expected, output.contents());
}

test "golden: empty entry" {
    try expect_json("{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\"}\n", &.{});
}

test "golden: single string field" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"k\":\"v\"}\n",
        &.{arc.string("k", "v")},
    );
}

test "golden: byte_string is raw text" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"k\":\"raw\"}\n",
        &.{arc.byte_string("k", "raw")},
    );
}

test "golden: bool true and false" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"t\":true,\"f\":false}\n",
        &.{ arc.boolean("t", true), arc.boolean("f", false) },
    );
}

test "golden: signed integers" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"a\":42,\"b\":-42,\"c\":0}\n",
        &.{ arc.int("a", 42), arc.int("b", -42), arc.int("c", 0) },
    );
}

test "golden: i64 min" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"n\":-9223372036854775808}\n",
        &.{arc.int64("n", std.math.minInt(i64))},
    );
}

test "golden: u64 max" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"n\":18446744073709551615}\n",
        &.{arc.uint64("n", std.math.maxInt(u64))},
    );
}

test "golden: integer width variants share encoding" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"a\":1,\"b\":2,\"c\":3,\"d\":4}\n",
        &.{ arc.int8("a", 1), arc.int16("b", 2), arc.int32("c", 3), arc.int64("d", 4) },
    );
}

test "golden: unsigned width variants share encoding" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"a\":1,\"b\":2,\"c\":3,\"d\":4}\n",
        &.{ arc.uint8("a", 1), arc.uint16("b", 2), arc.uint32("c", 3), arc.uint64("d", 4) },
    );
}

test "golden: float whole number uses integer fast path" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"f\":3}\n",
        &.{arc.float64("f", 3.0)},
    );
}

test "golden: float fractional" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"f\":2.5}\n",
        &.{arc.float64("f", 2.5)},
    );
}

test "golden: float zero and negative zero" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"a\":0,\"b\":-0}\n",
        &.{ arc.float64("a", 0.0), arc.float64("b", -0.0) },
    );
}

test "golden: float non finite encodes as strings" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\"," ++
            "\"nan\":\"NaN\",\"pos\":\"+Inf\",\"neg\":\"-Inf\"}\n",
        &.{
            arc.float64("nan", std.math.nan(f64)),
            arc.float64("pos", std.math.inf(f64)),
            arc.float64("neg", -std.math.inf(f64)),
        },
    );
}

test "golden: float32 exact value" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"f\":2.5}\n",
        &.{arc.float32("f", 2.5)},
    );
}

test "golden: duration seconds default" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"d\":1.5}\n",
        &.{arc.duration_ns("d", 1_500_000_000)},
    );
}

test "golden: duration millis" {
    try expect_json_config(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"d\":1500}\n",
        EncoderConfig.production().with_duration_encoding(.millis),
        &.{arc.duration_ns("d", 1_500_000_000)},
    );
}

test "golden: duration nanos" {
    try expect_json_config(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"d\":1500000000}\n",
        EncoderConfig.production().with_duration_encoding(.nanos),
        &.{arc.duration_ns("d", 1_500_000_000)},
    );
}

test "golden: duration string units" {
    try expect_json_config(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\"," ++
            "\"a\":\"1m30s\",\"b\":\"1h1m1s\",\"c\":\"1.5s\",\"d\":\"500ms\",\"e\":\"250us\",\"f\":\"7ns\"}\n",
        EncoderConfig.production().with_duration_encoding(.string),
        &.{
            arc.duration_ns("a", 90_000_000_000),
            arc.duration_ns("b", 3_661_000_000_000),
            arc.duration_ns("c", 1_500_000_000),
            arc.duration_ns("d", 500_000_000),
            arc.duration_ns("e", 250_000),
            arc.duration_ns("f", 7),
        },
    );
}

test "golden: time_s epoch seconds" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"t\":1700000000}\n",
        &.{arc.time_s("t", 1_700_000_000)},
    );
}

test "golden: time_ns sub second precision" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"t\":1700000000.123456789}\n",
        &.{arc.time_ns("t", 1_700_000_000_123_456_789)},
    );
}

test "golden: binary base64" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"b\":\"aGVsbG8=\"}\n",
        &.{arc.binary("b", "hello")},
    );
}

test "golden: error field uses error key" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"error\":\"boom\"}\n",
        &.{arc.err("boom")},
    );
}

test "golden: named error" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"cause\":\"boom\"}\n",
        &.{arc.named_err("cause", "boom")},
    );
}

test "golden: err_from uses error name" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"error\":\"ConnectionRefused\"}\n",
        &.{arc.err_from(error.ConnectionRefused)},
    );
}

test "golden: skip field emits nothing" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"a\":\"1\"}\n",
        &.{ arc.skip(), arc.string("a", "1") },
    );
}

test "golden: string list" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"l\":[\"a\",\"b\",\"c\"]}\n",
        &.{arc.string_list("l", &.{ "a", "b", "c" })},
    );
}

test "golden: empty string list" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"l\":[]}\n",
        &.{arc.string_list("l", &.{})},
    );
}

test "golden: int list" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"l\":[1,-2,3]}\n",
        &.{arc.int_list("l", &.{ 1, -2, 3 })},
    );
}

test "golden: uint list" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"l\":[1,2,3]}\n",
        &.{arc.uints("l", &.{ 1, 2, 3 })},
    );
}

test "golden: float list" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"l\":[1,2.5,3]}\n",
        &.{arc.float_list("l", &.{ 1.0, 2.5, 3.0 })},
    );
}

test "golden: bool list" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"l\":[true,false]}\n",
        &.{arc.bool_list("l", &.{ true, false })},
    );
}

test "golden: duration list seconds" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"l\":[1,2]}\n",
        &.{arc.durations("l", &.{ 1_000_000_000, 2_000_000_000 })},
    );
}

test "golden: time list epoch ns" {
    try expect_json_config(
        "{\"level\":\"info\",\"ts\":1700000000000000000,\"msg\":\"hello\"," ++
            "\"l\":[1000000000,2000000000]}\n",
        EncoderConfig.production().with_time_encoding(.epoch_ns),
        &.{arc.times("l", &.{ 1_000_000_000, 2_000_000_000 })},
    );
}

test "golden: namespace wraps later fields" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"ns\":{\"a\":\"1\",\"b\":2}}\n",
        &.{ arc.namespace("ns"), arc.string("a", "1"), arc.int("b", 2) },
    );
}

test "golden: dict encodes inline object" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\"," ++
            "\"cfg\":{\"host\":\"localhost\",\"port\":8080}}\n",
        &.{arc.dict("cfg", &.{ arc.string("host", "localhost"), arc.int("port", 8080) })},
    );
}

test "golden: escape quote and backslash" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"k\":\"a\\\"b\\\\c\"}\n",
        &.{arc.string("k", "a\"b\\c")},
    );
}

test "golden: escape control whitespace" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"k\":\"\\n\\r\\t\\b\\f\"}\n",
        &.{arc.string("k", "\n\r\t\x08\x0c")},
    );
}

test "golden: escape low control as unicode" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"k\":\"\\u0001\\u001f\"}\n",
        &.{arc.string("k", "\x01\x1f")},
    );
}

test "golden: multibyte utf8 passes through" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"k\":\"\u{00E9}\u{20AC}\"}\n",
        &.{arc.string("k", "\u{00E9}\u{20AC}")},
    );
}

test "golden: astral plane becomes surrogate pair" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"k\":\"\\ud83d\\ude00\"}\n",
        &.{arc.string("k", "\u{1F600}")},
    );
}

test "golden: invalid utf8 byte escaped" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"k\":\"\\u00ff\"}\n",
        &.{arc.string("k", "\xff")},
    );
}

test "golden: key needing escape is escaped" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"a\\\"b\":\"v\"}\n",
        &.{arc.string("a\"b", "v")},
    );
}

test "golden: empty string value" {
    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"k\":\"\"}\n",
        &.{arc.string("k", "")},
    );
}

test "golden: time epoch_ms" {
    try expect_json_config(
        "{\"level\":\"info\",\"ts\":1700000000000,\"msg\":\"hello\"}\n",
        EncoderConfig.production().with_time_encoding(.epoch_ms),
        &.{},
    );
}

test "golden: time epoch_ns" {
    try expect_json_config(
        "{\"level\":\"info\",\"ts\":1700000000000000000,\"msg\":\"hello\"}\n",
        EncoderConfig.production().with_time_encoding(.epoch_ns),
        &.{},
    );
}

test "golden: time iso8601" {
    try expect_json_config(
        "{\"level\":\"info\",\"ts\":\"2023-11-14T22:13:20Z\",\"msg\":\"hello\"}\n",
        EncoderConfig.production().with_time_encoding(.iso8601),
        &.{},
    );
}

test "golden: time rfc3339" {
    try expect_json_config(
        "{\"level\":\"info\",\"ts\":\"2023-11-14T22:13:20Z\",\"msg\":\"hello\"}\n",
        EncoderConfig.production().with_time_encoding(.rfc3339),
        &.{},
    );
}

test "golden: time iso8601 with offset" {
    try expect_json_config(
        "{\"level\":\"info\",\"ts\":\"2023-11-15T03:43:20+05:30\",\"msg\":\"hello\"}\n",
        EncoderConfig.production().with_time_encoding(.iso8601).with_time_offset(330),
        &.{},
    );
}

test "golden: level uppercase" {
    try expect_json_config(
        "{\"level\":\"INFO\",\"ts\":1700000000,\"msg\":\"hello\"}\n",
        EncoderConfig.production().with_level_encoding(.uppercase),
        &.{},
    );
}

test "golden: level capital color ignored in json" {
    try expect_json_config(
        "{\"level\":\"INFO\",\"ts\":1700000000,\"msg\":\"hello\"}\n",
        EncoderConfig.production().with_level_encoding(.capital_color),
        &.{},
    );
}

test "golden: message key rename" {
    try expect_json_config(
        "{\"level\":\"info\",\"ts\":1700000000,\"message\":\"hello\"}\n",
        EncoderConfig.production().with_message_key("message"),
        &.{},
    );
}

test "golden: omit level key" {
    try expect_json_config(
        "{\"ts\":1700000000,\"msg\":\"hello\"}\n",
        EncoderConfig.production().with_level_key(""),
        &.{},
    );
}

test "golden: omit time key" {
    try expect_json_config(
        "{\"level\":\"info\",\"msg\":\"hello\"}\n",
        EncoderConfig.production().with_time_key(""),
        &.{},
    );
}

test "golden: omit message key" {
    try expect_json_config(
        "{\"level\":\"info\",\"ts\":1700000000}\n",
        EncoderConfig.production().with_message_key(""),
        &.{},
    );
}

test "golden: line ending none" {
    var encoder_config = EncoderConfig.production();
    encoder_config.line_ending = .none;

    try expect_json_config(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\"}",
        encoder_config,
        &.{},
    );
}

test "golden: logger name in envelope" {
    var output = Buffer.init();
    var logger = buffer_logger(&output);

    var named = logger.named("svc");
    named.info("hello", &.{}, @src());

    try std.testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"logger\":\"svc\",\"msg\":\"hello\"}\n",
        output.contents(),
    );
}

test "golden: context with single field" {
    var output = Buffer.init();
    var logger = buffer_logger(&output);

    var child = logger.with(&.{arc.string("a", "1")});
    child.info("hello", &.{arc.string("b", "2")}, @src());

    try std.testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"a\":\"1\",\"b\":\"2\"}\n",
        output.contents(),
    );
}

test "golden: truncation notice" {
    var output = Buffer.init();
    var logger = buffer_logger(&output);

    logger.info("hello", &.{arc.string("big", "a" ** 9000)}, @src());

    try std.testing.expectEqualStrings(
        "{\"level\":\"info\",\"msg\":\"log entry exceeded buffer capacity and was dropped\"," ++
            "\"arc_truncated\":true}\n",
        output.contents(),
    );
}

test "golden: caller short path is deterministic" {
    try std.testing.expectEqualStrings(
        "core/entry.zig",
        arc.entry_mod.caller_short_path("/home/user/src/core/entry.zig"),
    );
}

const Address = struct {
    city: []const u8,
    zip_code: u32,

    pub fn marshal_log_object(self: *const Address, encoder: *arc.ObjectEncoder) void {
        encoder.add_string("city", self.city);
        encoder.add_uint("zip", self.zip_code);
    }
};

const Tags = struct {
    items: []const []const u8,

    pub fn marshal_log_array(self: *const Tags, encoder: *arc.ArrayEncoder) void {
        for (self.items) |item| {
            encoder.append_string(item);
        }
    }
};

const Metrics = struct {
    cpu: f64,
    cores: u32,
    active: bool,
    name: []const u8,
};

const Color = enum { red, green, blue };

const Labeled = struct {
    text: []const u8,

    pub fn to_string(self: *const Labeled) []const u8 {
        return self.text;
    }
};

test "golden: object marshaler" {
    const address = Address{ .city = "denver", .zip_code = 80014 };

    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\"," ++
            "\"addr\":{\"city\":\"denver\",\"zip\":80014}}\n",
        &.{arc.object("addr", &address)},
    );
}

test "golden: inline object merges into parent" {
    const address = Address{ .city = "boulder", .zip_code = 80301 };

    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\"," ++
            "\"city\":\"boulder\",\"zip\":80301,\"trailing\":\"x\"}\n",
        &.{ arc.inline_object(&address), arc.string("trailing", "x") },
    );
}

test "golden: array marshaler" {
    const tags = Tags{ .items = &.{ "a", "b", "c" } };

    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"tags\":[\"a\",\"b\",\"c\"]}\n",
        &.{arc.array("tags", &tags)},
    );
}

test "golden: reflect struct" {
    const metrics = Metrics{ .cpu = 0.5, .cores = 8, .active = true, .name = "node-1" };

    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\"," ++
            "\"m\":{\"cpu\":0.5,\"cores\":8,\"active\":true,\"name\":\"node-1\"}}\n",
        &.{arc.reflect("m", &metrics)},
    );
}

test "golden: reflect slice and enum" {
    const nums = [_]u32{ 1, 2, 3 };
    const color: Color = .green;

    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"nums\":[1,2,3],\"color\":\"green\"}\n",
        &.{ arc.reflect("nums", &nums), arc.reflect("color", &color) },
    );
}

test "golden: reflect optional" {
    const present: ?u32 = 7;
    const absent: ?u32 = null;

    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"a\":7,\"b\":null}\n",
        &.{ arc.reflect("a", &present), arc.reflect("b", &absent) },
    );
}

test "golden: stringer" {
    const labeled = Labeled{ .text = "v1.2.3" };

    try expect_json(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"version\":\"v1.2.3\"}\n",
        &.{arc.stringer("version", &labeled)},
    );
}
