const std = @import("std");
const clock_mod = @import("clock.zig");
const level_mod = @import("level.zig");

const Clock = clock_mod.Clock;
const Level = level_mod.Level;

pub const levels_count: u32 = 7;
pub const counters_per_level: u32 = 512;
pub const tick_ns_default: i64 = 1_000_000_000;

pub const Decision = enum(u8) {
    sampled,
    dropped,
};

pub const DecisionCallback = *const fn (
    at_level: Level,
    message: []const u8,
    decision: Decision,
) void;

const AtomicCounter = struct {
    reset_tick: std.atomic.Value(i64),
    count: std.atomic.Value(u64),

    fn increment_check_reset(self: *AtomicCounter, now_ns: i64, tick_ns: i64) u64 {
        std.debug.assert(tick_ns > 0);
        std.debug.assert(now_ns >= 0);

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

pub const Sampler = struct {
    counts: [levels_count][counters_per_level]AtomicCounter,
    tick_ns: i64,
    first: u64,
    thereafter: u64,
    hook: SamplingHook,

    pub fn init(tick_ns: i64, first: u64, thereafter: u64) Sampler {
        std.debug.assert(tick_ns > 0);
        std.debug.assert(first > 0);

        var sampler: Sampler = undefined;
        sampler.tick_ns = tick_ns;
        sampler.first = first;
        sampler.thereafter = thereafter;
        sampler.hook = .{ .nop = {} };

        for (&sampler.counts) |*row| {
            for (row) |*counter| {
                counter.reset_tick.store(0, .monotonic);
                counter.count.store(0, .monotonic);
            }
        }

        return sampler;
    }

    pub fn with_hook(self: *Sampler, hook: SamplingHook) void {
        self.hook = hook;
    }

    pub fn check(
        self: *Sampler,
        io: std.Io,
        at_level: Level,
        message: []const u8,
        clock: *const Clock,
    ) Decision {
        std.debug.assert(self.tick_ns > 0);
        std.debug.assert(self.first > 0);

        const row: usize = @intFromEnum(at_level);

        std.debug.assert(row < levels_count);

        const column = compute_index(message);

        std.debug.assert(column < counters_per_level);

        const counter = &self.counts[row][column];
        const now_ns: i64 = @intCast(@min(clock.now_nano(io), std.math.maxInt(i64)));

        const count = counter.increment_check_reset(now_ns, self.tick_ns);
        const decision = self.evaluate(count);

        self.hook.on_decision(at_level, message, decision);

        return decision;
    }

    fn evaluate(self: *const Sampler, count: u64) Decision {
        std.debug.assert(self.first > 0);
        std.debug.assert(count > 0);

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

fn compute_index(message: []const u8) usize {
    var hash: u64 = 14695981039346656037;

    for (message) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }

    const result = @as(usize, @intCast(hash % counters_per_level));

    std.debug.assert(result < counters_per_level);
    return result;
}

fn should_reset(last_reset_ns: i64, now_ns: i64, tick_ns: i64) bool {
    std.debug.assert(tick_ns > 0);

    if (last_reset_ns == 0) return true;

    const elapsed = now_ns - last_reset_ns;

    return elapsed >= tick_ns;
}
