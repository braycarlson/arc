const std = @import("std");

const arc = @import("arc.zig");

const assert = std.debug.assert;

const Core = arc.Core;
const Encoding = arc.Encoding;
const Field = arc.Field;
const Logger = arc.Logger;

const Harness = struct {
    bytes: [harness_bytes_max]u8,
    core: Core,
    parse_bytes: [harness_bytes_max * 8]u8,
    stream: std.Io.Writer,

    fn log(harness: *Harness, fields: []const Field) []const u8 {
        assert(fields.len <= arc.limits.field_count_max);
        assert(harness.core.sink_count == 1);

        harness.core.logger.information("hello", fields, &@src());

        return harness.stream.buffered();
    }

    fn json_valid(harness: *Harness, text: []const u8) bool {
        assert(text.len <= harness_bytes_max);
        assert(harness.core.sinks[0].encoding.format == .json);

        var allocator_state: std.heap.FixedBufferAllocator = .init(&harness.parse_bytes);
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');

        for (0..harness_line_count_max) |_| {
            const line = lines.next() orelse return true;

            const value = std.json.parseFromSliceLeaky(
                std.json.Value,
                allocator_state.allocator(),
                line,
                .{
                    .allocate = .alloc_always,
                    .duplicate_field_behavior = .use_last,
                    .ignore_unknown_fields = false,
                    .max_value_len = null,
                    .parse_numbers = true,
                },
            ) catch return false;

            if (value != .object) return false;
        }

        return false;
    }
};

const harness_bytes_max: u32 = 16 * 1024;
const harness_line_count_max: u32 = 64;

fn harness_create(encoding: *const Encoding) !*Harness {
    assert(encoding.valid());
    assert(harness_bytes_max >= arc.limits.entry_bytes_max);

    const harness = try testing.allocator.create(Harness);

    const sinks = [1]Core.Sink{.{
        .encoding = encoding.*,
        .level = .debug,
        .writer = .{ .stream = &harness.stream },
    }};

    harness.stream = .fixed(&harness.bytes);

    harness.core.init(testing.io, &.{
        .caller = false,
        .clock = .{ .fixed_ns = 1_700_000_000 * std.time.ns_per_s },
        .error_output = .discard,
        .level = .debug,
        .sampling = null,
        .sinks = &sinks,
        .terminal_development_panic = .none,
        .terminal_fatal = .none,
        .thread_safe = false,
    });

    return harness;
}

fn harness_destroy(harness: *Harness) void {
    assert(harness.core.sink_count == 1);
    assert(harness.stream.end <= harness_bytes_max);

    testing.allocator.destroy(harness);
}

fn encoding_with(time: Encoding.Time, offset_minutes: i32) Encoding {
    if (offset_minutes != 0) assert(time == .rfc3339);

    assert(offset_minutes > -1440);
    assert(offset_minutes < 1440);

    var encoding: Encoding = .production;

    encoding.time = time;
    encoding.time_offset_minutes = offset_minutes;

    assert(encoding.valid());

    return encoding;
}

fn encoding_console() Encoding {
    var encoding: Encoding = .production;

    encoding.format = .console;

    assert(encoding.valid());

    return encoding;
}

fn line_single(text: []const u8) bool {
    assert(text.len > 0);
    assert(text.len <= harness_bytes_max);

    return std.mem.countScalar(u8, text, '\n') == 1;
}

const testing = std.testing;

