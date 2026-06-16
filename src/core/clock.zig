const std = @import("std");

pub const ClockType = enum(u8) {
    system,
    fixed,
};

pub const Clock = union(ClockType) {
    system: void,
    fixed: i64,

    pub fn init_system() Clock {
        return .{ .system = {} };
    }

    pub fn init_fixed(timestamp_s: i64) Clock {
        std.debug.assert(timestamp_s >= 0);

        return .{ .fixed = timestamp_s };
    }

    pub fn now(self: *const Clock, io: std.Io) i64 {
        return switch (self.*) {
            .system => std.Io.Timestamp.now(io, .real).toSeconds(),
            .fixed => |timestamp| timestamp,
        };
    }

    pub fn now_nano(self: *const Clock, io: std.Io) i128 {
        return switch (self.*) {
            .system => std.Io.Timestamp.now(io, .real).toNanoseconds(),
            .fixed => |timestamp| @as(i128, timestamp) * 1_000_000_000,
        };
    }

    pub fn set_fixed(self: *Clock, timestamp_s: i64) void {
        std.debug.assert(timestamp_s >= 0);

        self.* = .{ .fixed = timestamp_s };
    }

    pub fn advance(self: *Clock, seconds: i64) void {
        std.debug.assert(seconds > 0);
        std.debug.assert(self.* == .fixed);

        switch (self.*) {
            .fixed => |*timestamp| timestamp.* += seconds,
            .system => {},
        }
    }
};
