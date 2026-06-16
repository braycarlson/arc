const std = @import("std");
const buffer_mod = @import("../io/buffer.zig");

const Buffer = buffer_mod.Buffer;

const nanos_per_second: i64 = 1_000_000_000;
const seconds_per_minute: i64 = 60;
const seconds_per_day: i64 = 86_400;

const epoch_second_min: i64 = -9_223_372_037;
const epoch_second_max: i64 = 9_223_372_036;
const epoch_year_min: i64 = 1677;
const epoch_year_max: i64 = 2262;

const DateTime = struct {
    year: u32,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
};

pub fn write_iso8601(buffer: *Buffer, timestamp_ns: i64, offset_minutes: i32) void {
    std.debug.assert(offset_minutes > -1440);
    std.debug.assert(offset_minutes < 1440);

    const offset_ns = @as(i64, offset_minutes) * seconds_per_minute * nanos_per_second;
    const local_ns = timestamp_ns +| offset_ns;

    const seconds = @divFloor(local_ns, nanos_per_second);
    const fraction_ns: u64 = @intCast(@mod(local_ns, nanos_per_second));

    std.debug.assert(fraction_ns < 1_000_000_000);

    const datetime = epoch_to_datetime(seconds);

    buffer.append_padded_u32(datetime.year, 4);
    buffer.append_byte('-');
    buffer.append_padded_u32(datetime.month, 2);
    buffer.append_byte('-');
    buffer.append_padded_u32(datetime.day, 2);
    buffer.append_byte('T');
    buffer.append_padded_u32(datetime.hour, 2);
    buffer.append_byte(':');
    buffer.append_padded_u32(datetime.minute, 2);
    buffer.append_byte(':');
    buffer.append_padded_u32(datetime.second, 2);

    if (fraction_ns > 0) {
        buffer.append_byte('.');
        write_fraction_trimmed(buffer, fraction_ns, 9);
    }

    write_offset(buffer, offset_minutes);
}

fn write_offset(buffer: *Buffer, offset_minutes: i32) void {
    if (offset_minutes == 0) {
        buffer.append_byte('Z');
        return;
    }

    const negative = offset_minutes < 0;
    const absolute: u32 = @intCast(if (negative) -offset_minutes else offset_minutes);

    buffer.append_byte(if (negative) '-' else '+');
    buffer.append_padded_u32(absolute / 60, 2);
    buffer.append_byte(':');
    buffer.append_padded_u32(absolute % 60, 2);
}

fn abs_i64_to_u64(value: i64) u64 {
    if (value >= 0) {
        return @intCast(value);
    }

    if (value == std.math.minInt(i64)) {
        return @as(u64, @intCast(std.math.maxInt(i64))) + 1;
    }

    const magnitude: u64 = @intCast(-value);

    std.debug.assert(magnitude <= std.math.maxInt(i64));

    return magnitude;
}

pub fn write_epoch_scaled(buffer: *Buffer, timestamp_ns: i64, divisor: i64, frac_digits: u32) void {
    std.debug.assert(divisor > 0);
    std.debug.assert(frac_digits > 0);
    std.debug.assert(frac_digits <= 9);

    const negative = timestamp_ns < 0;

    if (negative) {
        buffer.append_byte('-');
    }

    const absolute_ns: u64 = abs_i64_to_u64(timestamp_ns);
    const divisor_unsigned: u64 = @intCast(divisor);

    const whole = absolute_ns / divisor_unsigned;
    const fraction = absolute_ns % divisor_unsigned;

    buffer.append_unsigned(whole);

    if (fraction == 0) {
        return;
    }

    buffer.append_byte('.');
    write_fraction_trimmed(buffer, fraction, frac_digits);
}

pub fn write_duration_string(buffer: *Buffer, nanoseconds: i64) void {
    if (nanoseconds == 0) {
        buffer.append_slice("0s");
        return;
    }

    const negative = nanoseconds < 0;

    if (negative) {
        buffer.append_byte('-');
    }

    const absolute: u64 = abs_i64_to_u64(nanoseconds);

    if (absolute < 1_000) {
        buffer.append_unsigned(absolute);
        buffer.append_slice("ns");
    } else if (absolute < 1_000_000) {
        write_duration_fractional(buffer, absolute, 1_000, "us");
    } else if (absolute < 1_000_000_000) {
        write_duration_fractional(buffer, absolute, 1_000_000, "ms");
    } else {
        write_duration_composed(buffer, absolute);
    }
}

