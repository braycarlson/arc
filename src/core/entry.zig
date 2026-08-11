const std = @import("std");
const clock_mod = @import("clock.zig");
const level_mod = @import("level.zig");

const assert = std.debug.assert;

const Clock = clock_mod.Clock;
const Level = level_mod.Level;

pub const Entry = struct {
    level: Level,
    timestamp_s: i64,
    timestamp_ns: i64,
    message: []const u8,
    logger_name: []const u8,
    caller: Caller,
    stack_buffer: [stack_bytes_max]u8,
    stack_length: u32,
    context_cache: ?ContextCache,

    pub fn init(io: std.Io, at_level: Level, message: []const u8, logger_name: []const u8) Entry {
        assert(logger_name.len <= name_bytes_max);

        const now = std.Io.Timestamp.now(io, .real);
        const nanoseconds: i64 = @intCast(@min(now.toNanoseconds(), std.math.maxInt(i64)));

        var entry: Entry = undefined;
        entry.level = at_level;
        entry.timestamp_ns = nanoseconds;
        entry.timestamp_s = @divFloor(nanoseconds, nanoseconds_per_second);
        entry.message = message;
        entry.logger_name = logger_name;
        entry.caller = .{ .file = "", .line = 0, .function = "", .defined = false };
        entry.stack_length = 0;
        entry.context_cache = null;

        return entry;
    }

    pub fn init_with_clock(
        io: std.Io,
        at_level: Level,
        message: []const u8,
        logger_name: []const u8,
        clock: *const Clock,
    ) Entry {
        assert(logger_name.len <= name_bytes_max);

        const nanoseconds: i64 = @intCast(@min(clock.now_nano(io), std.math.maxInt(i64)));

        var entry: Entry = undefined;
        entry.level = at_level;
        entry.timestamp_ns = nanoseconds;
        entry.timestamp_s = @divFloor(nanoseconds, nanoseconds_per_second);
        entry.message = message;
        entry.logger_name = logger_name;
        entry.caller = .{ .file = "", .line = 0, .function = "", .defined = false };
        entry.stack_length = 0;
        entry.context_cache = null;

        return entry;
    }

    pub const CallerSite = struct {
        file: []const u8,
        line: u32,
        function: []const u8,
    };

    pub fn copy_into(self: *const Entry, target: *Entry) void {
        assert(self.stack_length <= stack_bytes_max);

        target.level = self.level;
        target.timestamp_s = self.timestamp_s;
        target.timestamp_ns = self.timestamp_ns;
        target.message = self.message;
        target.logger_name = self.logger_name;
        target.caller = self.caller;
        target.context_cache = self.context_cache;
        target.stack_length = self.stack_length;

        const used = self.stack_length;

        @memcpy(target.stack_buffer[0..used], self.stack_buffer[0..used]);

        assert(target.stack_length == self.stack_length);
    }

    pub fn with_caller(self: *Entry, site: CallerSite) void {
        assert(site.file.len > 0);
        assert(site.file.len <= caller_bytes_max);
        assert(site.line > 0);
        assert(site.function.len <= function_bytes_max);

        self.caller = .{
            .file = site.file,
            .line = site.line,
            .function = site.function,
            .defined = true,
        };
    }

    pub fn with_stack(self: *Entry, stack_data: []const u8) void {
        assert(stack_data.len > 0);

        const copy_length = @min(stack_data.len, stack_bytes_max);
        @memcpy(self.stack_buffer[0..copy_length], stack_data[0..copy_length]);
        self.stack_length = @intCast(copy_length);

        assert(self.stack_length > 0);
    }

    pub fn stack(self: *const Entry) []const u8 {
        assert(self.has_stack());

        return self.stack_buffer[0..self.stack_length];
    }

    pub fn has_stack(self: *const Entry) bool {
        assert(self.stack_length <= stack_bytes_max);

        return self.stack_length > 0;
    }
};

pub const Caller = struct {
    file: []const u8,
    line: u32,
    function: []const u8,
    defined: bool,
};

