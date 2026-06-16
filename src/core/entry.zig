const std = @import("std");
const clock_mod = @import("clock.zig");
const level_mod = @import("level.zig");

const Clock = clock_mod.Clock;
const Level = level_mod.Level;

pub const name_max: u32 = 128;
pub const caller_max: u32 = 256;
pub const function_max: u32 = 256;
pub const stack_max: u32 = 2048;

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

pub const nanos_per_second: i64 = 1_000_000_000;

pub const Entry = struct {
    level: Level,
    timestamp_s: i64,
    timestamp_ns: i64,
    message: []const u8,
    logger_name: []const u8,
    caller: Caller,
    stack_buffer: [stack_max]u8,
    stack_length: u32,
    context_cache: ?ContextCache,

    pub fn init(io: std.Io, at_level: Level, message: []const u8, logger_name: []const u8) Entry {
        std.debug.assert(logger_name.len <= name_max);

        const now = std.Io.Timestamp.now(io, .real);
        const nanos: i64 = @intCast(@min(now.toNanoseconds(), std.math.maxInt(i64)));

        var entry: Entry = undefined;
        entry.level = at_level;
        entry.timestamp_ns = nanos;
        entry.timestamp_s = @divFloor(nanos, nanos_per_second);
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
        std.debug.assert(logger_name.len <= name_max);

        const nanos: i64 = @intCast(@min(clock.now_nano(io), std.math.maxInt(i64)));

        var entry: Entry = undefined;
        entry.level = at_level;
        entry.timestamp_ns = nanos;
        entry.timestamp_s = @divFloor(nanos, nanos_per_second);
        entry.message = message;
        entry.logger_name = logger_name;
        entry.caller = .{ .file = "", .line = 0, .function = "", .defined = false };
        entry.stack_length = 0;
        entry.context_cache = null;

        return entry;
    }

    pub fn with_caller(self: *Entry, file: []const u8, line: u32, function: []const u8) void {
        std.debug.assert(file.len > 0);
        std.debug.assert(file.len <= caller_max);
        std.debug.assert(line > 0);
        std.debug.assert(function.len <= function_max);

        self.caller = .{
            .file = file,
            .line = line,
            .function = function,
            .defined = true,
        };
    }

    pub fn with_stack(self: *Entry, stack_data: []const u8) void {
        std.debug.assert(stack_data.len > 0);

        const copy_length = @min(stack_data.len, stack_max);
        @memcpy(self.stack_buffer[0..copy_length], stack_data[0..copy_length]);
        self.stack_length = @intCast(copy_length);

        std.debug.assert(self.stack_length > 0);
    }

    pub fn stack(self: *const Entry) []const u8 {
        std.debug.assert(self.has_stack());

        return self.stack_buffer[0..self.stack_length];
    }

    pub fn has_stack(self: *const Entry) bool {
        std.debug.assert(self.stack_length <= stack_max);

        return self.stack_length > 0;
    }
};

pub fn caller_short_path(file: []const u8) []const u8 {
    std.debug.assert(file.len > 0);
    std.debug.assert(file.len <= caller_max);

    var last_separator: usize = 0;
    var penultimate_separator: usize = 0;

    for (file, 0..) |byte, index| {
        if (byte == '/' or byte == '\\') {
            penultimate_separator = last_separator;
            last_separator = index;
        }
    }

    const start = if (penultimate_separator > 0) penultimate_separator + 1 else 0;

    std.debug.assert(start <= file.len);
    return file[start..];
}
