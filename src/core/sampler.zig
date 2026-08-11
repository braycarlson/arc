const std = @import("std");
const clock_mod = @import("clock.zig");
const level_mod = @import("level.zig");

const assert = std.debug.assert;

const Clock = clock_mod.Clock;
const Level = level_mod.Level;

pub const DecisionCallback = *const fn (
    at_level: Level,
    message: []const u8,
    decision: Decision,
) void;

pub const Sampler = struct {
    counts: [levels_count][level_counters_max]AtomicCounter,
    tick_ns: i64,
    first: u64,
    thereafter: u64,
    hook: SamplingHook,

    pub fn init(sampler: *Sampler, config: SamplingConfig) void {
        assert(config.tick_ns > 0);
        assert(config.first > 0);

        sampler.tick_ns = config.tick_ns;
        sampler.first = config.first;
        sampler.thereafter = config.thereafter;
        sampler.hook = .{ .nop = {} };

        for (&sampler.counts) |*row| {
            for (row) |*counter| {
                counter.reset_tick.store(0, .monotonic);
                counter.count.store(0, .monotonic);
            }
        }

        assert(sampler.is_valid());
    }

    pub fn is_valid(self: *const Sampler) bool {
        if (self.tick_ns <= 0) return false;
        if (self.first == 0) return false;

        return true;
    }

    pub fn with_hook(self: *Sampler, hook: SamplingHook) void {
        assert(self.is_valid());

        self.hook = hook;
    }

    pub fn check(
        self: *Sampler,
        io: std.Io,
        at_level: Level,
        message: []const u8,
        clock: *const Clock,
    ) Decision {
        assert(self.is_valid());

        const row: u8 = @intFromEnum(at_level);

        assert(row < levels_count);

        const column = message_bucket(message);

        assert(column < level_counters_max);

        const counter = &self.counts[row][column];
        const now_ns: i64 = @intCast(@min(clock.now_nano(io), std.math.maxInt(i64)));

        const count = counter.increment_check_reset(now_ns, self.tick_ns);
        const decision = self.evaluate(count);

        self.hook.on_decision(at_level, message, decision);

        return decision;
    }

    fn evaluate(self: *const Sampler, count: u64) Decision {
        assert(self.first > 0);
        assert(count > 0);

        if (count <= self.first) {
            return .sampled;
        }

        if (self.thereafter == 0) {
            return .dropped;
        }

        if ((count - self.first) % self.thereafter == 0) {
            return .sampled;
        }

        return .dropped;
    }
};

pub const SamplingConfig = struct {
    enabled: bool = true,
    tick_ns: i64 = tick_ns_default,
    first: u64 = 1,
    thereafter: u64 = 0,
};

pub const Decision = enum(u8) {
    sampled,
    dropped,
};

const AtomicCounter = struct {
    reset_tick: std.atomic.Value(i64),
    count: std.atomic.Value(u64),

    fn increment_check_reset(self: *AtomicCounter, now_ns: i64, tick_ns: i64) u64 {
        assert(tick_ns > 0);
        assert(now_ns >= 0);

        const last_reset = self.reset_tick.load(.monotonic);

        if (!should_reset(last_reset, now_ns, tick_ns)) {
            return self.count.fetchAdd(1, .monotonic) + 1;
        }

        self.count.store(1, .monotonic);

        if (self.reset_tick.cmpxchgStrong(last_reset, now_ns, .monotonic, .monotonic) != null) {
            return self.count.fetchAdd(1, .monotonic) + 1;
        }

        return 1;
    }
};

pub const SamplingCounter = struct {
    sampled: std.atomic.Value(u64),
    dropped: std.atomic.Value(u64),

    pub fn init() SamplingCounter {
        return .{
            .sampled = std.atomic.Value(u64).init(0),
            .dropped = std.atomic.Value(u64).init(0),
        };
    }

    pub fn sampled_count(self: *const SamplingCounter) u64 {
        return self.sampled.load(.acquire);
    }

    pub fn dropped_count(self: *const SamplingCounter) u64 {
        return self.dropped.load(.acquire);
    }
};

pub const SamplingHook = union(enum) {
    nop: void,
    counter: *SamplingCounter,
    callback: DecisionCallback,

    pub fn on_decision(
        self: SamplingHook,
        at_level: Level,
        message: []const u8,
        decision: Decision,
    ) void {
        switch (self) {
            .nop => {},
            .counter => |sampling_counter| {
                switch (decision) {
                    .sampled => _ = sampling_counter.sampled.fetchAdd(1, .monotonic),
                    .dropped => _ = sampling_counter.dropped.fetchAdd(1, .monotonic),
                }
            },
            .callback => |function| function(at_level, message, decision),
        }
    }
};

pub const levels_count: u32 = level_mod.levels_count;
pub const level_counters_max: u32 = 512;
pub const message_hash_bytes_max: u32 = 256;
pub const tick_ns_default: i64 = 1_000_000_000;

const fnv_offset_basis: u64 = 14695981039346656037;
const fnv_prime: u64 = 1099511628211;

