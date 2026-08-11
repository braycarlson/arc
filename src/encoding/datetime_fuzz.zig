const std = @import("std");
const buffer_mod = @import("../io/buffer.zig");
const datetime = @import("datetime.zig");
const fuzz = @import("../testing/fuzz.zig");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Buffer = buffer_mod.Buffer;

const offset_minutes_max: i32 = 1439;
const iso8601_bytes_min: usize = 20;
const nanosecond_digits: usize = 9;

const boundary_timestamps = [_]i64{
    std.math.minInt(i64),
    std.math.minInt(i64) + 1,
    -9_223_372_036_000_000_000,
    -1,
    0,
    1,
    1_700_000_000_000_000_000,
    9_223_372_036_000_000_000,
    std.math.maxInt(i64) - 1,
    std.math.maxInt(i64),
};

comptime {
    assert(offset_minutes_max > 0);
    assert(iso8601_bytes_min > 0);
    assert(nanosecond_digits == 9);
    assert(boundary_timestamps.len > 0);
}

pub fn main(gpa: Allocator, args: fuzz.FuzzArgs) !void {
    assert(args.events_max >= 1);

    _ = gpa;

    var prng = std.Random.DefaultPrng.init(args.seed);
    const random = prng.random();

    for (boundary_timestamps) |timestamp_ns| {
        try verify_all(timestamp_ns, 0);
        try verify_all(timestamp_ns, offset_minutes_max);
        try verify_all(timestamp_ns, -offset_minutes_max);
    }

    var event: u32 = 0;

    while (event < args.events_max) : (event += 1) {
        const timestamp_ns = random.int(i64);
        const offset_minutes = random.intRangeAtMost(i32, -offset_minutes_max, offset_minutes_max);

        try verify_all(timestamp_ns, offset_minutes);
    }

    assert(event == args.events_max);
}

fn verify_all(timestamp_ns: i64, offset_minutes: i32) !void {
    try verify_iso8601(timestamp_ns, offset_minutes);
    try verify_iso8601_nano(timestamp_ns, offset_minutes);
    try verify_epoch_scaled(timestamp_ns);
    try verify_duration(timestamp_ns);
}

fn verify_iso8601(timestamp_ns: i64, offset_minutes: i32) !void {
    var buffer = Buffer.init();

    datetime.write_iso8601(&buffer, timestamp_ns, offset_minutes);

    const text = buffer.contents();

    if (buffer.was_truncated()) {
        return error.Iso8601Truncated;
    }

    if (text.len < iso8601_bytes_min) {
        return error.Iso8601TooShort;
    }

    if (text[10] != 'T') {
        return error.Iso8601MissingDateSeparator;
    }
}

fn verify_iso8601_nano(timestamp_ns: i64, offset_minutes: i32) !void {
    var buffer = Buffer.init();

    datetime.write_iso8601_nano(&buffer, timestamp_ns, offset_minutes);

    const text = buffer.contents();

    if (buffer.was_truncated()) {
        return error.Iso8601NanoTruncated;
    }

    const dot = std.mem.indexOfScalar(u8, text, '.') orelse {
        return error.Iso8601NanoMissingFraction;
    };

    if (text.len < dot + 1 + nanosecond_digits) {
        return error.Iso8601NanoFractionTooShort;
    }
}

fn verify_epoch_scaled(timestamp_ns: i64) !void {
    var buffer = Buffer.init();

    datetime.write_epoch_scaled(&buffer, timestamp_ns, .{
        .divisor = 1_000_000_000,
        .fraction_digits = 9,
    });

    if (buffer.was_truncated()) {
        return error.EpochScaledTruncated;
    }

    if (buffer.is_empty()) {
        return error.EpochScaledEmpty;
    }
}

fn verify_duration(nanoseconds: i64) !void {
    var buffer = Buffer.init();

    datetime.write_duration_string(&buffer, nanoseconds);

    if (buffer.was_truncated()) {
        return error.DurationTruncated;
    }

    if (buffer.is_empty()) {
        return error.DurationEmpty;
    }
}

const testing = std.testing;

test "fuzz: datetime encoders survive the whole epoch range" {
    try main(testing.allocator, .{ .seed = 13, .events_max = fuzz.events_max_smoke });
}
