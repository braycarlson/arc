const std = @import("std");
const entry_mod = @import("core/entry.zig");
const field_mod = @import("core/field.zig");
const level_mod = @import("core/level.zig");

const Field = field_mod.Field;
const Level = level_mod.Level;
const Logger = @import("logger.zig").Logger;
const SourceLocation = std.builtin.SourceLocation;

pub const message_max: u32 = 1024;

pub const SugaredLogger = struct {
    logger: *Logger,
    message_buffer: [message_max]u8,

    pub fn init(logger: *Logger) SugaredLogger {
        std.debug.assert(logger.name_length <= entry_mod.name_max);

        var result: SugaredLogger = undefined;
        result.logger = logger;

        return result;
    }

    pub fn format_message(
        self: *SugaredLogger,
        comptime format: []const u8,
        args: anytype,
    ) []const u8 {
        std.debug.assert(format.len > 0);

        var writer = std.Io.Writer.fixed(&self.message_buffer);

        writer.print(format, args) catch {};

        const written = writer.buffered();

        std.debug.assert(written.len <= message_max);
        return written;
    }

    fn log_formatted(
        self: *SugaredLogger,
        at_level: Level,
        comptime format: []const u8,
        args: anytype,
        src: SourceLocation,
    ) void {
        std.debug.assert(format.len > 0);

        const message = self.format_message(format, args);

        self.logger.log(at_level, message, &.{}, src);
    }

    pub fn debugf(
        self: *SugaredLogger,
        comptime format: []const u8,
        args: anytype,
        src: SourceLocation,
    ) void {
        self.log_formatted(.debug, format, args, src);
    }

    pub fn infof(
        self: *SugaredLogger,
        comptime format: []const u8,
        args: anytype,
        src: SourceLocation,
    ) void {
        self.log_formatted(.info, format, args, src);
    }

    pub fn warnf(
        self: *SugaredLogger,
        comptime format: []const u8,
        args: anytype,
        src: SourceLocation,
    ) void {
        self.log_formatted(.warn, format, args, src);
    }

    pub fn errorf(
        self: *SugaredLogger,
        comptime format: []const u8,
        args: anytype,
        src: SourceLocation,
    ) void {
        self.log_formatted(.err, format, args, src);
    }

    pub fn dpanicf(
        self: *SugaredLogger,
        comptime format: []const u8,
        args: anytype,
        src: SourceLocation,
    ) void {
        self.log_formatted(.dpanic, format, args, src);
    }

    pub fn panicf(
        self: *SugaredLogger,
        comptime format: []const u8,
        args: anytype,
        src: SourceLocation,
    ) void {
        self.log_formatted(.panic, format, args, src);
    }

    pub fn fatalf(
        self: *SugaredLogger,
        comptime format: []const u8,
        args: anytype,
        src: SourceLocation,
    ) void {
        self.log_formatted(.fatal, format, args, src);
    }

    pub fn debugw(
        self: *SugaredLogger,
        message: []const u8,
        fields: []const Field,
        src: SourceLocation,
    ) void {
        self.logger.log(.debug, message, fields, src);
    }

    pub fn infow(
        self: *SugaredLogger,
        message: []const u8,
        fields: []const Field,
        src: SourceLocation,
    ) void {
        self.logger.log(.info, message, fields, src);
    }

    pub fn warnw(
        self: *SugaredLogger,
        message: []const u8,
        fields: []const Field,
        src: SourceLocation,
    ) void {
        self.logger.log(.warn, message, fields, src);
    }

    pub fn errorw(
        self: *SugaredLogger,
        message: []const u8,
        fields: []const Field,
        src: SourceLocation,
    ) void {
        self.logger.log(.err, message, fields, src);
    }

    pub fn dpanicw(
        self: *SugaredLogger,
        message: []const u8,
        fields: []const Field,
        src: SourceLocation,
    ) void {
        self.logger.log(.dpanic, message, fields, src);
    }

    pub fn panicw(
        self: *SugaredLogger,
        message: []const u8,
        fields: []const Field,
        src: SourceLocation,
    ) void {
        self.logger.log(.panic, message, fields, src);
    }

    pub fn fatalw(
        self: *SugaredLogger,
        message: []const u8,
        fields: []const Field,
        src: SourceLocation,
    ) void {
        self.logger.log(.fatal, message, fields, src);
    }
};
