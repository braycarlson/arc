const std = @import("std");
const arc = @import("arc");

const Clock = arc.Clock;
const Decision = arc.sampler_mod.Decision;
const Level = arc.Level;
const Sampler = arc.sampler_mod.Sampler;
const SamplingCounter = arc.SamplingCounter;

test "sampler allows first N messages" {
    var sampler = Sampler.init(1_000_000_000, 3, 0);
    var clock = Clock.init_fixed(1_000_000_000);

    try std.testing.expectEqual(.sampled, sampler.check(std.testing.io, .info, "msg", &clock));
    try std.testing.expectEqual(.sampled, sampler.check(std.testing.io, .info, "msg", &clock));
    try std.testing.expectEqual(.sampled, sampler.check(std.testing.io, .info, "msg", &clock));
    try std.testing.expectEqual(.dropped, sampler.check(std.testing.io, .info, "msg", &clock));

    std.debug.assert(sampler.first == 3);
    std.debug.assert(sampler.thereafter == 0);
}

test "sampler allows every Nth after initial" {
    var sampler = Sampler.init(1_000_000_000, 1, 2);
    var clock = Clock.init_fixed(1_000_000_000);

    try std.testing.expectEqual(.sampled, sampler.check(std.testing.io, .info, "msg", &clock));
    try std.testing.expectEqual(.dropped, sampler.check(std.testing.io, .info, "msg", &clock));
    try std.testing.expectEqual(.sampled, sampler.check(std.testing.io, .info, "msg", &clock));
    try std.testing.expectEqual(.dropped, sampler.check(std.testing.io, .info, "msg", &clock));
    try std.testing.expectEqual(.sampled, sampler.check(std.testing.io, .info, "msg", &clock));

    std.debug.assert(sampler.first == 1);
    std.debug.assert(sampler.thereafter == 2);
}

test "sampler resets after tick interval" {
    var sampler = Sampler.init(1_000_000_000, 1, 0);
    var clock = Clock.init_fixed(1_000_000_000);

    try std.testing.expectEqual(.sampled, sampler.check(std.testing.io, .info, "msg", &clock));
    try std.testing.expectEqual(.dropped, sampler.check(std.testing.io, .info, "msg", &clock));

    clock.advance(2);

    try std.testing.expectEqual(.sampled, sampler.check(std.testing.io, .info, "msg", &clock));

    std.debug.assert(sampler.tick_ns > 0);
    std.debug.assert(sampler.first == 1);
}

test "sampler counter hook tracks decisions" {
    var counter = SamplingCounter.init();
    var sampler = Sampler.init(1_000_000_000, 1, 0);
    var clock = Clock.init_fixed(1_000_000_000);

    sampler.with_hook(.{ .counter = &counter });

    _ = sampler.check(std.testing.io, .info, "msg", &clock);
    _ = sampler.check(std.testing.io, .info, "msg", &clock);
    _ = sampler.check(std.testing.io, .info, "msg", &clock);

    try std.testing.expectEqual(@as(u64, 1), counter.sampled_count());
    try std.testing.expectEqual(@as(u64, 2), counter.dropped_count());

    std.debug.assert(counter.sampled_count() + counter.dropped_count() == 3);
    std.debug.assert(counter.sampled_count() == 1);
}

test "sampler different messages hash independently" {
    var sampler = Sampler.init(1_000_000_000, 1, 0);
    var clock = Clock.init_fixed(1_000_000_000);

    try std.testing.expectEqual(.sampled, sampler.check(std.testing.io, .info, "msg_a", &clock));
    try std.testing.expectEqual(.sampled, sampler.check(std.testing.io, .info, "msg_b", &clock));

    std.debug.assert(sampler.first == 1);
    std.debug.assert(sampler.tick_ns > 0);
}

test "sampler keeps first N then drops when thereafter is zero" {
    var clock = Clock.init_fixed(100);
    var sampler = Sampler.init(1_000_000_000, 2, 0);

    try std.testing.expectEqual(Decision.sampled, sampler.check(std.testing.io, .info, "msg", &clock));
    try std.testing.expectEqual(Decision.sampled, sampler.check(std.testing.io, .info, "msg", &clock));
    try std.testing.expectEqual(Decision.dropped, sampler.check(std.testing.io, .info, "msg", &clock));
    try std.testing.expectEqual(Decision.dropped, sampler.check(std.testing.io, .info, "msg", &clock));

    std.debug.assert(sampler.check(std.testing.io, .info, "other message", &clock) == .sampled);
}