test "golden: empty entry" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{});

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\"}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: single string field" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{.{ .key = "k", .value = .{ .string = "v" } }});

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"k\":\"v\"}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: bool true and false" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{
        .{ .key = "t", .value = .{ .boolean = true } },
        .{ .key = "f", .value = .{ .boolean = false } },
    });

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"t\":true,\"f\":false}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: signed integers" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{
        .{ .key = "a", .value = .{ .integer = 42 } },
        .{ .key = "b", .value = .{ .integer = -42 } },
        .{ .key = "c", .value = .{ .integer = 0 } },
    });

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"a\":42,\"b\":-42,\"c\":0}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: i64 min" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{.{ .key = "n", .value = .{ .integer = std.math.minInt(i64) } }});

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"n\":-9223372036854775808}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: u64 max" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{
        .{ .key = "n", .value = .{ .unsigned = std.math.maxInt(u64) } },
    });

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"n\":18446744073709551615}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: integer widths share one encoding" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{
        .{ .key = "a", .value = .{ .integer = @as(i8, 1) } },
        .{ .key = "b", .value = .{ .integer = @as(i16, 2) } },
        .{ .key = "c", .value = .{ .unsigned = @as(u8, 3) } },
        .{ .key = "d", .value = .{ .unsigned = @as(u32, 4) } },
    });

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\"," ++
            "\"a\":1,\"b\":2,\"c\":3,\"d\":4}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: float whole number uses integer fast path" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{.{ .key = "f", .value = .{ .float = 3.0 } }});

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"f\":3}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: float fractional" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{.{ .key = "f", .value = .{ .float = 2.5 } }});

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"f\":2.5}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: float zero and negative zero" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{
        .{ .key = "a", .value = .{ .float = 0.0 } },
        .{ .key = "b", .value = .{ .float = -0.0 } },
    });

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"a\":0,\"b\":-0}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: float non finite encodes as strings" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{
        .{ .key = "nan", .value = .{ .float = std.math.nan(f64) } },
        .{ .key = "pos", .value = .{ .float = std.math.inf(f64) } },
        .{ .key = "neg", .value = .{ .float = -std.math.inf(f64) } },
    });

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\"," ++
            "\"nan\":\"NaN\",\"pos\":\"+Inf\",\"neg\":\"-Inf\"}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: float32 exact value" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{.{ .key = "f", .value = .{ .float = @as(f32, 2.5) } }});

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"f\":2.5}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: float extremes print every digit" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{.{ .key = "f", .value = .{ .float = 1e21 } }});

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"f\":1000000000000000000000}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: duration seconds default" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{.{ .key = "d", .value = .{ .duration_ns = 1_500_000_000 } }});

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"d\":1.5}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: duration millis and nanos" {
    const durations = [_]Encoding.Duration{ .milliseconds, .nanoseconds };

    const expected = [_][]const u8{
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"d\":1500}\n",
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"d\":1500000000}\n",
    };

    for (durations, expected) |duration, text| {
        var encoding: Encoding = .production;

        encoding.duration = duration;

        const harness = try harness_create(&encoding);
        defer harness_destroy(harness);

        const output = harness.log(&.{
            .{ .key = "d", .value = .{ .duration_ns = 1_500_000_000 } },
        });

        try testing.expectEqualStrings(text, output);
        try testing.expect(harness.json_valid(output));
    }
}

