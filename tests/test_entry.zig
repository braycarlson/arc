const std = @import("std");
const arc = @import("arc");

const Clock = arc.Clock;
const Entry = arc.entry_mod.Entry;
const Level = arc.Level;

test "entry init sets fields correctly" {
    const entry = Entry.init(std.testing.io, .info, "hello", "app");

    try std.testing.expectEqual(Level.info, entry.level);
    try std.testing.expectEqualStrings("hello", entry.message);
    try std.testing.expectEqualStrings("app", entry.logger_name);
    try std.testing.expect(!entry.caller.defined);
    try std.testing.expectEqual(@as(u32, 0), entry.stack_length);

    std.debug.assert(entry.timestamp_s > 0);
    std.debug.assert(entry.stack_length == 0);
}

test "entry init_with_clock uses fixed timestamp" {
    const clock = Clock.init_fixed(1_700_000_000);
    const entry = Entry.init_with_clock(std.testing.io, .warn, "test", "svc", &clock);

    try std.testing.expectEqual(@as(i64, 1_700_000_000), entry.timestamp_s);
    try std.testing.expectEqual(Level.warn, entry.level);
    try std.testing.expectEqualStrings("test", entry.message);

    std.debug.assert(entry.timestamp_s == 1_700_000_000);
    std.debug.assert(entry.stack_length == 0);
}

test "entry with_caller sets caller info" {
    var entry = Entry.init(std.testing.io, .info, "msg", "");

    entry.with_caller("src/main.zig", 42, "main");

    try std.testing.expect(entry.caller.defined);
    try std.testing.expectEqualStrings("src/main.zig", entry.caller.file);
    try std.testing.expectEqual(@as(u32, 42), entry.caller.line);
    try std.testing.expectEqualStrings("main", entry.caller.function);

    std.debug.assert(entry.caller.defined);
    std.debug.assert(entry.caller.line == 42);
}

test "entry with_stack stores stack data" {
    var entry = Entry.init(std.testing.io, .err, "crash", "");
    const stack_data = "0xdeadbeef\n0xcafebabe";

    entry.with_stack(stack_data);

    try std.testing.expect(entry.has_stack());
    try std.testing.expectEqualStrings(stack_data, entry.stack());
    try std.testing.expectEqual(@as(u32, @intCast(stack_data.len)), entry.stack_length);

    std.debug.assert(entry.stack_length > 0);
    std.debug.assert(entry.stack_length <= arc.entry_mod.stack_max);
}

test "entry without stack has no stack" {
    const entry = Entry.init(std.testing.io, .debug, "msg", "");

    try std.testing.expect(!entry.has_stack());
    try std.testing.expectEqual(@as(u32, 0), entry.stack_length);

    std.debug.assert(entry.stack_length == 0);
    std.debug.assert(!entry.has_stack());
}

test "entry all levels are valid" {
    const levels = [_]Level{ .debug, .info, .warn, .err, .dpanic, .panic, .fatal };

    for (levels) |at_level| {
        const entry = Entry.init(std.testing.io, at_level, "test", "");

        try std.testing.expectEqual(at_level, entry.level);

        std.debug.assert(@intFromEnum(entry.level) <= @intFromEnum(Level.fatal));
    }

    std.debug.assert(levels.len == 7);
}
