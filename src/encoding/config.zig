const std = @import("std");
const level_mod = @import("../core/level.zig");

const Level = level_mod.Level;

pub const key_name_max: u32 = 32;
pub const omit_key = "";

pub const EncoderConfigError = error{
    MessageKeyTooLong,
    LevelKeyTooLong,
    TimeKeyTooLong,
    NameKeyTooLong,
    CallerKeyTooLong,
    FunctionKeyTooLong,
    StacktraceKeyTooLong,
};

pub const TimeEncoding = enum(u8) {
    epoch_s,
    epoch_ms,
    epoch_ns,
    iso8601,
    rfc3339,
    rfc3339_nano,
};

pub const LevelEncoding = enum(u8) {
    lowercase,
    uppercase,
    capital,
    capital_color,
    lowercase_color,
};

pub const DurationEncoding = enum(u8) {
    seconds,
    millis,
    nanos,
    string,
};

pub const CallerEncoding = enum(u8) {
    full_path,
    short_path,
};

pub const LineEnding = enum(u8) {
    newline,
    none,
};

pub const ConsoleFieldFormat = enum(u8) {
    json,
    key_value,
};

pub const EncoderConfig = struct {
    key_message: []const u8,
    key_level: []const u8,
    key_time: []const u8,
    key_name: []const u8,
    key_caller: []const u8,
    key_function: []const u8,
    key_stacktrace: []const u8,

    encode_time: TimeEncoding,
    encode_level: LevelEncoding,
    encode_duration: DurationEncoding,
    encode_caller: CallerEncoding,

    line_ending: LineEnding,
    console_separator: u8,
    time_offset_minutes: i32 = 0,
    console_fields: ConsoleFieldFormat = .json,

    pub fn production() EncoderConfig {
        return .{
            .key_message = "msg",
            .key_level = "level",
            .key_time = "ts",
            .key_name = "logger",
            .key_caller = "caller",
            .key_function = omit_key,
            .key_stacktrace = "stacktrace",
            .encode_time = .epoch_s,
            .encode_level = .lowercase,
            .encode_duration = .seconds,
            .encode_caller = .short_path,
            .line_ending = .newline,
            .console_separator = '\t',
        };
    }

    pub fn development() EncoderConfig {
        return .{
            .key_message = "M",
            .key_level = "L",
            .key_time = "T",
            .key_name = "N",
            .key_caller = "C",
            .key_function = omit_key,
            .key_stacktrace = "S",
            .encode_time = .iso8601,
            .encode_level = .capital_color,
            .encode_duration = .string,
            .encode_caller = .short_path,
            .line_ending = .newline,
            .console_separator = '\t',
        };
    }

    pub fn should_omit_time(self: *const EncoderConfig) bool {
        return self.key_time.len == 0;
    }

    pub fn should_omit_level(self: *const EncoderConfig) bool {
        return self.key_level.len == 0;
    }

    pub fn should_omit_message(self: *const EncoderConfig) bool {
        return self.key_message.len == 0;
    }

    pub fn should_omit_name(self: *const EncoderConfig) bool {
        return self.key_name.len == 0;
    }

    pub fn should_omit_caller(self: *const EncoderConfig) bool {
        return self.key_caller.len == 0;
    }

    pub fn should_omit_function(self: *const EncoderConfig) bool {
        return self.key_function.len == 0;
    }

    pub fn should_omit_stacktrace(self: *const EncoderConfig) bool {
        return self.key_stacktrace.len == 0;
    }

    pub fn level_string(self: *const EncoderConfig, at_level: Level) []const u8 {
        return switch (self.encode_level) {
            .lowercase, .lowercase_color => at_level.to_string(),
            .uppercase, .capital, .capital_color => at_level.to_string_upper(),
        };
    }

    pub fn level_uses_color(self: *const EncoderConfig) bool {
        return self.encode_level == .capital_color or self.encode_level == .lowercase_color;
    }

    pub fn level_color_prefix(self: *const EncoderConfig, at_level: Level) []const u8 {
        if (!self.level_uses_color()) return "";

        return switch (at_level) {
            .debug => "\x1b[35m",
            .info => "\x1b[34m",
            .warn => "\x1b[33m",
            .err => "\x1b[31m",
            .dpanic => "\x1b[31m",
            .panic => "\x1b[1;31m",
            .fatal => "\x1b[1;31m",
        };
    }

    pub fn level_color_suffix(self: *const EncoderConfig) []const u8 {
        if (!self.level_uses_color()) return "";

        return "\x1b[0m";
    }

    pub fn validate(self: *const EncoderConfig) EncoderConfigError!void {
        if (self.key_message.len > key_name_max) return error.MessageKeyTooLong;
        if (self.key_level.len > key_name_max) return error.LevelKeyTooLong;
        if (self.key_time.len > key_name_max) return error.TimeKeyTooLong;
        if (self.key_name.len > key_name_max) return error.NameKeyTooLong;
        if (self.key_caller.len > key_name_max) return error.CallerKeyTooLong;
        if (self.key_function.len > key_name_max) return error.FunctionKeyTooLong;
        if (self.key_stacktrace.len > key_name_max) return error.StacktraceKeyTooLong;
    }

    pub fn with_message_key(self: *const EncoderConfig, key: []const u8) EncoderConfig {
        std.debug.assert(key.len <= key_name_max);

        var config = self.*;
        config.key_message = key;

        return config;
    }

    pub fn with_level_key(self: *const EncoderConfig, key: []const u8) EncoderConfig {
        std.debug.assert(key.len <= key_name_max);

        var config = self.*;
        config.key_level = key;

        return config;
    }

    pub fn with_time_key(self: *const EncoderConfig, key: []const u8) EncoderConfig {
        std.debug.assert(key.len <= key_name_max);

        var config = self.*;
        config.key_time = key;

        return config;
    }

    pub fn with_name_key(self: *const EncoderConfig, key: []const u8) EncoderConfig {
        std.debug.assert(key.len <= key_name_max);

        var config = self.*;
        config.key_name = key;

        return config;
    }

    pub fn with_caller_key(self: *const EncoderConfig, key: []const u8) EncoderConfig {
        std.debug.assert(key.len <= key_name_max);

        var config = self.*;
        config.key_caller = key;

        return config;
    }

    pub fn with_function_key(self: *const EncoderConfig, key: []const u8) EncoderConfig {
        std.debug.assert(key.len <= key_name_max);

        var config = self.*;
        config.key_function = key;

        return config;
    }

    pub fn with_stacktrace_key(self: *const EncoderConfig, key: []const u8) EncoderConfig {
        std.debug.assert(key.len <= key_name_max);

        var config = self.*;
        config.key_stacktrace = key;

        return config;
    }

    pub fn with_time_encoding(self: *const EncoderConfig, encoding: TimeEncoding) EncoderConfig {
        var config = self.*;
        config.encode_time = encoding;

        return config;
    }

    pub fn with_level_encoding(self: *const EncoderConfig, encoding: LevelEncoding) EncoderConfig {
        var config = self.*;
        config.encode_level = encoding;

        return config;
    }

    pub fn with_duration_encoding(
        self: *const EncoderConfig,
        encoding: DurationEncoding,
    ) EncoderConfig {
        var config = self.*;
        config.encode_duration = encoding;

        return config;
    }

    pub fn with_caller_encoding(
        self: *const EncoderConfig,
        encoding: CallerEncoding,
    ) EncoderConfig {
        var config = self.*;
        config.encode_caller = encoding;

        return config;
    }

    pub fn with_console_separator(self: *const EncoderConfig, separator: u8) EncoderConfig {
        std.debug.assert(separator != 0);
        std.debug.assert(separator >= 0x09);

        var config = self.*;
        config.console_separator = separator;

        return config;
    }

    pub fn with_time_offset(self: *const EncoderConfig, offset_minutes: i32) EncoderConfig {
        std.debug.assert(offset_minutes > -1440);
        std.debug.assert(offset_minutes < 1440);

        var config = self.*;
        config.time_offset_minutes = offset_minutes;

        return config;
    }

    pub fn with_console_fields(self: *const EncoderConfig, format: ConsoleFieldFormat) EncoderConfig {
        var config = self.*;
        config.console_fields = format;

        return config;
    }
};
