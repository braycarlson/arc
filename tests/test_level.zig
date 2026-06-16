const std = @import("std");
const arc = @import("arc");

const Level = arc.Level;
const AtomicLevel = arc.AtomicLevel;
const parse_level = arc.level_mod.parse_level;

test "level ordering is monotonically increasing" {
    const levels = [_]Level{ .debug, .info, .warn, .err, .dpanic, .panic, .fatal };

    for (levels, 0..) |at_level, i| {
        const raw: u8 = @intFromEnum(at_level);
        std.debug.assert(raw == i);
    }

    std.debug.assert(@intFromEnum(Level.debug) < @intFromEnum(Level.fatal));
}

test "level enabled respects severity threshold" {
    const info_level = Level.info;

    std.debug.assert(!info_level.enabled(.debug));
    std.debug.assert(info_level.enabled(.info));
    std.debug.assert(info_level.enabled(.warn));
    std.debug.assert(info_level.enabled(.err));
    std.debug.assert(info_level.enabled(.panic));
    std.debug.assert(info_level.enabled(.fatal));

    try std.testing.expect(!info_level.enabled(.debug));
    try std.testing.expect(info_level.enabled(.info));
    try std.testing.expect(info_level.enabled(.warn));
}

test "level debug enables all levels" {
    const debug_level = Level.debug;

    try std.testing.expect(debug_level.enabled(.debug));
    try std.testing.expect(debug_level.enabled(.info));
    try std.testing.expect(debug_level.enabled(.panic));
    try std.testing.expect(debug_level.enabled(.fatal));

    std.debug.assert(debug_level.enabled(.debug));
}

test "level fatal enables only fatal" {
    const fatal_level = Level.fatal;

    try std.testing.expect(!fatal_level.enabled(.debug));
    try std.testing.expect(!fatal_level.enabled(.info));
    try std.testing.expect(!fatal_level.enabled(.warn));
    try std.testing.expect(!fatal_level.enabled(.err));
    try std.testing.expect(!fatal_level.enabled(.dpanic));
    try std.testing.expect(!fatal_level.enabled(.panic));
    try std.testing.expect(fatal_level.enabled(.fatal));

    std.debug.assert(!fatal_level.enabled(.debug));
    std.debug.assert(fatal_level.enabled(.fatal));
}

test "level to_string returns lowercase names" {
    try std.testing.expectEqualStrings("debug", Level.debug.to_string());
    try std.testing.expectEqualStrings("info", Level.info.to_string());
    try std.testing.expectEqualStrings("warn", Level.warn.to_string());
    try std.testing.expectEqualStrings("error", Level.err.to_string());
    try std.testing.expectEqualStrings("dpanic", Level.dpanic.to_string());
    try std.testing.expectEqualStrings("panic", Level.panic.to_string());
    try std.testing.expectEqualStrings("fatal", Level.fatal.to_string());

    std.debug.assert(Level.debug.to_string().len > 0);
    std.debug.assert(Level.fatal.to_string().len > 0);
}

test "level to_string_upper returns uppercase names" {
    try std.testing.expectEqualStrings("DEBUG", Level.debug.to_string_upper());
    try std.testing.expectEqualStrings("INFO", Level.info.to_string_upper());
    try std.testing.expectEqualStrings("WARN", Level.warn.to_string_upper());
    try std.testing.expectEqualStrings("ERROR", Level.err.to_string_upper());
    try std.testing.expectEqualStrings("DPANIC", Level.dpanic.to_string_upper());
    try std.testing.expectEqualStrings("PANIC", Level.panic.to_string_upper());
    try std.testing.expectEqualStrings("FATAL", Level.fatal.to_string_upper());

    std.debug.assert(Level.debug.to_string_upper().len > 0);
    std.debug.assert(Level.fatal.to_string_upper().len > 0);
}

