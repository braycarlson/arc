const std = @import("std");

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

pub fn parse_level(text: []const u8) ParseLevelError!Level {
    std.debug.assert(text.len > 0);
    std.debug.assert(text.len <= 16);

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

fn ascii_equal_ignore_case(a: []const u8, b: []const u8) bool {
    std.debug.assert(a.len > 0);
    std.debug.assert(b.len > 0);

    if (a.len != b.len) return false;

    for (a, b) |char_a, char_b| {
        const lower_a = if (char_a >= 'A' and char_a <= 'Z') char_a + 32 else char_a;
        const lower_b = if (char_b >= 'A' and char_b <= 'Z') char_b + 32 else char_b;

        if (lower_a != lower_b) return false;
    }

    return true;
}

pub const AtomicLevel = struct {
    value: std.atomic.Value(u8),

    pub fn init(at_level: Level) AtomicLevel {
        return .{
            .value = std.atomic.Value(u8).init(@intFromEnum(at_level)),
        };
    }

    pub fn level(self: *const AtomicLevel) Level {
        const raw = self.value.load(.acquire);

        std.debug.assert(raw <= @intFromEnum(Level.fatal));

        return @enumFromInt(raw);
    }

    pub fn set_level(self: *AtomicLevel, at_level: Level) void {
        self.value.store(@intFromEnum(at_level), .release);

        std.debug.assert(self.value.load(.acquire) == @intFromEnum(at_level));
    }

    pub fn enabled(self: *const AtomicLevel, at_level: Level) bool {
        const current = self.level();

        return @intFromEnum(at_level) >= @intFromEnum(current);
    }
};
