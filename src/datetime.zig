const std = @import("std");

const buffer_module = @import("buffer.zig");

const assert = std.debug.assert;

const Buffer = buffer_module.Buffer;

pub const Fraction = enum {
    fixed,
    trimmed,
};

pub const Unit = enum {
    milliseconds,
    seconds,
};

const Civil = struct {
    day: u32,
    hour: u32,
    minute: u32,
    month: u32,
    second: u32,
    year: u32,
};

const Digits = struct {
    count: u32,
    value: u64,
};

const Scale = struct {
    digit_count: u32,
    divisor: u64,
    suffix: []const u8,
};

const Subsecond = enum {
    microseconds,
    milliseconds,
};

const day_s: u64 = 86_400;
const days_per_era: u64 = 146_097;
const days_shift: i64 = 719_468;
const digit_count_max: u32 = 9;
const hour_s: u64 = 3_600;
const microsecond_ns: u64 = 1_000;
const millisecond_ns: u64 = 1_000_000;
const minute_s: u64 = 60;
const offset_minutes_bound: i32 = 24 * 60;
const second_ns: u64 = 1_000_000_000;
pub const seconds_max: i64 = @divFloor(std.math.maxInt(i64), @as(i64, second_ns));
pub const seconds_min: i64 = @divFloor(std.math.minInt(i64), @as(i64, second_ns));
const year_max: i64 = 2262;
const year_min: i64 = 1677;

const digit_pairs: [100][2]u8 = blk: {
    var table: [100][2]u8 = undefined;

    for (&table, 0..) |*pair, index| {
        pair.* = .{ '0' + @divTrunc(index, 10), '0' + @rem(index, 10) };
    }

    break :blk table;
};

const powers_of_ten = [digit_count_max + 1]u64{
    1,
    10,
    100,
    1_000,
    10_000,
    100_000,
    1_000_000,
    10_000_000,
    100_000_000,
    1_000_000_000,
};

comptime {
    assert(powers_of_ten[digit_count_max] == second_ns);
    assert(powers_of_ten[6] == millisecond_ns);
    assert(powers_of_ten[3] == microsecond_ns);
    assert(days_per_era == 400 * 365 + 97);
    assert(std.mem.eql(u8, &digit_pairs[7], "07"));
    assert(std.mem.eql(u8, &digit_pairs[99], "99"));
    assert(seconds_min < 0);
    assert(seconds_max > 0);
}

pub fn rfc3339_write(buffer: *Buffer, time_ns: i64, offset_minutes: i32, fraction: Fraction) void {
    assert(offset_minutes > -offset_minutes_bound);
    assert(offset_minutes < offset_minutes_bound);
    assert(@divFloor(time_ns, @as(i64, second_ns)) >= seconds_min);
    assert(@divFloor(time_ns, @as(i64, second_ns)) <= seconds_max);

    const offset_ns = @as(i64, offset_minutes) * @as(i64, minute_s * second_ns);
    const local_ns = time_ns +| offset_ns;
    const seconds = @divFloor(local_ns, @as(i64, second_ns));
    const civil = civil_of(seconds);

    var text: [19]u8 = undefined;

    text[0..2].* = digit_pairs[@divTrunc(civil.year, 100)];
    text[2..4].* = digit_pairs[@rem(civil.year, 100)];
    text[4] = '-';
    text[5..7].* = digit_pairs[civil.month];
    text[7] = '-';
    text[8..10].* = digit_pairs[civil.day];
    text[10] = 'T';
    text[11..13].* = digit_pairs[civil.hour];
    text[13] = ':';
    text[14..16].* = digit_pairs[civil.minute];
    text[16] = ':';
    text[17..19].* = digit_pairs[civil.second];

    buffer.append_slice(&text);

    const nanoseconds: u64 = @intCast(@mod(local_ns, @as(i64, second_ns)));

    switch (fraction) {
        .fixed => {
            buffer.append_byte('.');
            digits_fixed_write(buffer, &.{ .count = digit_count_max, .value = nanoseconds });
        },
        .trimmed => if (nanoseconds > 0) {
            buffer.append_byte('.');
            digits_trimmed_write(buffer, &.{ .count = digit_count_max, .value = nanoseconds });
        },
    }

    offset_write(buffer, offset_minutes);
}

