const std = @import("std");
const arc = @import("arc");

const Buffer = arc.buffer_mod.Buffer;
const Clock = arc.Clock;
const Config = arc.Config;
const Logger = arc.Logger;
const Smith = std.testing.Smith;
const Encoding = arc.encoder_mod.Encoding;
const EncoderConfig = arc.EncoderConfig;
const TimeEncoding = arc.encoder_config_mod.TimeEncoding;
const DurationEncoding = arc.encoder_config_mod.DurationEncoding;
const Field = arc.Field;

// Bias the byte stream toward the inputs that stress the JSON escaper:
// quotes, backslashes, control characters, and UTF-8 lead/continuation bytes.
const byte_weights = [_]Smith.Weight{
    .rangeAtMost(u8, 0x00, 0xff, 2),
    .rangeAtMost(u8, 0x00, 0x1f, 4),
    .value(u8, '"', 6),
    .value(u8, '\\', 6),
    .rangeAtMost(u8, 0x80, 0xbf, 3),
    .rangeAtMost(u8, 0xc0, 0xf7, 3),
};

const level_weights = [_]Smith.Weight{
    .rangeAtMost(u8, 'a', 'z', 4),
    .rangeAtMost(u8, 'A', 'Z', 2),
    .rangeAtMost(u8, 0x00, 0xff, 1),
};

// Seeds so the suite still exercises nasty inputs under a plain `zig build test`
// (without `--fuzz`), not only during a dedicated fuzzing run.
const seeds = [_][]const u8{
    "",
    "\"\\\n\r\t",
    "\x00\x01\x1f",
    "\xff\xfe\xc0\x80",
    "\xf0\x9f\x98\x80",
    "plain ascii text",
    "}{][:,",
};