test "sampler keeps first N and then every thereafter-th event" {
    var clock = Clock.init_fixed(200);
    var sampler = Sampler.init(1_000_000_000, 2, 3);

    try std.testing.expectEqual(Decision.sampled, sampler.check(std.testing.io, .info, "msg", &clock)); // 1
    try std.testing.expectEqual(Decision.sampled, sampler.check(std.testing.io, .info, "msg", &clock)); // 2
    try std.testing.expectEqual(Decision.dropped, sampler.check(std.testing.io, .info, "msg", &clock)); // 3
    try std.testing.expectEqual(Decision.dropped, sampler.check(std.testing.io, .info, "msg", &clock)); // 4
    try std.testing.expectEqual(Decision.sampled, sampler.check(std.testing.io, .info, "msg", &clock)); // 5
    try std.testing.expectEqual(Decision.dropped, sampler.check(std.testing.io, .info, "msg", &clock)); // 6
    try std.testing.expectEqual(Decision.dropped, sampler.check(std.testing.io, .info, "msg", &clock)); // 7
    try std.testing.expectEqual(Decision.sampled, sampler.check(std.testing.io, .info, "msg", &clock)); // 8
}

test "sampler resets after tick window elapses" {
    var clock = Clock.init_fixed(300);
    var sampler = Sampler.init(1_000_000_000, 1, 0);

    try std.testing.expectEqual(Decision.sampled, sampler.check(std.testing.io, .info, "msg", &clock));
    try std.testing.expectEqual(Decision.dropped, sampler.check(std.testing.io, .info, "msg", &clock));

    clock.advance(1);

    try std.testing.expectEqual(Decision.sampled, sampler.check(std.testing.io, .info, "msg", &clock));
    try std.testing.expectEqual(Decision.dropped, sampler.check(std.testing.io, .info, "msg", &clock));

    std.debug.assert(sampler.check(std.testing.io, .warn, "msg", &clock) == .sampled);
}

test "sampler separates counters by level and message" {
    var clock = Clock.init_fixed(400);
    var sampler = Sampler.init(1_000_000_000, 1, 0);

    try std.testing.expectEqual(Decision.sampled, sampler.check(std.testing.io, .info, "msg-a", &clock));
    try std.testing.expectEqual(Decision.sampled, sampler.check(std.testing.io, .info, "msg-b", &clock));
    try std.testing.expectEqual(Decision.sampled, sampler.check(std.testing.io, .warn, "msg-a", &clock));

    try std.testing.expectEqual(Decision.dropped, sampler.check(std.testing.io, .info, "msg-a", &clock));
    try std.testing.expectEqual(Decision.dropped, sampler.check(std.testing.io, .info, "msg-b", &clock));
    try std.testing.expectEqual(Decision.dropped, sampler.check(std.testing.io, .warn, "msg-a", &clock));
}

test "sampler hook counts sampled and dropped decisions" {
    var clock = Clock.init_fixed(500);
    var sampler = Sampler.init(1_000_000_000, 1, 0);
    var counter = SamplingCounter.init();

    sampler.with_hook(.{ .counter = &counter });

    _ = sampler.check(std.testing.io, .info, "msg", &clock);
    _ = sampler.check(std.testing.io, .info, "msg", &clock);
    _ = sampler.check(std.testing.io, .info, "msg", &clock);

    try std.testing.expectEqual(@as(u64, 1), counter.sampled_count());
    try std.testing.expectEqual(@as(u64, 2), counter.dropped_count());

    std.debug.assert(counter.sampled_count() == 1);
    std.debug.assert(counter.dropped_count() == 2);
}

test "sampler with nop hook still makes decisions" {
    var clock = Clock.init_fixed(600);
    var sampler = Sampler.init(1_000_000_000, 1, 1);

    sampler.with_hook(.{ .nop = {} });

    try std.testing.expectEqual(Decision.sampled, sampler.check(std.testing.io, .info, "msg", &clock));
    try std.testing.expectEqual(Decision.sampled, sampler.check(std.testing.io, .info, "msg", &clock));
    try std.testing.expectEqual(Decision.sampled, sampler.check(std.testing.io, .info, "msg", &clock));

    std.debug.assert(sampler.check(std.testing.io, .info, "other", &clock) == .sampled);
}