pub fn epoch_write(buffer: *Buffer, time_ns: i64, unit: Unit) void {
    assert(buffer.count <= buffer_module.entry_bytes_max);
    assert(@divTrunc(@abs(time_ns), second_ns) <= seconds_max);

    const scale: Scale = switch (unit) {
        .milliseconds => .{ .digit_count = 6, .divisor = millisecond_ns, .suffix = "" },
        .seconds => .{ .digit_count = 9, .divisor = second_ns, .suffix = "" },
    };

    assert(powers_of_ten[scale.digit_count] == scale.divisor);

    const magnitude = @abs(time_ns);
    const whole = @divTrunc(magnitude, scale.divisor);
    const fraction = @rem(magnitude, scale.divisor);

    if (time_ns < 0) buffer.append_byte('-');

    buffer.append_unsigned(whole);

    if (fraction > 0) {
        buffer.append_byte('.');
        digits_trimmed_write(buffer, &.{ .count = scale.digit_count, .value = fraction });
    }
}

pub fn duration_write(buffer: *Buffer, nanoseconds: i64) void {
    assert(buffer.count <= buffer_module.entry_bytes_max);
    assert(@divTrunc(@abs(nanoseconds), second_ns) <= seconds_max);

    if (nanoseconds == 0) {
        buffer.append_slice("0s");

        return;
    }

    const magnitude = @abs(nanoseconds);

    if (nanoseconds < 0) buffer.append_byte('-');

    if (magnitude < microsecond_ns) {
        buffer.append_unsigned(magnitude);
        buffer.append_slice("ns");
    } else if (magnitude < millisecond_ns) {
        duration_fraction_write(buffer, magnitude, .microseconds);
    } else if (magnitude < second_ns) {
        duration_fraction_write(buffer, magnitude, .milliseconds);
    } else {
        duration_composed_write(buffer, magnitude);
    }
}

fn duration_fraction_write(buffer: *Buffer, nanoseconds: u64, subsecond: Subsecond) void {
    assert(nanoseconds >= microsecond_ns);
    assert(nanoseconds < second_ns);

    const scale: Scale = switch (subsecond) {
        .microseconds => .{ .digit_count = 3, .divisor = microsecond_ns, .suffix = "us" },
        .milliseconds => .{ .digit_count = 6, .divisor = millisecond_ns, .suffix = "ms" },
    };

    const whole = @divTrunc(nanoseconds, scale.divisor);
    const fraction = @rem(nanoseconds, scale.divisor);

    assert(whole > 0);
    assert(whole < 1_000);

    buffer.append_unsigned(whole);

    if (fraction > 0) {
        buffer.append_byte('.');
        digits_trimmed_write(buffer, &.{ .count = scale.digit_count, .value = fraction });
    }

    buffer.append_slice(scale.suffix);
}

fn duration_composed_write(buffer: *Buffer, nanoseconds: u64) void {
    assert(nanoseconds >= second_ns);
    assert(buffer.count <= buffer_module.entry_bytes_max);

    const seconds_total = @divTrunc(nanoseconds, second_ns);
    const fraction = @rem(nanoseconds, second_ns);
    const hours = @divTrunc(seconds_total, hour_s);
    const minutes = @divTrunc(@rem(seconds_total, hour_s), minute_s);
    const seconds = @rem(seconds_total, minute_s);

    if (hours > 0) {
        buffer.append_unsigned(hours);
        buffer.append_byte('h');
        buffer.append_unsigned(minutes);
        buffer.append_byte('m');
    } else if (minutes > 0) {
        buffer.append_unsigned(minutes);
        buffer.append_byte('m');
    } else {}

    buffer.append_unsigned(seconds);

    if (fraction > 0) {
        buffer.append_byte('.');
        digits_trimmed_write(buffer, &.{ .count = digit_count_max, .value = fraction });
    }

    buffer.append_byte('s');
}

fn digits_fixed_write(buffer: *Buffer, digits: *const Digits) void {
    assert(digits.count > 0);
    assert(digits.count <= digit_count_max);
    assert(digits.value < powers_of_ten[digits.count]);

    var text: [digit_count_max + 1]u8 = undefined;
    var remaining = digits.value;
    var index = digits.count + @rem(digits.count, 2);

    for (0..@divCeil(digits.count, 2)) |_| {
        index -= 2;
        text[index..][0..2].* = digit_pairs[@rem(remaining, 100)];
        remaining = @divTrunc(remaining, 100);
    }

    assert(remaining == 0);
    assert(index == 0);

    const start = @rem(digits.count, 2);

    buffer.append_slice(text[start..][0..digits.count]);
}

