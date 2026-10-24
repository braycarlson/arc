const std = @import("std");

const level_module = @import("level.zig");

const assert = std.debug.assert;

const Level = level_module.Level;

pub const Record = struct {
    caller: ?Caller,
    level: Level,
    message: []const u8,
    name: []const u8,
    time_ns: i64,

    pub const Caller = struct {
        file: []const u8,
        function: []const u8,
        line: u32,

        pub fn of(source: *const std.lang.SourceLocation) Caller {
            assert(source.file.len > 0);
            assert(source.line > 0);

            return .{ .file = source.file, .function = source.fn_name, .line = source.line };
        }

        pub fn file_short(caller: *const Caller) []const u8 {
            assert(caller.file.len > 0);
            assert(caller.line > 0);

            const separator_last = std.mem.findLastAny(u8, caller.file, separators) orelse {
                return caller.file;
            };

            const head = caller.file[0..separator_last];

            const separator_previous = std.mem.findLastAny(u8, head, separators) orelse {
                return caller.file;
            };

            const result = caller.file[separator_previous + 1 ..];

            assert(result.len > 0);
            assert(result.len < caller.file.len);

            return result;
        }
    };
};

const separators = "/\\";

const testing = std.testing;

test Record {
    const record: Record = .{
        .caller = .of(&.{
            .module = "arc",
            .file = "/home/user/src/http/server.zig",
            .line = 42,
            .column = 7,
            .fn_name = "handle",
        }),
        .level = .warn,
        .message = "slow response",
        .name = "http",
        .time_ns = 0,
    };

    const caller = record.caller orelse return error.CallerMissing;

    try testing.expectEqualStrings("http/server.zig", caller.file_short());
    try testing.expectEqualStrings("handle", caller.function);
    try testing.expectEqual(@as(u32, 42), caller.line);
}

test "a short caller path keeps the last two segments of either separator" {
    const cases = [_][2][]const u8{
        .{ "main.zig", "main.zig" },
        .{ "src/main.zig", "src/main.zig" },
        .{ "/src/main.zig", "src/main.zig" },
        .{ "a/b/c/main.zig", "c/main.zig" },
        .{ "C:\\project\\src\\main.zig", "src\\main.zig" },
        .{ "a\\b/main.zig", "b/main.zig" },
    };

    for (cases) |case| {
        const caller: Record.Caller = .{ .file = case[0], .function = "", .line = 1 };

        try testing.expectEqualStrings(case[1], caller.file_short());
    }
}
