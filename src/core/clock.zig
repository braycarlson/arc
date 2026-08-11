const std = @import("std");

const assert = std.debug.assert;

pub const Clock = union(enum) {
    system: void,
    fixed: i64,

    pub fn init_system() Clock {
        return .{ .system = {} };
    }

    pub fn init_fixed(timestamp_s: i64) Clock {
        assert(timestamp_s >= 0);

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
        assert(timestamp_s >= 0);

        self.* = .{ .fixed = timestamp_s };
    }

    pub fn advance(self: *Clock, seconds: i64) void {
        assert(seconds > 0);
        assert(self.* == .fixed);

        switch (self.*) {
            .fixed => |*timestamp| timestamp.* += seconds,
            .system => {},
        }
    }
};

const testing = std.testing;

test "a system clock reports itself as a system clock" {
    const clock = Clock.init_system();

    try testing.expect(@as(std.meta.Tag(Clock), clock) == .system);

    const now_s = clock.now(testing.io);
    const now_ns = clock.now_nano(testing.io);

    try testing.expect(now_s > 0);
    try testing.expect(now_ns > 0);

    assert(now_s > 0);
    assert(now_ns > 0);
}

test "a fixed clock returns the exact instant it was built with" {
    const clock = Clock.init_fixed(123);

    try testing.expectEqual(@as(i64, 123), clock.now(testing.io));
    try testing.expectEqual(@as(i128, 123_000_000_000), clock.now_nano(testing.io));

    assert(clock.now(testing.io) == 123);
    assert(clock.now_nano(testing.io) == 123_000_000_000);
}

test "setting a fixed clock moves it to the new instant" {
    var clock = Clock.init_fixed(10);

    try testing.expectEqual(@as(i64, 10), clock.now(testing.io));

    clock.set_fixed(25);

    try testing.expectEqual(@as(i64, 25), clock.now(testing.io));
    try testing.expectEqual(@as(i128, 25_000_000_000), clock.now_nano(testing.io));

    assert(clock.now(testing.io) == 25);
    assert(clock.now_nano(testing.io) == 25_000_000_000);
}

test "advancing a fixed clock moves it forward by the given seconds" {
    var clock = Clock.init_fixed(100);

    clock.advance(1);
    try testing.expectEqual(@as(i64, 101), clock.now(testing.io));

    clock.advance(9);
    try testing.expectEqual(@as(i64, 110), clock.now(testing.io));
    try testing.expectEqual(@as(i128, 110_000_000_000), clock.now_nano(testing.io));

    assert(clock.now(testing.io) == 110);
    assert(clock.now_nano(testing.io) == 110_000_000_000);
}

test "repeated advances accumulate on a fixed clock" {
    var clock = Clock.init_fixed(1);

    var total: i64 = 1;
    const steps = [_]i64{ 2, 3, 5, 8, 13 };

    for (steps) |step| {
        clock.advance(step);
        total += step;
    }

    try testing.expectEqual(total, clock.now(testing.io));
    try testing.expectEqual(@as(i128, total) * 1_000_000_000, clock.now_nano(testing.io));

    assert(clock.now(testing.io) == total);
}
