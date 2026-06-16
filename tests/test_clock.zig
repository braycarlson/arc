const std = @import("std");
const arc = @import("arc");

const Clock = arc.Clock;

test "system clock initializes as system" {
    const clock = Clock.init_system();

    try std.testing.expect(@as(arc.clock_mod.ClockType, clock) == .system);

    const now_s = clock.now(std.testing.io);
    const now_ns = clock.now_nano(std.testing.io);

    try std.testing.expect(now_s > 0);
    try std.testing.expect(now_ns > 0);

    std.debug.assert(now_s > 0);
    std.debug.assert(now_ns > 0);
}

test "fixed clock returns exact seconds and nanos" {
    const clock = Clock.init_fixed(123);

    try std.testing.expectEqual(@as(i64, 123), clock.now(std.testing.io));
    try std.testing.expectEqual(@as(i128, 123_000_000_000), clock.now_nano(std.testing.io));

    std.debug.assert(clock.now(std.testing.io) == 123);
    std.debug.assert(clock.now_nano(std.testing.io) == 123_000_000_000);
}

test "fixed clock can be updated with set_fixed" {
    var clock = Clock.init_fixed(10);

    try std.testing.expectEqual(@as(i64, 10), clock.now(std.testing.io));

    clock.set_fixed(25);

    try std.testing.expectEqual(@as(i64, 25), clock.now(std.testing.io));
    try std.testing.expectEqual(@as(i128, 25_000_000_000), clock.now_nano(std.testing.io));

    std.debug.assert(clock.now(std.testing.io) == 25);
    std.debug.assert(clock.now_nano(std.testing.io) == 25_000_000_000);
}

test "fixed clock advance increments timestamp" {
    var clock = Clock.init_fixed(100);

    clock.advance(1);
    try std.testing.expectEqual(@as(i64, 101), clock.now(std.testing.io));

    clock.advance(9);
    try std.testing.expectEqual(@as(i64, 110), clock.now(std.testing.io));
    try std.testing.expectEqual(@as(i128, 110_000_000_000), clock.now_nano(std.testing.io));

    std.debug.assert(clock.now(std.testing.io) == 110);
    std.debug.assert(clock.now_nano(std.testing.io) == 110_000_000_000);
}

test "fixed clock supports repeated advances" {
    var clock = Clock.init_fixed(1);

    var total: i64 = 1;
    const steps = [_]i64{ 2, 3, 5, 8, 13 };

    for (steps) |step| {
        clock.advance(step);
        total += step;
    }

    try std.testing.expectEqual(total, clock.now(std.testing.io));
    try std.testing.expectEqual(@as(i128, total) * 1_000_000_000, clock.now_nano(std.testing.io));

    std.debug.assert(clock.now(std.testing.io) == total);
}
