const std = @import("std");
const entry_mod = @import("core/entry.zig");
const field_mod = @import("core/field.zig");
const level_mod = @import("core/level.zig");
const buffer_mod = @import("io/buffer.zig");

const assert = std.debug.assert;

const Field = field_mod.Field;
const Level = level_mod.Level;
const Logger = @import("logger.zig").Logger;
const SourceLocation = std.builtin.SourceLocation;

pub const SugaredLogger = struct {
    logger: *Logger,
    message_buffer: [message_bytes_max]u8,
    truncated: bool,

    pub fn init(logger: *Logger) SugaredLogger {
        assert(logger.name_length <= entry_mod.name_bytes_max);

        var result: SugaredLogger = undefined;
        result.logger = logger;
        result.truncated = false;

        return result;
    }

    pub fn format_message(
        self: *SugaredLogger,
        comptime format: []const u8,
        args: anytype,
    ) []const u8 {
        assert(format.len > 0);

        var writer = std.Io.Writer.fixed(&self.message_buffer);

        self.truncated = false;

        writer.print(format, args) catch |print_error| switch (print_error) {
            error.WriteFailed => self.truncated = true,
        };

        const written = writer.buffered();

        assert(written.len <= message_bytes_max);

        return written;
    }

    pub fn was_truncated(self: *const SugaredLogger) bool {
        return self.truncated;
    }

    fn log_formatted(
        self: *SugaredLogger,
        at_level: Level,
        comptime format: []const u8,
        args: anytype,
        source: SourceLocation,
    ) void {
        assert(format.len > 0);
        assert(self.logger.is_valid());

        const message = self.format_message(format, args);

        assert(message.len <= message_bytes_max);

        self.logger.log(at_level, message, &.{}, source);
    }

    pub fn debugf(
        self: *SugaredLogger,
        comptime format: []const u8,
        args: anytype,
        source: SourceLocation,
    ) void {
        assert(format.len > 0);

        self.log_formatted(.debug, format, args, source);
    }

    pub fn infof(
        self: *SugaredLogger,
        comptime format: []const u8,
        args: anytype,
        source: SourceLocation,
    ) void {
        assert(format.len > 0);

        self.log_formatted(.info, format, args, source);
    }

    pub fn warnf(
        self: *SugaredLogger,
        comptime format: []const u8,
        args: anytype,
        source: SourceLocation,
    ) void {
        assert(format.len > 0);

        self.log_formatted(.warn, format, args, source);
    }

    pub fn errorf(
        self: *SugaredLogger,
        comptime format: []const u8,
        args: anytype,
        source: SourceLocation,
    ) void {
        assert(format.len > 0);

        self.log_formatted(.err, format, args, source);
    }

    pub fn dpanicf(
        self: *SugaredLogger,
        comptime format: []const u8,
        args: anytype,
        source: SourceLocation,
    ) void {
        assert(format.len > 0);

        self.log_formatted(.dpanic, format, args, source);
    }

    pub fn panicf(
        self: *SugaredLogger,
        comptime format: []const u8,
        args: anytype,
        source: SourceLocation,
    ) void {
        assert(format.len > 0);

        self.log_formatted(.panic, format, args, source);
    }

    pub fn fatalf(
        self: *SugaredLogger,
        comptime format: []const u8,
        args: anytype,
        source: SourceLocation,
    ) void {
        assert(format.len > 0);

        self.log_formatted(.fatal, format, args, source);
    }

    pub fn debugw(
        self: *SugaredLogger,
        message: []const u8,
        fields: []const Field,
        source: SourceLocation,
    ) void {
        assert(fields.len <= field_mod.fields_max);
        assert(self.logger.is_valid());

        self.logger.log(.debug, message, fields, source);
    }

    pub fn infow(
        self: *SugaredLogger,
        message: []const u8,
        fields: []const Field,
        source: SourceLocation,
    ) void {
        assert(fields.len <= field_mod.fields_max);
        assert(self.logger.is_valid());

        self.logger.log(.info, message, fields, source);
    }

    pub fn warnw(
        self: *SugaredLogger,
        message: []const u8,
        fields: []const Field,
        source: SourceLocation,
    ) void {
        assert(fields.len <= field_mod.fields_max);
        assert(self.logger.is_valid());

        self.logger.log(.warn, message, fields, source);
    }

    pub fn errorw(
        self: *SugaredLogger,
        message: []const u8,
        fields: []const Field,
        source: SourceLocation,
    ) void {
        assert(fields.len <= field_mod.fields_max);
        assert(self.logger.is_valid());

        self.logger.log(.err, message, fields, source);
    }

    pub fn dpanicw(
        self: *SugaredLogger,
        message: []const u8,
        fields: []const Field,
        source: SourceLocation,
    ) void {
        assert(fields.len <= field_mod.fields_max);
        assert(self.logger.is_valid());

        self.logger.log(.dpanic, message, fields, source);
    }

    pub fn panicw(
        self: *SugaredLogger,
        message: []const u8,
        fields: []const Field,
        source: SourceLocation,
    ) void {
        assert(fields.len <= field_mod.fields_max);
        assert(self.logger.is_valid());

        self.logger.log(.panic, message, fields, source);
    }

    pub fn fatalw(
        self: *SugaredLogger,
        message: []const u8,
        fields: []const Field,
        source: SourceLocation,
    ) void {
        assert(fields.len <= field_mod.fields_max);
        assert(self.logger.is_valid());

        self.logger.log(.fatal, message, fields, source);
    }
};