test "parse_level accepts canonical names" {
    try std.testing.expectEqual(Level.debug, try parse_level("debug"));
    try std.testing.expectEqual(Level.info, try parse_level("info"));
    try std.testing.expectEqual(Level.warn, try parse_level("warn"));
    try std.testing.expectEqual(Level.warn, try parse_level("warning"));
    try std.testing.expectEqual(Level.err, try parse_level("error"));
    try std.testing.expectEqual(Level.err, try parse_level("err"));
    try std.testing.expectEqual(Level.dpanic, try parse_level("dpanic"));
    try std.testing.expectEqual(Level.panic, try parse_level("panic"));
    try std.testing.expectEqual(Level.fatal, try parse_level("fatal"));

    std.debug.assert(@intFromEnum(try parse_level("debug")) == 0);
    std.debug.assert(@intFromEnum(try parse_level("fatal")) == 6);
}

test "parse_level is case insensitive" {
    try std.testing.expectEqual(Level.debug, try parse_level("DEBUG"));
    try std.testing.expectEqual(Level.info, try parse_level("Info"));
    try std.testing.expectEqual(Level.warn, try parse_level("WARN"));
    try std.testing.expectEqual(Level.err, try parse_level("Error"));
    try std.testing.expectEqual(Level.panic, try parse_level("PANIC"));

    std.debug.assert(@intFromEnum(try parse_level("DEBUG")) == 0);
    std.debug.assert(@intFromEnum(try parse_level("INFO")) == 1);
}

test "parse_level rejects invalid input" {
    try std.testing.expectError(error.InvalidLevel, parse_level("trace"));
    try std.testing.expectError(error.InvalidLevel, parse_level("verbose"));
    try std.testing.expectError(error.InvalidLevel, parse_level("critical"));
    try std.testing.expectError(error.InvalidLevel, parse_level("none"));

    std.debug.assert(parse_level("trace") == error.InvalidLevel);
    std.debug.assert(parse_level("debug") != error.InvalidLevel);
}

test "atomic_level init and read" {
    const atomic = AtomicLevel.init(.info);
    const current = atomic.level();

    try std.testing.expectEqual(Level.info, current);

    std.debug.assert(@intFromEnum(current) == @intFromEnum(Level.info));
    std.debug.assert(atomic.enabled(.info));
}

test "atomic_level set and enabled" {
    var atomic = AtomicLevel.init(.info);

    try std.testing.expect(!atomic.enabled(.debug));
    try std.testing.expect(atomic.enabled(.info));
    try std.testing.expect(atomic.enabled(.warn));

    atomic.set_level(.warn);

    try std.testing.expect(!atomic.enabled(.debug));
    try std.testing.expect(!atomic.enabled(.info));
    try std.testing.expect(atomic.enabled(.warn));
    try std.testing.expect(atomic.enabled(.err));

    std.debug.assert(atomic.level() == .warn);
    std.debug.assert(!atomic.enabled(.debug));
}

test "atomic_level to_string round trip" {
    var atomic = AtomicLevel.init(.err);

    const text = atomic.level().to_string();

    try std.testing.expectEqualStrings("error", text);

    std.debug.assert(text.len > 0);
    std.debug.assert(text.len <= 8);
}

test "atomic_level set via parse_level" {
    var atomic = AtomicLevel.init(.debug);

    const parsed = try parse_level("warn");
    atomic.set_level(parsed);

    try std.testing.expectEqual(Level.warn, atomic.level());

    std.debug.assert(atomic.level() == .warn);
    std.debug.assert(atomic.enabled(.warn));
}

test "atomic_level parse_level rejects invalid" {
    var atomic = AtomicLevel.init(.debug);

    try std.testing.expectError(
        error.InvalidLevel,
        parse_level("garbage"),
    );

    try std.testing.expectEqual(Level.debug, atomic.level());

    std.debug.assert(atomic.level() == .debug);
    std.debug.assert(atomic.enabled(.debug));
}