test "golden: duration string units" {
    var encoding: Encoding = .production;

    encoding.duration = .string;

    const harness = try harness_create(&encoding);
    defer harness_destroy(harness);

    const output = harness.log(&.{
        .{ .key = "a", .value = .{ .duration_ns = 90_000_000_000 } },
        .{ .key = "b", .value = .{ .duration_ns = 3_661_000_000_000 } },
        .{ .key = "c", .value = .{ .duration_ns = 1_500_000_000 } },
        .{ .key = "d", .value = .{ .duration_ns = 500_000_000 } },
        .{ .key = "e", .value = .{ .duration_ns = 250_000 } },
        .{ .key = "f", .value = .{ .duration_ns = 7 } },
    });

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\"," ++
            "\"a\":\"1m30s\",\"b\":\"1h1m1s\",\"c\":\"1.5s\"" ++
            ",\"d\":\"500ms\",\"e\":\"250us\",\"f\":\"7ns\"}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: time in epoch seconds keeps sub second precision" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{
        .{ .key = "s", .value = .{ .time_ns = 1_700_000_000 * std.time.ns_per_s } },
        .{ .key = "t", .value = .{ .time_ns = 1_700_000_000_123_456_789 } },
    });

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\"," ++
            "\"s\":1700000000,\"t\":1700000000.123456789}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: binary base64" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{.{ .key = "b", .value = .{ .binary = "hello" } }});

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"b\":\"aGVsbG8=\"}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: an error name under the error key" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{
        .{ .key = "error", .value = .{ .string = @errorName(error.ConnectionRefused) } },
    });

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\"" ++
            ",\"error\":\"ConnectionRefused\"}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: skip field emits nothing" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{ .skip, .{ .key = "a", .value = .{ .string = "1" } } });

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"a\":\"1\"}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: lists" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{
        .{ .key = "s", .value = .{ .string_list = &.{ "a", "b", "c" } } },
        .{ .key = "e", .value = .{ .string_list = &.{} } },
        .{ .key = "i", .value = .{ .integer_list = &.{ 1, -2, 3 } } },
        .{ .key = "u", .value = .{ .unsigned_list = &.{ 1, 2, 3 } } },
        .{ .key = "f", .value = .{ .float_list = &.{ 1.0, 2.5, 3.0 } } },
        .{ .key = "b", .value = .{ .boolean_list = &.{ true, false } } },
        .{ .key = "d", .value = .{ .duration_ns_list = &.{ 1_000_000_000, 2_000_000_000 } } },
    });

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\"," ++
            "\"s\":[\"a\",\"b\",\"c\"],\"e\":[],\"i\":[1,-2,3],\"u\":[1,2,3]," ++
            "\"f\":[1,2.5,3],\"b\":[true,false],\"d\":[1,2]}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: time list epoch ns" {
    const harness = try harness_create(&encoding_with(.epoch_ns, 0));
    defer harness_destroy(harness);

    const output = harness.log(&.{
        .{ .key = "l", .value = .{ .time_ns_list = &.{ 1_000_000_000, 2_000_000_000 } } },
    });

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000000000000,\"msg\":\"hello\"," ++
            "\"l\":[1000000000,2000000000]}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: namespace wraps later fields" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{
        .{ .key = "ns", .value = .namespace },
        .{ .key = "a", .value = .{ .string = "1" } },
        .{ .key = "b", .value = .{ .integer = 2 } },
    });

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"ns\":{\"a\":\"1\",\"b\":2}}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: object nests its fields" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{
        .{ .key = "user", .value = .{ .object = &.{
            .{ .key = "name", .value = .{ .string = "alice" } },
            .{ .key = "age", .value = .{ .unsigned = 30 } },
            .{ .key = "address", .value = .{ .object = &.{
                .{ .key = "city", .value = .{ .string = "denver" } },
                .{ .key = "zip", .value = .{ .unsigned = 80014 } },
            } } },
        } } },
    });

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"user\":{\"name\":\"alice\"," ++
            "\"age\":30,\"address\":{\"city\":\"denver\",\"zip\":80014}}}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: escapes" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{
        .{ .key = "q", .value = .{ .string = "a\"b\\c" } },
        .{ .key = "w", .value = .{ .string = "\n\r\t\x08\x0c" } },
        .{ .key = "c", .value = .{ .string = "\x01\x1f" } },
        .{ .key = "u", .value = .{ .string = "\u{00E9}\u{20AC}" } },
        .{ .key = "a", .value = .{ .string = "\u{1F600}" } },
        .{ .key = "x", .value = .{ .string = "\xff" } },
        .{ .key = "k\"", .value = .{ .string = "" } },
    });

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\",\"q\":\"a\\\"b\\\\c\"," ++
            "\"w\":\"\\n\\r\\t\\b\\f\",\"c\":\"\\u0001\\u001f\",\"u\":\"\u{00E9}\u{20AC}\"," ++
            "\"a\":\"\\ud83d\\ude00\",\"x\":\"\\u00ff\",\"k\\\"\":\"\"}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: time encodings" {
    const encodings = [_]Encoding{
        encoding_with(.epoch_ms, 0),
        encoding_with(.epoch_ns, 0),
        encoding_with(.rfc3339, 0),
        encoding_with(.rfc3339, 330),
        encoding_with(.rfc3339_nano, 0),
    };

    const expected = [_][]const u8{
        "{\"level\":\"info\",\"ts\":1700000000000,\"msg\":\"hello\"}\n",
        "{\"level\":\"info\",\"ts\":1700000000000000000,\"msg\":\"hello\"}\n",
        "{\"level\":\"info\",\"ts\":\"2023-11-14T22:13:20Z\",\"msg\":\"hello\"}\n",
        "{\"level\":\"info\",\"ts\":\"2023-11-15T03:43:20+05:30\",\"msg\":\"hello\"}\n",
        "{\"level\":\"info\",\"ts\":\"2023-11-14T22:13:20.000000000Z\",\"msg\":\"hello\"}\n",
    };

    for (&encodings, expected) |*encoding, text| {
        const harness = try harness_create(encoding);
        defer harness_destroy(harness);

        const output = harness.log(&.{});

        try testing.expectEqualStrings(text, output);
        try testing.expect(harness.json_valid(output));
    }
}