fn digits_trimmed_write(buffer: *Buffer, digits: *const Digits) void {
    assert(digits.count > 0);
    assert(digits.value > 0);
    assert(digits.value < powers_of_ten[digits.count]);

    var count = digits.count;
    var value = digits.value;

    for (0..digits.count) |_| {
        if (@rem(value, 10) != 0) break;

        value = @divTrunc(value, 10);
        count -= 1;
    }

    assert(count > 0);
    assert(value > 0);

    digits_fixed_write(buffer, &.{ .count = count, .value = value });
}

fn offset_write(buffer: *Buffer, offset_minutes: i32) void {
    assert(offset_minutes > -offset_minutes_bound);
    assert(offset_minutes < offset_minutes_bound);

    if (offset_minutes == 0) {
        buffer.append_byte('Z');

        return;
    }

    const magnitude: u32 = @abs(offset_minutes);

    var text: [6]u8 = undefined;

    text[0] = if (offset_minutes < 0) '-' else '+';
    text[1..3].* = digit_pairs[@divTrunc(magnitude, 60)];
    text[3] = ':';
    text[4..6].* = digit_pairs[@rem(magnitude, 60)];

    buffer.append_slice(&text);
}

fn civil_of(seconds: i64) Civil {
    assert(seconds >= seconds_min);
    assert(seconds <= seconds_max);

    const days = @divFloor(seconds, @as(i64, day_s));
    const second_of_day: u64 = @intCast(seconds - days * @as(i64, day_s));
    const era_days = days + days_shift;
    const era = @divFloor(era_days, @as(i64, days_per_era));
    const day_of_era: u64 = @intCast(era_days - era * @as(i64, days_per_era));

    assert(second_of_day < day_s);
    assert(day_of_era < days_per_era);

    const year_of_era = @divTrunc(
        day_of_era - @divTrunc(day_of_era, 1_460) + @divTrunc(day_of_era, 36_524) -
            @divTrunc(day_of_era, days_per_era - 1),
        365,
    );

    const day_of_year = day_of_era -
        (365 * year_of_era + @divTrunc(year_of_era, 4) - @divTrunc(year_of_era, 100));

    const month_shifted = @divTrunc(5 * day_of_year + 2, 153);
    const day = day_of_year - @divTrunc(153 * month_shifted + 2, 5) + 1;
    const month = if (month_shifted < 10) month_shifted + 3 else month_shifted - 9;
    const year_base = @as(i64, @intCast(year_of_era)) + era * 400;
    const year = if (month <= 2) year_base + 1 else year_base;

    assert(year >= year_min);
    assert(year <= year_max);

    return .{
        .day = @intCast(day),
        .hour = @intCast(@divTrunc(second_of_day, hour_s)),
        .minute = @intCast(@divTrunc(@rem(second_of_day, hour_s), minute_s)),
        .month = @intCast(month),
        .second = @intCast(@rem(second_of_day, minute_s)),
        .year = @intCast(year),
    };
}

const testing = std.testing;

const Case = struct {
    expected: []const u8,
    fraction: Fraction,
    offset_minutes: i32,
    time_ns: i64,
};

fn test_rfc3339(case: *const Case) !void {
    assert(case.expected.len >= 20);
    assert(case.offset_minutes < offset_minutes_bound);

    var buffer: Buffer = undefined;

    buffer.reset();
    rfc3339_write(&buffer, case.time_ns, case.offset_minutes, case.fraction);

    try testing.expectEqualStrings(case.expected, buffer.contents());
    try testing.expect(!buffer.truncated);
}

test "an rfc3339 timestamp trims trailing zeros from its fraction" {
    try test_rfc3339(&.{
        .expected = "1970-01-01T00:00:01.5Z",
        .fraction = .trimmed,
        .offset_minutes = 0,
        .time_ns = 1_500_000_000,
    });

    try test_rfc3339(&.{
        .expected = "1970-01-01T00:00:02Z",
        .fraction = .trimmed,
        .offset_minutes = 0,
        .time_ns = 2_000_000_000,
    });
}

test "a fixed rfc3339 fraction always carries nine digits" {
    try test_rfc3339(&.{
        .expected = "1970-01-01T00:00:01.500000000Z",
        .fraction = .fixed,
        .offset_minutes = 0,
        .time_ns = 1_500_000_000,
    });

    try test_rfc3339(&.{
        .expected = "1970-01-01T00:00:02.000000000Z",
        .fraction = .fixed,
        .offset_minutes = 0,
        .time_ns = 2_000_000_000,
    });

    try test_rfc3339(&.{
        .expected = "1970-01-01T00:00:01.000000030Z",
        .fraction = .fixed,
        .offset_minutes = 0,
        .time_ns = 1_000_000_030,
    });
}

