const std = @import("std");
const buffer_mod = @import("../io/buffer.zig");
const encoder_config_mod = @import("config.zig");
const entry_mod = @import("../core/entry.zig");
const field_mod = @import("../core/field.zig");
const json_mod = @import("json.zig");
const clock_mod = @import("../core/clock.zig");
const fuzz = @import("../testing/fuzz.zig");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Buffer = buffer_mod.Buffer;
const EncoderConfig = encoder_config_mod.EncoderConfig;
const Entry = entry_mod.Entry;
const Field = field_mod.Field;
const JsonEncoder = json_mod.JsonEncoder;

const value_bytes_max: u32 = 512;
const key_bytes_max: u32 = 8;
const fixed_timestamp_s: i64 = 1_700_000_000;

const ill_formed_utf8 = [_][]const u8{
    "\xc0\xa9",
    "\xe0\x80\xaf",
    "\xf0\x80\x80\xa0",
    "\xed\xa0\x80",
    "\xf4\x90\x80\x80",
    "\x80",
    "\xc3",
    "\xc3\xa9",
    "ok\xc0\xa9end",
};

const Shape = enum {
    message,
    string_value,
    binary_value,
    escaped_key,
    numeric,
    many_fields,
};

comptime {
    assert(value_bytes_max > 0);
    assert(key_bytes_max > 0);
    assert(ill_formed_utf8.len > 0);
}

pub fn main(gpa: Allocator, args: fuzz.FuzzArgs) !void {
    assert(args.events_max >= 1);

    var prng = std.Random.DefaultPrng.init(args.seed);
    const random = prng.random();

    for (ill_formed_utf8) |case| {
        try verify_string_field(gpa, case);
    }

    var event: u32 = 0;

    while (event < args.events_max) : (event += 1) {
        try verify_shape(gpa, random);
    }

    assert(event == args.events_max);
}

fn encode(buffer: *Buffer, message: []const u8, fields: []const Field) void {
    assert(fields.len <= field_mod.fields_max);

    var encoder = JsonEncoder.init(EncoderConfig.production());
    var state = json_mod.EncodeState.init();

    const clock = clock_mod.Clock.init_fixed(fixed_timestamp_s);
    const entry = Entry.init_with_clock(undefined, .info, message, "fuzz", &clock);

    encoder.encode_entry(&state, buffer, &entry, .{ .context = &.{}, .message = fields });
}

fn parse_object(gpa: Allocator, line: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, gpa, line, .{
        .duplicate_field_behavior = .use_last,
    });
}

fn expect_valid_object(gpa: Allocator, buffer: *const Buffer) !void {
    var line = buffer.contents();

    while (line.len > 0 and (line[line.len - 1] == '\n' or line[line.len - 1] == '\r')) {
        line = line[0 .. line.len - 1];
    }

    if (line.len == 0) {
        return error.EmptyOutput;
    }

    const parsed = parse_object(gpa, line) catch return error.InvalidJson;
    defer parsed.deinit();

    if (parsed.value != .object) {
        return error.NotAnObject;
    }
}

fn verify_string_field(gpa: Allocator, value: []const u8) !void {
    var buffer = Buffer.init();

    encode(&buffer, "message", &.{field_mod.string("field", value)});

    try expect_valid_object(gpa, &buffer);
}

fn verify_shape(gpa: Allocator, random: std.Random) !void {
    var scratch: [value_bytes_max]u8 = undefined;
    var key_scratch: [key_bytes_max]u8 = undefined;

    switch (fuzz.random_enum_uniform(random, Shape)) {
        .message => {
            const length = random.uintAtMost(usize, value_bytes_max);
            const message = fuzz.random_bytes(random, scratch[0..length]);
            var buffer = Buffer.init();

            encode(&buffer, message, &.{});

            try expect_valid_object(gpa, &buffer);
        },
        .string_value => {
            const length = random.uintAtMost(usize, value_bytes_max);
            const value = fuzz.random_bytes(random, scratch[0..length]);

            try verify_string_field(gpa, value);
            try verify_string_round_trip(gpa, value);
        },
        .binary_value => {
            const length = random.uintAtMost(usize, value_bytes_max);
            const value = fuzz.random_bytes(random, scratch[0..length]);
            var buffer = Buffer.init();

            encode(&buffer, "message", &.{field_mod.binary("payload", value)});

            try expect_valid_object(gpa, &buffer);
        },
        .escaped_key => {
            const length = 1 + random.uintLessThan(usize, key_bytes_max);
            const key = fuzz.random_bytes(random, key_scratch[0..length]);

            if (key.len == 0) {
                return;
            }

            var buffer = Buffer.init();

            encode(&buffer, "message", &.{field_mod.string(key, "value")});

            try expect_valid_object(gpa, &buffer);
        },
        .numeric => try verify_numeric(gpa, random),
        .many_fields => try verify_many_fields(gpa, random),
    }
}

fn verify_string_round_trip(gpa: Allocator, value: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(value)) {
        return;
    }

    var buffer = Buffer.init();

    encode(&buffer, "message", &.{field_mod.string("field", value)});

    if (buffer.was_truncated()) {
        return;
    }

    var line = buffer.contents();

    while (line.len > 0 and line[line.len - 1] == '\n') {
        line = line[0 .. line.len - 1];
    }

    const parsed = parse_object(gpa, line) catch return error.InvalidJson;
    defer parsed.deinit();

    const node = parsed.value.object.get("field") orelse return error.MissingField;

    if (node != .string) {
        return error.FieldIsNotAString;
    }

    if (!std.mem.eql(u8, node.string, value)) {
        return error.StringRoundTripDiverged;
    }
}

fn verify_numeric(gpa: Allocator, random: std.Random) !void {
    var buffer = Buffer.init();

    const signed = random.int(i64);
    const unsigned = random.int(u64);
    const floating: f64 = @bitCast(random.int(u64));

    encode(&buffer, "message", &.{
        field_mod.int64("signed", signed),
        field_mod.uint64("unsigned", unsigned),
        field_mod.float64("floating", floating),
        field_mod.duration_ns("span", signed),
        field_mod.time_ns("at", signed),
    });

    try expect_valid_object(gpa, &buffer);
}

fn verify_many_fields(gpa: Allocator, random: std.Random) !void {
    var fields: [field_mod.fields_max]Field = undefined;
    var keys: [field_mod.fields_max][key_bytes_max]u8 = undefined;

    const count = random.uintAtMost(usize, field_mod.fields_max);

    var index: usize = 0;

    while (index < count) : (index += 1) {
        const length = 1 + random.uintLessThan(usize, key_bytes_max);
        const key = fuzz.random_bytes(random, keys[index][0..length]);

        fields[index] = if (key.len == 0)
            field_mod.int64("empty", random.int(i64))
        else
            field_mod.int64(key, random.int(i64));
    }

    var buffer = Buffer.init();

    encode(&buffer, "message", fields[0..count]);

    try expect_valid_object(gpa, &buffer);
}

const testing = std.testing;

test "fuzz: json encoding stays valid for arbitrary fields" {
    try main(testing.allocator, .{ .seed = 17, .events_max = fuzz.events_max_smoke });
}