test "golden: level styles" {
    const styles = [_]arc.Level.Style{ .capital, .capital_color };

    for (styles) |style| {
        var encoding: Encoding = .production;

        encoding.level = style;

        const harness = try harness_create(&encoding);
        defer harness_destroy(harness);

        const output = harness.log(&.{});

        try testing.expectEqualStrings(
            "{\"level\":\"INFO\",\"ts\":1700000000,\"msg\":\"hello\"}\n",
            output,
        );

        try testing.expect(harness.json_valid(output));
    }
}

test "golden: keys renamed and omitted" {
    var encodings = [_]Encoding{ .production, .production, .production, .production };

    encodings[0].key_message = "message";
    encodings[1].key_level = "";
    encodings[2].key_time = "";
    encodings[3].key_message = "";

    const expected = [_][]const u8{
        "{\"level\":\"info\",\"ts\":1700000000,\"message\":\"hello\"}\n",
        "{\"ts\":1700000000,\"msg\":\"hello\"}\n",
        "{\"level\":\"info\",\"msg\":\"hello\"}\n",
        "{\"level\":\"info\",\"ts\":1700000000}\n",
    };

    for (&encodings, expected) |*encoding, text| {
        const harness = try harness_create(encoding);
        defer harness_destroy(harness);

        const output = harness.log(&.{});

        try testing.expectEqualStrings(text, output);
        try testing.expect(harness.json_valid(output));
    }
}