pub const message_bytes_max: u32 = 1024;

comptime {
    assert(message_bytes_max > 0);
    assert(message_bytes_max <= buffer_mod.buffer_bytes_max);
}

const testing = std.testing;

const Buffer = @import("io/buffer.zig").Buffer;
const Clock = @import("core/clock.zig").Clock;
const Config = @import("config.zig").Config;

fn sugar_logger(output: *Buffer) Logger {
    var logger = Logger.init_with_config(
        testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = output })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    return logger;
}

test "a sugared logger keeps the logger it was built from" {
    var output = Buffer.init();
    var logger = sugar_logger(&output);

    const sugared = SugaredLogger.init(&logger);

    try testing.expect(sugared.logger == &logger);

    assert(sugared.logger == &logger);
}

test "formatting a message substitutes every argument" {
    var output = Buffer.init();
    var logger = sugar_logger(&output);
    var sugared = SugaredLogger.init(&logger);

    const message = sugared.format_message("{s} took {d}ms", .{ "request", 42 });

    try testing.expectEqualStrings("request took 42ms", message);

    assert(message.len == 17);
}

test "formatting a message that overflows the buffer keeps what fits" {
    var output = Buffer.init();
    var logger = sugar_logger(&output);
    var sugared = SugaredLogger.init(&logger);

    var payload: [message_bytes_max * 2]u8 = @splat('x');
    const message = sugared.format_message("{s}", .{payload[0..]});

    try testing.expect(message.len <= message_bytes_max);

    assert(message.len <= message_bytes_max);
}

test "each formatting method logs at its own level" {
    const Case = struct {
        level_text: []const u8,
        log: *const fn (*SugaredLogger, std.builtin.SourceLocation) void,
    };

    const cases = [_]Case{
        .{ .level_text = "debug", .log = struct {
            fn call(sugared: *SugaredLogger, source: SourceLocation) void {
                sugared.debugf("count {d}", .{1}, source);
            }
        }.call },
        .{ .level_text = "info", .log = struct {
            fn call(sugared: *SugaredLogger, source: SourceLocation) void {
                sugared.infof("count {d}", .{2}, source);
            }
        }.call },
        .{ .level_text = "warn", .log = struct {
            fn call(sugared: *SugaredLogger, source: SourceLocation) void {
                sugared.warnf("count {d}", .{3}, source);
            }
        }.call },
        .{ .level_text = "error", .log = struct {
            fn call(sugared: *SugaredLogger, source: SourceLocation) void {
                sugared.errorf("count {d}", .{4}, source);
            }
        }.call },
    };

    for (cases, 1..) |case, expected| {
        var output = Buffer.init();
        var logger = sugar_logger(&output);
        var sugared = SugaredLogger.init(&logger);

        case.log(&sugared, @src());

        var scratch: [16]u8 = undefined;
        const rendered = try std.fmt.bufPrint(&scratch, "count {d}", .{expected});

        try testing.expect(output.contains(rendered));
        try testing.expect(output.contains(case.level_text));
    }
}

test "each wide method forwards its fields to the logger" {
    var output = Buffer.init();
    var logger = sugar_logger(&output);
    var sugared = SugaredLogger.init(&logger);

    sugared.debugw("debug wide", &.{field_mod.string("phase", "one")}, @src());
    sugared.infow("info wide", &.{field_mod.int64("count", 7)}, @src());
    sugared.warnw("warn wide", &.{field_mod.boolean("retry", true)}, @src());
    sugared.errorw("error wide", &.{field_mod.uint64("size", 9)}, @src());

    try testing.expect(output.contains("debug wide"));
    try testing.expect(output.contains("\"phase\":\"one\""));
    try testing.expect(output.contains("\"count\":7"));
    try testing.expect(output.contains("\"retry\":true"));
    try testing.expect(output.contains("\"size\":9"));

    assert(output.contains("error wide"));
}

test "a level below the threshold produces no output" {
    var output = Buffer.init();

    var logger = Logger.init_with_config(
        testing.io,
        Config.production()
            .with_level(.warn)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    var sugared = SugaredLogger.init(&logger);

    sugared.infof("hidden {d}", .{1}, @src());

    try testing.expect(output.is_empty());

    sugared.warnf("shown {d}", .{2}, @src());

    try testing.expect(output.contains("shown 2"));

    assert(!output.is_empty());
}