fn fuzz_logger(output: *Buffer) Logger {
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

fn expect_valid_json_object(text: []const u8) !void {
    const line = trimmed_line(text);

    try std.testing.expect(line.len > 0);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
}

fn fuzz_string_value(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();

    var input: [1024]u8 = undefined;
    const length = smith.sliceWeightedBytes(&input, &byte_weights);

    var output = Buffer.init();
    var logger = fuzz_logger(&output);

    logger.info("message", &.{arc.string("field", input[0..length])}, @src());

    try expect_valid_json_object(output.contents());
}

fn fuzz_message(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();

    var input: [1024]u8 = undefined;
    const length = smith.sliceWeightedBytes(&input, &byte_weights);

    var output = Buffer.init();
    var logger = fuzz_logger(&output);

    logger.info(input[0..length], &.{}, @src());

    try expect_valid_json_object(output.contents());
}

fn fuzz_key(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();

    var input: [128]u8 = undefined;
    const length = smith.sliceWeightedBytes(&input, &byte_weights);

    if (length == 0) {
        return;
    }

    var output = Buffer.init();
    var logger = fuzz_logger(&output);

    logger.info("message", &.{arc.string(input[0..length], "value")}, @src());

    try expect_valid_json_object(output.contents());
}

fn fuzz_binary(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();

    var input: [1024]u8 = undefined;
    const length = smith.sliceWeightedBytes(&input, &byte_weights);

    var output = Buffer.init();
    var logger = fuzz_logger(&output);

    logger.info("message", &.{arc.binary("payload", input[0..length])}, @src());

    try expect_valid_json_object(output.contents());
}

fn fuzz_parse_level(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();

    var input: [16]u8 = undefined;
    const length = smith.sliceWeightedBytes(&input, &level_weights);

    if (length == 0) {
        return;
    }

    _ = arc.level_mod.parse_level(input[0..length]) catch {};
}

test "fuzz: arbitrary string field value stays valid json" {
    try std.testing.fuzz({}, fuzz_string_value, .{ .corpus = &seeds });
}

test "fuzz: arbitrary message stays valid json" {
    try std.testing.fuzz({}, fuzz_message, .{ .corpus = &seeds });
}

test "fuzz: arbitrary field key stays valid json" {
    try std.testing.fuzz({}, fuzz_key, .{ .corpus = &seeds });
}

test "fuzz: arbitrary binary value stays valid json" {
    try std.testing.fuzz({}, fuzz_binary, .{ .corpus = &seeds });
}

test "fuzz: parse_level never crashes" {
    try std.testing.fuzz({}, fuzz_parse_level, .{ .corpus = &seeds });
}

test "regression: ill-formed utf8 still yields valid json" {
    const cases = [_][]const u8{
        "\xc0\xa9", // overlong 2-byte encoding of ')'
        "\xe0\x80\xaf", // overlong 3-byte encoding of '/'
        "\xf0\x80\x80\xa0", // overlong 4-byte sequence
        "\xed\xa0\x80", // UTF-16 surrogate U+D800
        "\xf4\x90\x80\x80", // codepoint above U+10FFFF
        "\x80", // bare continuation byte
        "\xc3", // truncated lead byte
        "\xc3\xa9", // well-formed: U+00E9, must pass through
        "ok\xc0\xa9end", // ill-formed embedded in ascii
    };

    for (cases) |case| {
        var output = Buffer.init();
        var logger = fuzz_logger(&output);

        logger.info("message", &.{arc.string("field", case)}, @src());

        try expect_valid_json_object(output.contents());
    }
}

const time_encodings = [_]TimeEncoding{ .epoch_s, .epoch_ms, .epoch_ns, .iso8601, .rfc3339 };
const duration_encodings = [_]DurationEncoding{ .seconds, .millis, .nanos, .string };
const encodings = [_]Encoding{ .json, .console };
const offsets = [_]i32{ 0, 330, -300, 1439, -1439 };

// Boundary values that a random byte stream almost never lands on but that
// historically crashed the time and duration encoders: i64 negation overflow in
// write_epoch_scaled and the time_s * nanos_per_second multiply. The harness is
// not coverage-guided, so these are pinned explicitly rather than left to chance.
const i64_boundaries = [_]i64{
    std.math.minInt(i64),
    std.math.minInt(i64) + 1,
    -9_223_372_037,
    -9_223_372_036,
    -1,
    0,
    1,
    9_223_372_036,
    9_223_372_037,
    1_700_000_000,
    std.math.maxInt(i64) - 1,
    std.math.maxInt(i64),
};

const u64_boundaries = [_]u64{
    0,
    1,
    9_223_372_036_854_775_807,
    9_223_372_036_854_775_808,
    std.math.maxInt(u64),
};

const f64_boundaries = [_]f64{
    -std.math.inf(f64),
    std.math.inf(f64),
    std.math.nan(f64),
    -0.0,
    0.0,
    1.5,
    -1.5,
    std.math.floatMax(f64),
    -std.math.floatMax(f64),
    std.math.floatMin(f64),
};

fn config_logger(
    output: *Buffer,
    encoding: Encoding,
    time_encoding: TimeEncoding,
    duration_encoding: DurationEncoding,
    offset_minutes: i32,
) Logger {
    const encoder_config = EncoderConfig.production()
        .with_time_encoding(time_encoding)
        .with_duration_encoding(duration_encoding)
        .with_time_offset(offset_minutes);

    var logger = Logger.init_with_config(
        std.testing.io,
        Config.production()
            .with_level(.debug)
            .with_encoding(encoding)
            .with_encoder_config(encoder_config)
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

fn expect_encoded(output: *const Buffer, encoding: Encoding) !void {
    if (encoding == .json) {
        try expect_valid_json_object(output.contents());
    } else {
        try std.testing.expect(!output.is_empty());
    }
}

fn check_field(
    encoding: Encoding,
    time_encoding: TimeEncoding,
    duration_encoding: DurationEncoding,
    offset_minutes: i32,
    field: Field,
) !void {
    var output = Buffer.init();
    var logger = config_logger(&output, encoding, time_encoding, duration_encoding, offset_minutes);

    logger.info("message", &.{field}, @src());

    try expect_encoded(&output, encoding);
}

fn numeric_field(smith: *Smith) Field {
    return switch (smith.index(6)) {
        0 => arc.int64("v", smith.value(i64)),
        1 => arc.uint64("v", smith.value(u64)),
        2 => arc.float64("v", smith.value(f64)),
        3 => arc.duration_ns("v", smith.value(i64)),
        4 => arc.time_s("v", smith.value(i64)),
        else => arc.time_ns("v", smith.value(i64)),
    };
}

fn multi_field(smith: *Smith, key: []const u8, text: []u8) Field {
    return switch (smith.index(7)) {
        0 => arc.string(key, text[0..smith.sliceWeightedBytes(text, &byte_weights)]),
        1 => arc.int64(key, smith.value(i64)),
        2 => arc.uint64(key, smith.value(u64)),
        3 => arc.float64(key, smith.value(f64)),
        4 => arc.boolean(key, smith.boolWeighted(1, 1)),
        5 => arc.namespace(key),
        else => arc.time_ns(key, smith.value(i64)),
    };
}

fn fuzz_numeric_temporal(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();

    const encoding = encodings[smith.index(encodings.len)];
    const time_encoding = time_encodings[smith.index(time_encodings.len)];
    const duration_encoding = duration_encodings[smith.index(duration_encodings.len)];
    const offset_minutes = smith.valueRangeAtMost(i32, -1439, 1439);

    var output = Buffer.init();
    var logger = config_logger(&output, encoding, time_encoding, duration_encoding, offset_minutes);

    logger.info("message", &.{numeric_field(smith)}, @src());

    try expect_encoded(&output, encoding);
}

fn fuzz_console(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();

    var input: [1024]u8 = undefined;
    const length = smith.sliceWeightedBytes(&input, &byte_weights);

    const time_encoding = time_encodings[smith.index(time_encodings.len)];
    const offset_minutes = smith.valueRangeAtMost(i32, -1439, 1439);

    var output = Buffer.init();
    var logger = config_logger(&output, .console, time_encoding, .string, offset_minutes);

    logger.info(
        "message",
        &.{ arc.string("field", input[0..length]), arc.time_ns("at", smith.value(i64)) },
        @src(),
    );

    try std.testing.expect(!output.is_empty());
}

fn fuzz_multi_field(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();

    var fields: [arc.fields_max]Field = undefined;
    var keys: [arc.fields_max][8]u8 = undefined;
    var texts: [arc.fields_max][16]u8 = undefined;

    const count = smith.index(arc.fields_max + 1);

    var index: usize = 0;

    while (index < count) : (index += 1) {
        const key_length = 1 + smith.index(keys[index].len);
        smith.bytes(keys[index][0..key_length]);

        fields[index] = multi_field(smith, keys[index][0..key_length], texts[index][0..]);
    }

    var output = Buffer.init();
    var logger = config_logger(&output, .json, .epoch_s, .seconds, 0);

    logger.info("message", fields[0..count], @src());

    try expect_valid_json_object(output.contents());
}

fn fuzz_truncation(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();

    var input: [12288]u8 = undefined;
    const length = smith.sliceWeightedBytes(&input, &byte_weights);

    var output = Buffer.init();
    var logger = fuzz_logger(&output);

    logger.info("message", &.{arc.string("field", input[0..length])}, @src());

    try expect_valid_json_object(output.contents());
}

test "regression: boundary numeric and temporal values never crash" {
    for (encodings) |encoding| {
        for (offsets) |offset| {
            for (time_encodings) |time_encoding| {
                for (i64_boundaries) |value| {
                    try check_field(encoding, time_encoding, .seconds, offset, arc.time_ns("t", value));
                    try check_field(encoding, time_encoding, .seconds, offset, arc.time_s("t", value));
                    try check_field(encoding, time_encoding, .seconds, offset, arc.int64("i", value));
                }
            }

            for (duration_encodings) |duration_encoding| {
                for (i64_boundaries) |value| {
                    try check_field(encoding, .epoch_s, duration_encoding, offset, arc.duration_ns("d", value));
                }
            }

            for (u64_boundaries) |value| {
                try check_field(encoding, .epoch_s, .seconds, offset, arc.uint64("u", value));
            }

            for (f64_boundaries) |value| {
                try check_field(encoding, .epoch_s, .seconds, offset, arc.float64("f", value));
            }
        }
    }
}

test "fuzz: numeric and temporal fields survive every encoder" {
    try std.testing.fuzz({}, fuzz_numeric_temporal, .{ .corpus = &seeds });
}

test "fuzz: console encoder never crashes" {
    try std.testing.fuzz({}, fuzz_console, .{ .corpus = &seeds });
}

test "fuzz: multi field entries stay valid json" {
    try std.testing.fuzz({}, fuzz_multi_field, .{ .corpus = &seeds });
}

test "fuzz: oversized fields truncate to valid json" {
    try std.testing.fuzz({}, fuzz_truncation, .{ .corpus = &seeds });
}

fn trimmed_line(text: []const u8) []const u8 {
    var line = text;

    while (line.len > 0 and (line[line.len - 1] == '\n' or line[line.len - 1] == '\r')) {
        line = line[0 .. line.len - 1];
    }

    return line;
}

fn parse_object(text: []const u8) !std.json.Parsed(std.json.Value) {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        trimmed_line(text),
        .{},
    );
    errdefer parsed.deinit();

    try std.testing.expect(parsed.value == .object);

    return parsed;
}

// Round-trip fuzzing: validity is necessary but not sufficient. A bug in the
// escaper, surrogate-pair math, or base64 can emit well-formed JSON whose decoded
// value differs from the input. These targets encode a value, parse it back, and
// assert the recovered value equals the original.
fn fuzz_roundtrip_string(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();

    var input: [1024]u8 = undefined;
    const length = smith.sliceWeightedBytes(&input, &byte_weights);
    const value = input[0..length];

    // Escaping is lossless only for well-formed UTF-8; ill-formed bytes are
    // deliberately rewritten to \u00XX, so exact round-trip does not apply.
    if (!std.unicode.utf8ValidateSlice(value)) {
        return;
    }

    var output = Buffer.init();
    var logger = fuzz_logger(&output);

    logger.info("message", &.{arc.string("field", value)}, @src());

    const parsed = try parse_object(output.contents());
    defer parsed.deinit();

    const node = parsed.value.object.get("field") orelse return error.MissingField;

    try std.testing.expect(node == .string);
    try std.testing.expectEqualSlices(u8, value, node.string);
}

fn fuzz_roundtrip_binary(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();

    var input: [1024]u8 = undefined;
    const length = smith.sliceWeightedBytes(&input, &byte_weights);
    const value = input[0..length];

    var output = Buffer.init();
    var logger = fuzz_logger(&output);

    logger.info("message", &.{arc.binary("payload", value)}, @src());

    const parsed = try parse_object(output.contents());
    defer parsed.deinit();

    const node = parsed.value.object.get("payload") orelse return error.MissingField;

    try std.testing.expect(node == .string);

    const decoder = std.base64.standard.Decoder;
    const decoded_length = try decoder.calcSizeForSlice(node.string);

    try std.testing.expectEqual(length, decoded_length);

    var decoded: [1024]u8 = undefined;
    try decoder.decode(decoded[0..decoded_length], node.string);

    try std.testing.expectEqualSlices(u8, value, decoded[0..decoded_length]);
}

fn fuzz_roundtrip_number(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();

    var output = Buffer.init();
    var logger = fuzz_logger(&output);

    switch (smith.index(3)) {
        0 => {
            const value = smith.value(i64);
            logger.info("message", &.{arc.int64("v", value)}, @src());
            try expect_signed_text(output.contents(), value);
        },
        1 => {
            const value = smith.value(u64);
            logger.info("message", &.{arc.uint64("v", value)}, @src());
            try expect_unsigned_text(output.contents(), value);
        },
        else => {
            const value = smith.value(f64);
            logger.info("message", &.{arc.float64("v", value)}, @src());
            try expect_float_roundtrip(output.contents(), value);
        },
    }
}

fn expect_signed_text(output: []const u8, value: i64) !void {
    var scratch: [32]u8 = undefined;
    const expected = try std.fmt.bufPrint(&scratch, "\"v\":{d}", .{value});

    try std.testing.expect(std.mem.indexOf(u8, output, expected) != null);
}

fn expect_unsigned_text(output: []const u8, value: u64) !void {
    var scratch: [32]u8 = undefined;
    const expected = try std.fmt.bufPrint(&scratch, "\"v\":{d}", .{value});

    try std.testing.expect(std.mem.indexOf(u8, output, expected) != null);
}

fn expect_float_roundtrip(output: []const u8, value: f64) !void {
    const parsed = try parse_object(output);
    defer parsed.deinit();

    const node = parsed.value.object.get("v") orelse return error.MissingField;

    if (std.math.isNan(value)) {
        try std.testing.expect(node == .string);
        try std.testing.expectEqualSlices(u8, "NaN", node.string);
        return;
    }

    if (std.math.isPositiveInf(value)) {
        try std.testing.expect(node == .string);
        try std.testing.expectEqualSlices(u8, "+Inf", node.string);
        return;
    }

    if (std.math.isNegativeInf(value)) {
        try std.testing.expect(node == .string);
        try std.testing.expectEqualSlices(u8, "-Inf", node.string);
        return;
    }

    const decoded: f64 = switch (node) {
        .float => |parsed_float| parsed_float,
        .integer => |parsed_int| @floatFromInt(parsed_int),
        .number_string => |parsed_text| std.fmt.parseFloat(f64, parsed_text) catch return error.BadNumber,
        else => return error.WrongType,
    };

    try std.testing.expect(decoded == value);
}

test "fuzz: string field round-trips losslessly for valid utf8" {
    try std.testing.fuzz({}, fuzz_roundtrip_string, .{ .corpus = &seeds });
}

test "fuzz: binary field round-trips losslessly" {
    try std.testing.fuzz({}, fuzz_roundtrip_binary, .{ .corpus = &seeds });
}

test "fuzz: numeric fields round-trip exactly" {
    try std.testing.fuzz({}, fuzz_roundtrip_number, .{ .corpus = &seeds });
}