test "golden: line ending none" {
    var encoding: Encoding = .production;

    encoding.line_ending = .none;

    const harness = try harness_create(&encoding);
    defer harness_destroy(harness);

    const output = harness.log(&.{});

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"hello\"}",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: logger name and context in the envelope" {
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    var named: Logger = undefined;
    var child: Logger = undefined;

    harness.core.logger.child(&named, &.{ .fields = &.{}, .name = "svc" });

    named.child(&child, &.{
        .fields = &.{.{ .key = "a", .value = .{ .string = "1" } }},
        .name = "",
    });

    child.information("hello", &.{.{ .key = "b", .value = .{ .string = "2" } }}, &@src());

    const output = harness.stream.buffered();

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"logger\":\"svc\",\"msg\":\"hello\"," ++
            "\"a\":\"1\",\"b\":\"2\"}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden: truncation notice" {
    const big: [9000]u8 = @splat('a');
    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    const output = harness.log(&.{.{ .key = "big", .value = .{ .string = &big } }});

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"msg\":\"log entry exceeded buffer capacity and was dropped\"," ++
            "\"arc_truncated\":true}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}

test "golden console: minimal envelope" {
    const harness = try harness_create(&encoding_console());
    defer harness_destroy(harness);

    const output = harness.log(&.{});

    try testing.expectEqualStrings("1700000000\tinfo\thello\n", output);
    try testing.expect(line_single(output));
}

test "golden console: json fields block" {
    const harness = try harness_create(&encoding_console());
    defer harness_destroy(harness);

    const output = harness.log(&.{
        .{ .key = "k", .value = .{ .string = "v" } },
        .{ .key = "n", .value = .{ .integer = 42 } },
    });

    try testing.expectEqualStrings("1700000000\tinfo\thello\t{\"k\":\"v\",\"n\":42}\n", output);
    try testing.expect(line_single(output));
}

test "golden console: key and value pairs" {
    var encoding = encoding_console();

    encoding.console_fields = .key_value;

    const fields = [_][]const Field{
        &.{.{ .key = "k", .value = .{ .string = "v" } }},
        &.{
            .{ .key = "a", .value = .{ .string = "1" } },
            .{ .key = "b", .value = .{ .integer = 2 } },
        },
        &.{
            .{ .key = "ns", .value = .namespace },
            .{ .key = "a", .value = .{ .string = "1" } },
        },
    };

    const expected = [_][]const u8{
        "1700000000\tinfo\thello\tk=\"v\"\n",
        "1700000000\tinfo\thello\ta=\"1\" b=2\n",
        "1700000000\tinfo\thello\tns.a=\"1\"\n",
    };

    for (fields, expected) |set, text| {
        const harness = try harness_create(&encoding);
        defer harness_destroy(harness);

        const output = harness.log(set);

        try testing.expectEqualStrings(text, output);
        try testing.expect(line_single(output));
    }
}

test "golden console: key and value pairs render lists and objects as json" {
    var encoding = encoding_console();

    encoding.console_fields = .key_value;

    const harness = try harness_create(&encoding);
    defer harness_destroy(harness);

    const output = harness.log(&.{
        .{ .key = "nums", .value = .{ .integer_list = &.{ 1, 2, 3 } } },
        .{ .key = "d", .value = .{ .object = &.{.{ .key = "a", .value = .{ .integer = 1 } }} } },
    });

    try testing.expectEqualStrings("1700000000\tinfo\thello\tnums=[1,2,3] d={\"a\":1}\n", output);
    try testing.expect(line_single(output));
}

test "golden console: level color" {
    var encoding = encoding_console();

    encoding.level = .capital_color;

    const harness = try harness_create(&encoding);
    defer harness_destroy(harness);

    const output = harness.log(&.{});

    try testing.expectEqualStrings("1700000000\t\x1b[34mINFO\x1b[0m\thello\n", output);
    try testing.expect(line_single(output));
}

test "golden console: rfc3339 timestamp" {
    var encoding = encoding_console();

    encoding.time = .rfc3339;

    const harness = try harness_create(&encoding);
    defer harness_destroy(harness);

    const output = harness.log(&.{});

    try testing.expectEqualStrings("2023-11-14T22:13:20Z\tinfo\thello\n", output);
    try testing.expect(line_single(output));
}

test "golden console: logger name segment" {
    const harness = try harness_create(&encoding_console());
    defer harness_destroy(harness);

    var named: Logger = undefined;

    harness.core.logger.child(&named, &.{ .fields = &.{}, .name = "svc" });
    named.information("hello", &.{}, &@src());

    const output = harness.stream.buffered();

    try testing.expectEqualStrings("1700000000\tinfo\tsvc\thello\n", output);
    try testing.expect(line_single(output));
}

test "golden console: truncation notice" {
    const big: [9000]u8 = @splat('a');
    const harness = try harness_create(&encoding_console());
    defer harness_destroy(harness);

    const output = harness.log(&.{.{ .key = "big", .value = .{ .string = &big } }});

    try testing.expectEqualStrings(
        "info\tlog entry exceeded buffer capacity and was dropped\n",
        output,
    );

    try testing.expect(line_single(output));
}

test "golden: caller short and full paths" {
    const source: std.lang.SourceLocation = .{
        .module = "golden",
        .file = "/home/user/src/core/entry.zig",
        .line = 42,
        .column = 1,
        .fn_name = "handle",
    };

    const harness = try harness_create(&.production);
    defer harness_destroy(harness);

    harness.core.caller = true;

    harness.core.logger.information("hello", &.{}, &source);
    harness.core.sinks[0].encoding.caller = .full_path;
    harness.core.sinks[0].encoding.key_function = "func";

    harness.core.logger.information("hello", &.{}, &source);

    const output = harness.stream.buffered();

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"caller\":\"core/entry.zig:42\"," ++
            "\"msg\":\"hello\"}\n" ++
            "{\"level\":\"info\",\"ts\":1700000000," ++
            "\"caller\":\"/home/user/src/core/entry.zig:42\",\"func\":\"handle\"," ++
            "\"msg\":\"hello\"}\n",
        output,
    );

    try testing.expect(harness.json_valid(output));
}