pub const ContextCache = struct {
    bytes: []const u8,
    field_count: u32,
    namespace_depth: u32,
};

pub const name_bytes_max: u32 = 128;
pub const caller_bytes_max: u32 = 256;
pub const function_bytes_max: u32 = 256;
pub const stack_bytes_max: u32 = 2048;

pub const nanoseconds_per_second: i64 = 1_000_000_000;

comptime {
    assert(name_bytes_max > 0);
    assert(caller_bytes_max > 0);
    assert(function_bytes_max > 0);
    assert(stack_bytes_max > 0);
    assert(nanoseconds_per_second > 0);
}

pub fn caller_short_path(file: []const u8) []const u8 {
    assert(file.len > 0);
    assert(file.len <= caller_bytes_max);

    var last_separator: usize = 0;
    var penultimate_separator: usize = 0;

    for (file, 0..) |byte, index| {
        if (byte == '/' or byte == '\\') {
            penultimate_separator = last_separator;
            last_separator = index;
        }
    }

    const start = if (penultimate_separator > 0) penultimate_separator + 1 else 0;

    assert(start <= file.len);

    return file[start..];
}

const testing = std.testing;

test "a new entry carries the level, message, and logger name it was built with" {
    const entry = Entry.init(testing.io, .info, "hello", "app");

    try testing.expectEqual(Level.info, entry.level);
    try testing.expectEqualStrings("hello", entry.message);
    try testing.expectEqualStrings("app", entry.logger_name);
    try testing.expect(!entry.caller.defined);
    try testing.expectEqual(@as(u32, 0), entry.stack_length);

    assert(entry.timestamp_s > 0);
    assert(entry.stack_length == 0);
}

test "an entry built with a fixed clock carries that clock's instant" {
    const clock = Clock.init_fixed(1_700_000_000);
    const entry = Entry.init_with_clock(testing.io, .warn, "test", "svc", &clock);

    try testing.expectEqual(@as(i64, 1_700_000_000), entry.timestamp_s);
    try testing.expectEqual(Level.warn, entry.level);
    try testing.expectEqualStrings("test", entry.message);

    assert(entry.timestamp_s == 1_700_000_000);
    assert(entry.stack_length == 0);
}

test "adding caller information records the file, line, and function" {
    var entry = Entry.init(testing.io, .info, "msg", "");

    entry.with_caller(.{ .file = "src/main.zig", .line = 42, .function = "main" });

    try testing.expect(entry.caller.defined);
    try testing.expectEqualStrings("src/main.zig", entry.caller.file);
    try testing.expectEqual(@as(u32, 42), entry.caller.line);
    try testing.expectEqualStrings("main", entry.caller.function);

    assert(entry.caller.defined);
    assert(entry.caller.line == 42);
}

test "adding a stack stores its text on the entry" {
    var entry = Entry.init(testing.io, .err, "crash", "");
    const stack_data = "0xdeadbeef\n0xcafebabe";

    entry.with_stack(stack_data);

    try testing.expect(entry.has_stack());
    try testing.expectEqualStrings(stack_data, entry.stack());
    try testing.expectEqual(@as(u32, @intCast(stack_data.len)), entry.stack_length);

    assert(entry.stack_length > 0);
    assert(entry.stack_length <= stack_bytes_max);
}

test "an entry built without a stack carries none" {
    const entry = Entry.init(testing.io, .debug, "msg", "");

    try testing.expect(!entry.has_stack());
    try testing.expectEqual(@as(u32, 0), entry.stack_length);

    assert(entry.stack_length == 0);
    assert(!entry.has_stack());
}

test "an entry accepts every level" {
    const levels = [_]Level{ .debug, .info, .warn, .err, .dpanic, .panic, .fatal };

    for (levels) |at_level| {
        const entry = Entry.init(testing.io, at_level, "test", "");

        try testing.expectEqual(at_level, entry.level);

        assert(@intFromEnum(entry.level) <= @intFromEnum(Level.fatal));
    }

    assert(levels.len == 7);
}
