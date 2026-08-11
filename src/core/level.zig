const std = @import("std");

const assert = std.debug.assert;

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
    dpanic = 4,
    panic = 5,
    fatal = 6,

    pub fn to_string(self: Level) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
            .dpanic => "dpanic",
            .panic => "panic",
            .fatal => "fatal",
        };
    }

    pub fn to_string_upper(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .dpanic => "DPANIC",
            .panic => "PANIC",
            .fatal => "FATAL",
        };
    }

    pub fn enabled(self: Level, at_level: Level) bool {
        return @intFromEnum(at_level) >= @intFromEnum(self);
    }
};

pub const ParseLevelError = error{InvalidLevel};

pub const AtomicLevel = struct {
    value: std.atomic.Value(u8),

    pub fn init(at_level: Level) AtomicLevel {
        return .{
            .value = std.atomic.Value(u8).init(@intFromEnum(at_level)),
        };
    }

    pub fn level(self: *const AtomicLevel) Level {
        const raw = self.value.load(.acquire);

        assert(raw <= @intFromEnum(Level.fatal));

        return @enumFromInt(raw);
    }

    pub fn set_level(self: *AtomicLevel, at_level: Level) void {
        self.value.store(@intFromEnum(at_level), .release);
    }

    pub fn enabled(self: *const AtomicLevel, at_level: Level) bool {
        const current = self.level();

        return @intFromEnum(at_level) >= @intFromEnum(current);
    }
};

pub const levels_count: u32 = @typeInfo(Level).@"enum".fields.len;

comptime {
    assert(levels_count > 0);
    assert(@intFromEnum(Level.debug) == 0);
    assert(@intFromEnum(Level.fatal) == levels_count - 1);
}

pub fn parse_level(text: []const u8) ParseLevelError!Level {
    assert(text.len > 0);
    assert(text.len <= 16);

    if (ascii_equal_ignore_case(text, "debug")) return .debug;
    if (ascii_equal_ignore_case(text, "info")) return .info;
    if (ascii_equal_ignore_case(text, "warn")) return .warn;
    if (ascii_equal_ignore_case(text, "warning")) return .warn;
    if (ascii_equal_ignore_case(text, "error")) return .err;
    if (ascii_equal_ignore_case(text, "err")) return .err;
    if (ascii_equal_ignore_case(text, "dpanic")) return .dpanic;
    if (ascii_equal_ignore_case(text, "panic")) return .panic;
    if (ascii_equal_ignore_case(text, "fatal")) return .fatal;

    return error.InvalidLevel;
}

fn ascii_lower(byte: u8) u8 {
    if (byte >= 'A' and byte <= 'Z') {
        return byte + 32;
    }

    return byte;
}

fn ascii_equal_ignore_case(left: []const u8, right: []const u8) bool {
    assert(left.len > 0);
    assert(right.len > 0);

    if (left.len != right.len) return false;

    for (left, right) |left_byte, right_byte| {
        const left_lower = ascii_lower(left_byte);
        const right_lower = ascii_lower(right_byte);

        if (left_lower != right_lower) return false;
    }

    return true;
}

const testing = std.testing;

test "the levels are ordered by ascending severity" {
    const levels = [_]Level{ .debug, .info, .warn, .err, .dpanic, .panic, .fatal };

    for (levels, 0..) |at_level, i| {
        const raw: u8 = @intFromEnum(at_level);
        assert(raw == i);
    }

    assert(@intFromEnum(Level.debug) < @intFromEnum(Level.fatal));
}

test "a level enables only levels at or above its severity" {
    const info_level = Level.info;

    assert(!info_level.enabled(.debug));
    assert(info_level.enabled(.info));
    assert(info_level.enabled(.warn));
    assert(info_level.enabled(.err));
    assert(info_level.enabled(.panic));
    assert(info_level.enabled(.fatal));

    try testing.expect(!info_level.enabled(.debug));
    try testing.expect(info_level.enabled(.info));
    try testing.expect(info_level.enabled(.warn));
}

test "the debug level enables every level" {
    const debug_level = Level.debug;

    try testing.expect(debug_level.enabled(.debug));
    try testing.expect(debug_level.enabled(.info));
    try testing.expect(debug_level.enabled(.panic));
    try testing.expect(debug_level.enabled(.fatal));

    assert(debug_level.enabled(.debug));
}

test "the fatal level enables only itself" {
    const fatal_level = Level.fatal;

    try testing.expect(!fatal_level.enabled(.debug));
    try testing.expect(!fatal_level.enabled(.info));
    try testing.expect(!fatal_level.enabled(.warn));
    try testing.expect(!fatal_level.enabled(.err));
    try testing.expect(!fatal_level.enabled(.dpanic));
    try testing.expect(!fatal_level.enabled(.panic));
    try testing.expect(fatal_level.enabled(.fatal));

    assert(!fatal_level.enabled(.debug));
    assert(fatal_level.enabled(.fatal));
}