fn write_duration_composed(buffer: *Buffer, nanoseconds: u64) void {
    std.debug.assert(nanoseconds >= 1_000_000_000);

    const total_seconds = nanoseconds / 1_000_000_000;
    const fraction = nanoseconds % 1_000_000_000;

    const hours = total_seconds / 3600;
    const remainder = total_seconds % 3600;
    const minutes = remainder / 60;
    const seconds = remainder % 60;

    if (hours > 0) {
        buffer.append_unsigned(hours);
        buffer.append_byte('h');
    }

    if (hours > 0 or minutes > 0) {
        buffer.append_unsigned(minutes);
        buffer.append_byte('m');
    }

    buffer.append_unsigned(seconds);

    if (fraction > 0) {
        buffer.append_byte('.');
        write_fraction_trimmed(buffer, fraction, 9);
    }

    buffer.append_byte('s');
}

fn write_duration_fractional(
    buffer: *Buffer,
    nanoseconds: u64,
    divisor: u64,
    suffix: []const u8,
) void {
    std.debug.assert(divisor > 0);
    std.debug.assert(suffix.len > 0);

    const whole = nanoseconds / divisor;
    const fraction = nanoseconds % divisor;

    buffer.append_unsigned(whole);

    if (fraction > 0) {
        buffer.append_byte('.');

        var fraction_remaining = fraction;
        var current_divisor = divisor / 10;
        var iterations: u32 = 0;

        while (fraction_remaining > 0 and current_divisor > 0 and iterations < 20) {
            const digit = (fraction_remaining / current_divisor) % 10;
            buffer.append_byte(@intCast('0' + digit));
            fraction_remaining %= current_divisor;
            current_divisor /= 10;
            iterations += 1;
        }
    }

    buffer.append_slice(suffix);
}

fn write_fraction_trimmed(buffer: *Buffer, fraction: u64, frac_digits: u32) void {
    std.debug.assert(frac_digits > 0);
    std.debug.assert(frac_digits <= 9);

    var scratch: [9]u8 = undefined;
    var index: u32 = frac_digits;
    var remaining = fraction;

    while (index > 0) {
        index -= 1;
        scratch[index] = @intCast('0' + remaining % 10);
        remaining /= 10;
    }

    std.debug.assert(remaining == 0);

    var trimmed: u32 = frac_digits;

    while (trimmed > 1 and scratch[trimmed - 1] == '0') {
        trimmed -= 1;
    }

    buffer.append_slice(scratch[0..trimmed]);
}

fn epoch_to_datetime(timestamp_s: i64) DateTime {
    std.debug.assert(timestamp_s >= epoch_second_min);
    std.debug.assert(timestamp_s <= epoch_second_max);

    const days: i64 = @divFloor(timestamp_s, seconds_per_day);
    const remaining_seconds: u64 = @intCast(timestamp_s - days * seconds_per_day);

    std.debug.assert(remaining_seconds < 86_400);

    const hour: u32 = @intCast(remaining_seconds / 3600);
    const minute: u32 = @intCast((remaining_seconds % 3600) / 60);
    const second: u32 = @intCast(remaining_seconds % 60);

    std.debug.assert(hour < 24);
    std.debug.assert(minute < 60);
    std.debug.assert(second < 60);

    const era_days: i64 = days + 719468;
    const era: i64 = @divFloor(era_days, 146097);
    const day_of_era: u64 = @intCast(era_days - era * 146097);

    std.debug.assert(day_of_era <= 146096);

    const year_of_era: u64 =
        (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365;
    const year_value: i64 = @as(i64, @intCast(year_of_era)) + era * 400;
    const day_of_year: u64 = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    const month_calc: u64 = (5 * day_of_year + 2) / 153;

    const day_value: u32 = @intCast(day_of_year - (153 * month_calc + 2) / 5 + 1);
    const month_value: u32 =
        if (month_calc < 10) @intCast(month_calc + 3) else @intCast(month_calc - 9);
    const year_calendar: i64 = if (month_value <= 2) year_value + 1 else year_value;

    std.debug.assert(year_calendar >= epoch_year_min);
    std.debug.assert(year_calendar <= epoch_year_max);

    const year_adjusted: u32 = @intCast(year_calendar);

    std.debug.assert(day_value >= 1);
    std.debug.assert(day_value <= 31);
    std.debug.assert(month_value >= 1);
    std.debug.assert(month_value <= 12);

    return .{
        .year = year_adjusted,
        .month = month_value,
        .day = day_value,
        .hour = hour,
        .minute = minute,
        .second = second,
    };
}