comptime {
    assert(@intFromEnum(Level.fatal) < levels_count);
    assert(level_counters_max > 0);
    assert(message_hash_bytes_max > 0);
    assert(tick_ns_default > 0);
}

fn message_bucket(message: []const u8) u16 {
    var hash: u64 = fnv_offset_basis;

    const hashed = message[0..@min(message.len, message_hash_bytes_max)];

    assert(hashed.len <= message_hash_bytes_max);

    for (hashed) |byte| {
        hash ^= byte;
        hash *%= fnv_prime;
    }

    const result: u16 = @intCast(hash % level_counters_max);

    assert(result < level_counters_max);

    return result;
}

fn should_reset(last_reset_ns: i64, now_ns: i64, tick_ns: i64) bool {
    assert(tick_ns > 0);

    if (last_reset_ns == 0) return true;

    const elapsed = now_ns - last_reset_ns;

    return elapsed >= tick_ns;
}

const testing = std.testing;

test "a sampler passes the first messages of a tick" {
    var sampler: Sampler = undefined;

    sampler.init(.{ .tick_ns = 1_000_000_000, .first = 3, .thereafter = 0 });
    var clock = Clock.init_fixed(1_000_000_000);

    try testing.expectEqual(.sampled, sampler.check(testing.io, .info, "msg", &clock));
    try testing.expectEqual(.sampled, sampler.check(testing.io, .info, "msg", &clock));
    try testing.expectEqual(.sampled, sampler.check(testing.io, .info, "msg", &clock));
    try testing.expectEqual(.dropped, sampler.check(testing.io, .info, "msg", &clock));

    assert(sampler.first == 3);
    assert(sampler.thereafter == 0);
}

test "a sampler passes every nth message once the initial allowance is spent" {
    var sampler: Sampler = undefined;

    sampler.init(.{ .tick_ns = 1_000_000_000, .first = 1, .thereafter = 2 });
    var clock = Clock.init_fixed(1_000_000_000);

    try testing.expectEqual(.sampled, sampler.check(testing.io, .info, "msg", &clock));
    try testing.expectEqual(.dropped, sampler.check(testing.io, .info, "msg", &clock));
    try testing.expectEqual(.sampled, sampler.check(testing.io, .info, "msg", &clock));
    try testing.expectEqual(.dropped, sampler.check(testing.io, .info, "msg", &clock));
    try testing.expectEqual(.sampled, sampler.check(testing.io, .info, "msg", &clock));

    assert(sampler.first == 1);
    assert(sampler.thereafter == 2);
}

test "a sampler forgets its counts once the tick interval elapses" {
    var sampler: Sampler = undefined;

    sampler.init(.{ .tick_ns = 1_000_000_000, .first = 1, .thereafter = 0 });
    var clock = Clock.init_fixed(1_000_000_000);

    try testing.expectEqual(.sampled, sampler.check(testing.io, .info, "msg", &clock));
    try testing.expectEqual(.dropped, sampler.check(testing.io, .info, "msg", &clock));

    clock.advance(2);

    try testing.expectEqual(.sampled, sampler.check(testing.io, .info, "msg", &clock));

    assert(sampler.tick_ns > 0);
    assert(sampler.first == 1);
}

test "a counter hook records both sampled and dropped decisions" {
    var counter = SamplingCounter.init();
    var sampler: Sampler = undefined;

    sampler.init(.{ .tick_ns = 1_000_000_000, .first = 1, .thereafter = 0 });
    var clock = Clock.init_fixed(1_000_000_000);

    sampler.with_hook(.{ .counter = &counter });

    _ = sampler.check(testing.io, .info, "msg", &clock);
    _ = sampler.check(testing.io, .info, "msg", &clock);
    _ = sampler.check(testing.io, .info, "msg", &clock);

    try testing.expectEqual(@as(u64, 1), counter.sampled_count());
    try testing.expectEqual(@as(u64, 2), counter.dropped_count());

    assert(counter.sampled_count() + counter.dropped_count() == 3);
    assert(counter.sampled_count() == 1);
}

test "two different messages count against separate buckets" {
    var sampler: Sampler = undefined;

    sampler.init(.{ .tick_ns = 1_000_000_000, .first = 1, .thereafter = 0 });
    var clock = Clock.init_fixed(1_000_000_000);

    try testing.expectEqual(.sampled, sampler.check(testing.io, .info, "msg_a", &clock));
    try testing.expectEqual(.sampled, sampler.check(testing.io, .info, "msg_b", &clock));

    assert(sampler.first == 1);
    assert(sampler.tick_ns > 0);
}

test "a sampler with no thereafter allowance drops everything past the first messages" {
    var clock = Clock.init_fixed(100);
    var sampler: Sampler = undefined;

    sampler.init(.{ .tick_ns = 1_000_000_000, .first = 2, .thereafter = 0 });

    try testing.expectEqual(Decision.sampled, sampler.check(testing.io, .info, "msg", &clock));
    try testing.expectEqual(Decision.sampled, sampler.check(testing.io, .info, "msg", &clock));
    try testing.expectEqual(Decision.dropped, sampler.check(testing.io, .info, "msg", &clock));
    try testing.expectEqual(Decision.dropped, sampler.check(testing.io, .info, "msg", &clock));

    assert(sampler.check(testing.io, .info, "other message", &clock) == .sampled);
}