test "a level renders as its lowercase name" {
    try testing.expectEqualStrings("debug", Level.debug.to_string());
    try testing.expectEqualStrings("info", Level.info.to_string());
    try testing.expectEqualStrings("warn", Level.warn.to_string());
    try testing.expectEqualStrings("error", Level.err.to_string());
    try testing.expectEqualStrings("dpanic", Level.dpanic.to_string());
    try testing.expectEqualStrings("panic", Level.panic.to_string());
    try testing.expectEqualStrings("fatal", Level.fatal.to_string());

    assert(Level.debug.to_string().len > 0);
    assert(Level.fatal.to_string().len > 0);
}

test "a level renders as its uppercase name" {
    try testing.expectEqualStrings("DEBUG", Level.debug.to_string_upper());
    try testing.expectEqualStrings("INFO", Level.info.to_string_upper());
    try testing.expectEqualStrings("WARN", Level.warn.to_string_upper());
    try testing.expectEqualStrings("ERROR", Level.err.to_string_upper());
    try testing.expectEqualStrings("DPANIC", Level.dpanic.to_string_upper());
    try testing.expectEqualStrings("PANIC", Level.panic.to_string_upper());
    try testing.expectEqualStrings("FATAL", Level.fatal.to_string_upper());

    assert(Level.debug.to_string_upper().len > 0);
    assert(Level.fatal.to_string_upper().len > 0);
}

test "parsing accepts every canonical level name and its aliases" {
    try testing.expectEqual(Level.debug, try parse_level("debug"));
    try testing.expectEqual(Level.info, try parse_level("info"));
    try testing.expectEqual(Level.warn, try parse_level("warn"));
    try testing.expectEqual(Level.warn, try parse_level("warning"));
    try testing.expectEqual(Level.err, try parse_level("error"));
    try testing.expectEqual(Level.err, try parse_level("err"));
    try testing.expectEqual(Level.dpanic, try parse_level("dpanic"));
    try testing.expectEqual(Level.panic, try parse_level("panic"));
    try testing.expectEqual(Level.fatal, try parse_level("fatal"));

    assert(@intFromEnum(try parse_level("debug")) == 0);
    assert(@intFromEnum(try parse_level("fatal")) == 6);
}

test "parsing ignores the case of a level name" {
    try testing.expectEqual(Level.debug, try parse_level("DEBUG"));
    try testing.expectEqual(Level.info, try parse_level("Info"));
    try testing.expectEqual(Level.warn, try parse_level("WARN"));
    try testing.expectEqual(Level.err, try parse_level("Error"));
    try testing.expectEqual(Level.panic, try parse_level("PANIC"));

    assert(@intFromEnum(try parse_level("DEBUG")) == 0);
    assert(@intFromEnum(try parse_level("INFO")) == 1);
}

test "parsing rejects text that names no level" {
    try testing.expectError(error.InvalidLevel, parse_level("trace"));
    try testing.expectError(error.InvalidLevel, parse_level("verbose"));
    try testing.expectError(error.InvalidLevel, parse_level("critical"));
    try testing.expectError(error.InvalidLevel, parse_level("none"));

    try testing.expectError(error.InvalidLevel, parse_level("trace"));
    try testing.expectEqual(Level.debug, try parse_level("debug"));
}

test "an atomic level reads back the level it was built with" {
    const atomic = AtomicLevel.init(.info);
    const current = atomic.level();

    try testing.expectEqual(Level.info, current);

    assert(@intFromEnum(current) == @intFromEnum(Level.info));
    assert(atomic.enabled(.info));
}

test "setting an atomic level moves the threshold it enables" {
    var atomic = AtomicLevel.init(.info);

    try testing.expect(!atomic.enabled(.debug));
    try testing.expect(atomic.enabled(.info));
    try testing.expect(atomic.enabled(.warn));

    atomic.set_level(.warn);

    try testing.expect(!atomic.enabled(.debug));
    try testing.expect(!atomic.enabled(.info));
    try testing.expect(atomic.enabled(.warn));
    try testing.expect(atomic.enabled(.err));

    assert(atomic.level() == .warn);
    assert(!atomic.enabled(.debug));
}

test "an atomic level renders the name of the level it holds" {
    var atomic = AtomicLevel.init(.err);

    const text = atomic.level().to_string();

    try testing.expectEqualStrings("error", text);

    assert(text.len > 0);
    assert(text.len <= 8);
}

test "an atomic level accepts a level parsed from text" {
    var atomic = AtomicLevel.init(.debug);

    const parsed = try parse_level("warn");
    atomic.set_level(parsed);

    try testing.expectEqual(Level.warn, atomic.level());

    assert(atomic.level() == .warn);
    assert(atomic.enabled(.warn));
}

test "an atomic level keeps its level when the text names none" {
    var atomic = AtomicLevel.init(.debug);

    try testing.expectError(
        error.InvalidLevel,
        parse_level("garbage"),
    );

    try testing.expectEqual(Level.debug, atomic.level());

    assert(atomic.level() == .debug);
    assert(atomic.enabled(.debug));
}