test "an offset shifts the wall clock and is written as hours and minutes" {
    try test_rfc3339(&.{
        .expected = "2023-11-15T03:43:20+05:30",
        .fraction = .trimmed,
        .offset_minutes = 330,
        .time_ns = 1_700_000_000_000_000_000,
    });

    try test_rfc3339(&.{
        .expected = "2023-11-14T17:13:20-05:00",
        .fraction = .trimmed,
        .offset_minutes = -300,
        .time_ns = 1_700_000_000_000_000_000,
    });
}

test "timestamps before the epoch floor to the earlier second" {
    try test_rfc3339(&.{
        .expected = "1969-12-31T23:59:59Z",
        .fraction = .trimmed,
        .offset_minutes = 0,
        .time_ns = -1_000_000_000,
    });

    try test_rfc3339(&.{
        .expected = "1969-12-31T23:59:59.5Z",
        .fraction = .trimmed,
        .offset_minutes = 0,
        .time_ns = -500_000_000,
    });

    try test_rfc3339(&.{
        .expected = "1900-01-01T00:00:00Z",
        .fraction = .trimmed,
        .offset_minutes = 0,
        .time_ns = -2_208_988_800_000_000_000,
    });
}

const calendar_format = "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}";

test "every rfc3339 date matches the std epoch calendar" {
    var prng = std.Random.DefaultPrng.init(0x7e57_da7e);
    const random = prng.random();

    for (0..4_096) |_| {
        const seconds = random.intRangeAtMost(i64, 0, seconds_max);
        const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
        const year_day = epoch.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch.getDaySeconds();

        var expected: [19]u8 = undefined;
        var buffer: Buffer = undefined;

        const text = try std.mem.print(&expected, calendar_format, .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        });

        buffer.reset();
        rfc3339_write(&buffer, seconds * @as(i64, second_ns), 0, .trimmed);

        try testing.expectEqualStrings(text, buffer.contents()[0..19]);
    }
}

test "an epoch timestamp prints a sign, whole units, and a trimmed fraction" {
    const cases = [_]struct { time_ns: i64, unit: Unit, expected: []const u8 }{
        .{ .time_ns = 0, .unit = .seconds, .expected = "0" },
        .{
            .time_ns = 1_700_000_000_123_456_789,
            .unit = .seconds,
            .expected = "1700000000.123456789",
        },
        .{ .time_ns = -500_000_000, .unit = .seconds, .expected = "-0.5" },
        .{ .time_ns = std.math.minInt(i64), .unit = .seconds, .expected = "-9223372036.854775808" },
        .{
            .time_ns = 1_700_000_000_000_000_000,
            .unit = .milliseconds,
            .expected = "1700000000000",
        },
        .{ .time_ns = 1_500_000, .unit = .milliseconds, .expected = "1.5" },
        .{ .time_ns = 1, .unit = .milliseconds, .expected = "0.000001" },
    };

    for (cases) |case| {
        var buffer: Buffer = undefined;

        buffer.reset();
        epoch_write(&buffer, case.time_ns, case.unit);

        try testing.expectEqualStrings(case.expected, buffer.contents());
    }
}

test "a duration renders the way Go renders a time.Duration" {
    const cases = [_]struct { nanoseconds: i64, expected: []const u8 }{
        .{ .nanoseconds = 0, .expected = "0s" },
        .{ .nanoseconds = 7, .expected = "7ns" },
        .{ .nanoseconds = 1_234, .expected = "1.234us" },
        .{ .nanoseconds = 250_000, .expected = "250us" },
        .{ .nanoseconds = 500_000_000, .expected = "500ms" },
        .{ .nanoseconds = 999_999_999, .expected = "999.999999ms" },
        .{ .nanoseconds = 1_500_000_000, .expected = "1.5s" },
        .{ .nanoseconds = 90_000_000_000, .expected = "1m30s" },
        .{ .nanoseconds = 3_661_000_000_000, .expected = "1h1m1s" },
        .{ .nanoseconds = 86_400_000_000_000, .expected = "24h0m0s" },
        .{ .nanoseconds = -1_500_000_000, .expected = "-1.5s" },
        .{ .nanoseconds = std.math.minInt(i64), .expected = "-2562047h47m16.854775808s" },
        .{ .nanoseconds = std.math.maxInt(i64), .expected = "2562047h47m16.854775807s" },
    };

    for (cases) |case| {
        var buffer: Buffer = undefined;

        buffer.reset();
        duration_write(&buffer, case.nanoseconds);

        try testing.expectEqualStrings(case.expected, buffer.contents());
    }
}