test "a sampler keeps the first messages and then every thereafter-th one" {
    var clock = Clock.init_fixed(200);
    var sampler: Sampler = undefined;

    sampler.init(.{ .tick_ns = 1_000_000_000, .first = 2, .thereafter = 3 });

    try testing.expectEqual(Decision.sampled, sampler.check(testing.io, .info, "msg", &clock)); // 1
    try testing.expectEqual(Decision.sampled, sampler.check(testing.io, .info, "msg", &clock)); // 2
    try testing.expectEqual(Decision.dropped, sampler.check(testing.io, .info, "msg", &clock)); // 3
    try testing.expectEqual(Decision.dropped, sampler.check(testing.io, .info, "msg", &clock)); // 4
    try testing.expectEqual(Decision.sampled, sampler.check(testing.io, .info, "msg", &clock)); // 5
    try testing.expectEqual(Decision.dropped, sampler.check(testing.io, .info, "msg", &clock)); // 6
    try testing.expectEqual(Decision.dropped, sampler.check(testing.io, .info, "msg", &clock)); // 7
    try testing.expectEqual(Decision.sampled, sampler.check(testing.io, .info, "msg", &clock)); // 8
}

test "a sampler starts counting again in the next tick window" {
    var clock = Clock.init_fixed(300);
    var sampler: Sampler = undefined;

    sampler.init(.{ .tick_ns = 1_000_000_000, .first = 1, .thereafter = 0 });

    try testing.expectEqual(Decision.sampled, sampler.check(testing.io, .info, "msg", &clock));
    try testing.expectEqual(Decision.dropped, sampler.check(testing.io, .info, "msg", &clock));

    clock.advance(1);

    try testing.expectEqual(Decision.sampled, sampler.check(testing.io, .info, "msg", &clock));
    try testing.expectEqual(Decision.dropped, sampler.check(testing.io, .info, "msg", &clock));

    assert(sampler.check(testing.io, .warn, "msg", &clock) == .sampled);
}

test "a sampler counts each level and message pair on its own" {
    var clock = Clock.init_fixed(400);
    var sampler: Sampler = undefined;

    sampler.init(.{ .tick_ns = 1_000_000_000, .first = 1, .thereafter = 0 });

    try testing.expectEqual(Decision.sampled, sampler.check(testing.io, .info, "msg-a", &clock));
    try testing.expectEqual(Decision.sampled, sampler.check(testing.io, .info, "msg-b", &clock));
    try testing.expectEqual(Decision.sampled, sampler.check(testing.io, .warn, "msg-a", &clock));

    try testing.expectEqual(Decision.dropped, sampler.check(testing.io, .info, "msg-a", &clock));
    try testing.expectEqual(Decision.dropped, sampler.check(testing.io, .info, "msg-b", &clock));
    try testing.expectEqual(Decision.dropped, sampler.check(testing.io, .warn, "msg-a", &clock));
}

test "a sampling hook sees every decision the sampler makes" {
    var clock = Clock.init_fixed(500);
    var sampler: Sampler = undefined;

    sampler.init(.{ .tick_ns = 1_000_000_000, .first = 1, .thereafter = 0 });
    var counter = SamplingCounter.init();

    sampler.with_hook(.{ .counter = &counter });

    _ = sampler.check(testing.io, .info, "msg", &clock);
    _ = sampler.check(testing.io, .info, "msg", &clock);
    _ = sampler.check(testing.io, .info, "msg", &clock);

    try testing.expectEqual(@as(u64, 1), counter.sampled_count());
    try testing.expectEqual(@as(u64, 2), counter.dropped_count());

    assert(counter.sampled_count() == 1);
    assert(counter.dropped_count() == 2);
}

test "a sampler with a nop hook still decides" {
    var clock = Clock.init_fixed(600);
    var sampler: Sampler = undefined;

    sampler.init(.{ .tick_ns = 1_000_000_000, .first = 1, .thereafter = 1 });

    sampler.with_hook(.{ .nop = {} });

    try testing.expectEqual(Decision.sampled, sampler.check(testing.io, .info, "msg", &clock));
    try testing.expectEqual(Decision.sampled, sampler.check(testing.io, .info, "msg", &clock));
    try testing.expectEqual(Decision.sampled, sampler.check(testing.io, .info, "msg", &clock));

    assert(sampler.check(testing.io, .info, "other", &clock) == .sampled);
}

test "two messages sharing a long prefix land in the same bucket" {
    var long_a: [message_hash_bytes_max + 32]u8 = @splat('a');
    var long_b: [message_hash_bytes_max + 32]u8 = @splat('a');

    long_b[message_hash_bytes_max] = 'b';

    try testing.expectEqual(message_bucket(&long_a), message_bucket(&long_b));

    var differing: [message_hash_bytes_max]u8 = @splat('a');

    differing[0] = 'b';

    const prefix = long_a[0..message_hash_bytes_max];

    try testing.expect(message_bucket(&differing) != message_bucket(prefix));

    assert(message_bucket(&long_a) < level_counters_max);
}
