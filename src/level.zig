const std = @import("std");

const assert = std.debug.assert;

pub const Level = enum(u8) {
    debug,
    information,
    warn,
    err,
    development_panic,
    panic,
    fatal,

    pub const Color = struct {
        prefix: []const u8,
        suffix: []const u8,
    };

    pub const Error = error{LevelInvalid};

    pub const Style = enum {
        capital,
        capital_color,
        lowercase,
        lowercase_color,
    };

    pub const count: u32 = @typeInfo(Level).@"enum".field_names.len;

    pub fn parse(name: []const u8) Error!Level {
        assert(name.len <= text_bytes_max);

        for (spellings) |spelling| {
            if (std.ascii.eqlIgnoreCase(name, spelling.text)) {
                assert(spelling.text.len == name.len);

                return spelling.level;
            }
        }

        return error.LevelInvalid;
    }

    pub fn text(level: Level, style: Style) []const u8 {
        const result = switch (style) {
            .capital, .capital_color => texts_capital[@backingInt(level)],
            .lowercase, .lowercase_color => texts_lowercase[@backingInt(level)],
        };

        assert(result.len >= level_text_bytes_min);
        assert(result.len <= level_text_bytes_max);

        return result;
    }

    pub fn color(level: Level, style: Style) Color {
        const result: Color = switch (style) {
            .capital, .lowercase => .{ .prefix = "", .suffix = "" },
            .capital_color, .lowercase_color => .{
                .prefix = color_prefixes[@backingInt(level)],
                .suffix = color_reset,
            },
        };

        assert((result.prefix.len == 0) == (result.suffix.len == 0));

        return result;
    }

    pub fn enables(threshold: *const Level, level: Level) bool {
        const result = @backingInt(level) >= @backingInt(threshold.*);

        if (threshold.* == .debug) assert(result);
        if (level == .fatal) assert(result);

        return result;
    }
};

const Spelling = struct {
    level: Level,
    text: []const u8,
};

pub const text_bytes_max: u32 = 1 << 31;
const color_reset = "\x1b[0m";
const level_text_bytes_max: u32 = 6;
const level_text_bytes_min: u32 = 4;

const color_prefixes = [Level.count][]const u8{
    "\x1b[35m",
    "\x1b[34m",
    "\x1b[33m",
    "\x1b[31m",
    "\x1b[31m",
    "\x1b[1;31m",
    "\x1b[1;31m",
};

const spellings = [_]Spelling{
    .{ .level = .debug, .text = "debug" },
    .{ .level = .information, .text = "info" },
    .{ .level = .warn, .text = "warn" },
    .{ .level = .warn, .text = "warning" },
    .{ .level = .err, .text = "error" },
    .{ .level = .err, .text = "err" },
    .{ .level = .development_panic, .text = "dpanic" },
    .{ .level = .panic, .text = "panic" },
    .{ .level = .fatal, .text = "fatal" },
};

const texts_capital = [Level.count][]const u8{
    "DEBUG",
    "INFO",
    "WARN",
    "ERROR",
    "DPANIC",
    "PANIC",
    "FATAL",
};

const texts_lowercase = [Level.count][]const u8{
    "debug",
    "info",
    "warn",
    "error",
    "dpanic",
    "panic",
    "fatal",
};

comptime {
    assert(Level.count == 7);
    assert(@backingInt(Level.debug) == 0);
    assert(@backingInt(Level.fatal) == Level.count - 1);
    assert(spellings.len > Level.count);

    for (texts_capital, texts_lowercase) |capital, lowercase| {
        assert(capital.len == lowercase.len);
        assert(std.ascii.eqlIgnoreCase(capital, lowercase));
    }
}

const testing = std.testing;

test Level {
    const level = try Level.parse("WARNING");

    try testing.expectEqual(Level.warn, level);
    try testing.expectEqualStrings("warn", level.text(.lowercase));
    try testing.expectEqualStrings("WARN", level.text(.capital_color));
    try testing.expectEqualStrings("\x1b[33m", level.color(.capital_color).prefix);
    try testing.expectEqualStrings("", level.color(.capital).prefix);
    try testing.expect(level.enables(.err));
    try testing.expect(!level.enables(.information));
    try testing.expectError(error.LevelInvalid, Level.parse("trace"));
}

test "every level renders a text in every style that parses back to the same level" {
    for (std.enums.values(Level)) |level| {
        for (std.enums.values(Level.Style)) |style| {
            try testing.expectEqual(level, try Level.parse(level.text(style)));
        }
    }
}

test "parsing accepts the aliases and ignores case" {
    try testing.expectEqual(Level.warn, try Level.parse("warning"));
    try testing.expectEqual(Level.err, try Level.parse("err"));
    try testing.expectEqual(Level.err, try Level.parse("Error"));
    try testing.expectEqual(Level.information, try Level.parse("INFO"));
    try testing.expectEqual(Level.development_panic, try Level.parse("DPanic"));
}

test "parsing rejects text that names no level" {
    const rejected = [_][]const u8{ "", "trace", "verbose", "critical", "none", "infos", "inf" };

    for (rejected) |name| {
        try testing.expectError(error.LevelInvalid, Level.parse(name));
    }
}

test "a threshold enables exactly the levels at or above it" {
    for (std.enums.values(Level)) |threshold| {
        for (std.enums.values(Level)) |level| {
            const expected = @backingInt(level) >= @backingInt(threshold);

            try testing.expectEqual(expected, threshold.enables(level));
        }
    }
}

test "a colored style wraps every level in an escape and a reset" {
    for (std.enums.values(Level)) |level| {
        const color = level.color(.lowercase_color);

        try testing.expect(std.mem.startsWith(u8, color.prefix, "\x1b["));
        try testing.expectEqualStrings(color_reset, color.suffix);
        try testing.expectEqualStrings("", level.color(.lowercase).suffix);
    }
}
