const std = @import("std");

const level_module = @import("level.zig");

const assert = std.debug.assert;

const Level = level_module.Level;

pub const Encoding = struct {
    caller: Caller = .short_path,
    console_fields: ConsoleFields = .json,
    console_separator: u8 = '\t',
    duration: Duration = .seconds,
    format: Format = .json,
    key_caller: []const u8 = "caller",
    key_function: []const u8 = "",
    key_level: []const u8 = "level",
    key_message: []const u8 = "msg",
    key_name: []const u8 = "logger",
    key_time: []const u8 = "ts",
    level: Level.Style = .lowercase,
    line_ending: LineEnding = .newline,
    time: Time = .epoch_s,
    time_offset_minutes: i32 = 0,

    pub const Caller = enum {
        full_path,
        short_path,
    };

    pub const ConsoleFields = enum {
        json,
        key_value,
    };

    pub const Duration = enum {
        milliseconds,
        nanoseconds,
        seconds,
        string,
    };

    pub const Format = enum {
        console,
        json,
    };

    pub const LineEnding = enum {
        newline,
        none,
    };

    pub const Time = enum {
        epoch_ms,
        epoch_ns,
        epoch_s,
        rfc3339,
        rfc3339_nano,
    };

    pub const development: Encoding = .{
        .caller = .short_path,
        .console_fields = .json,
        .console_separator = '\t',
        .duration = .string,
        .format = .console,
        .key_caller = "C",
        .key_function = "",
        .key_level = "L",
        .key_message = "M",
        .key_name = "N",
        .key_time = "T",
        .level = .capital_color,
        .line_ending = .newline,
        .time = .rfc3339,
        .time_offset_minutes = 0,
    };

    pub const production: Encoding = .{
        .caller = .short_path,
        .console_fields = .json,
        .console_separator = '\t',
        .duration = .seconds,
        .format = .json,
        .key_caller = "caller",
        .key_function = "",
        .key_level = "level",
        .key_message = "msg",
        .key_name = "logger",
        .key_time = "ts",
        .level = .lowercase,
        .line_ending = .newline,
        .time = .epoch_s,
        .time_offset_minutes = 0,
    };

    pub fn valid(encoding: *const Encoding) bool {
        const keys = [_][]const u8{
            encoding.key_caller,
            encoding.key_function,
            encoding.key_level,
            encoding.key_message,
            encoding.key_name,
            encoding.key_time,
        };

        for (keys) |key| {
            if (key.len > key_bytes_max) return false;
        }

        if (encoding.console_separator >= 0x80) return false;
        if (encoding.time_offset_minutes <= -offset_minutes_bound) return false;
        if (encoding.time_offset_minutes >= offset_minutes_bound) return false;

        if (encoding.console_separator < ' ') {
            return encoding.console_separator == '\t';
        }

        return true;
    }
};

pub const key_bytes_max: u32 = 32;
pub const offset_minutes_bound: i32 = 24 * 60;

comptime {
    assert(key_bytes_max > 0);
    assert(offset_minutes_bound == 1440);
    assert(Encoding.production.valid());
    assert(Encoding.development.valid());
}

const testing = std.testing;

test Encoding {
    var encoding: Encoding = .production;

    encoding.time = .rfc3339;
    encoding.time_offset_minutes = 330;

    try testing.expect(encoding.valid());

    encoding.time_offset_minutes = offset_minutes_bound;

    try testing.expect(!encoding.valid());

    encoding.time_offset_minutes = -offset_minutes_bound + 1;

    try testing.expect(encoding.valid());
}

test "a field default matches the production preset" {
    const defaulted: Encoding = .{};

    try testing.expectEqualDeep(Encoding.production, defaulted);
    try testing.expect(defaulted.valid());
}

test "a key longer than the bound or a control separator makes an encoding invalid" {
    var encoding: Encoding = .production;

    encoding.key_message = "a key that is longer than thirty two bytes";

    try testing.expect(!encoding.valid());

    encoding = .production;
    encoding.console_separator = '\n';

    try testing.expect(!encoding.valid());

    encoding.console_separator = ' ';

    try testing.expect(encoding.valid());

    encoding.console_separator = 0xff;

    try testing.expect(!encoding.valid());
}
