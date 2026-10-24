const std = @import("std");

const level_module = @import("level.zig");

const assert = std.debug.assert;

const Level = level_module.Level;

pub const Sampler = struct {
    counters: [Level.count][bucket_count]Counter,
    dropped_count: std.atomic.Value(u64),
    first: u32,
    thereafter: u32,
    tick_ns: u64,

    pub const Options = struct {
        first: u32,
        thereafter: u32,
        tick_ns: u64,
    };

    pub fn init(sampler: *Sampler, options: *const Options) void {
        assert(options.first > 0);
        assert(options.tick_ns > 0);
        assert(options.tick_ns <= std.math.maxInt(i64));

        sampler.counters = @splat(@splat(.{ .count = .init(0), .reset_ns = .init(0) }));
        sampler.dropped_count = .init(0);
        sampler.first = options.first;
        sampler.thereafter = options.thereafter;
        sampler.tick_ns = options.tick_ns;
    }

    pub fn sample(sampler: *Sampler, level: Level, message: []const u8, time_ns: i64) bool {
        assert(@backingInt(level) < @backingInt(Level.development_panic));
        assert(message.len <= level_module.text_bytes_max);
        assert(time_ns >= 0);

        const counter = &sampler.counters[@backingInt(level)][bucket_of(message)];
        const count = counter.increment(time_ns, sampler.tick_ns);
        const kept = sampler.keeps(count);

        if (!kept) _ = sampler.dropped_count.fetchAdd(1, .monotonic);

        return kept;
    }

    fn keeps(sampler: *const Sampler, count: u64) bool {
        assert(count > 0);
        assert(sampler.first > 0);

        if (count <= sampler.first) return true;
        if (sampler.thereafter == 0) return false;
        return @rem(count - sampler.first, sampler.thereafter) == 0;
    }
};

const Counter = struct {
    count: std.atomic.Value(u64),
    reset_ns: std.atomic.Value(i64),

    fn increment(counter: *Counter, time_ns: i64, tick_ns: u64) u64 {
        assert(time_ns >= 0);
        assert(tick_ns > 0);

        const reset_ns = counter.reset_ns.load(.monotonic);

        if (reset_due(reset_ns, &.{ .tick_ns = tick_ns, .time_ns = time_ns })) {
            counter.count.store(1, .monotonic);

            if (counter.reset_ns.cmpxchgStrong(reset_ns, time_ns, .monotonic, .monotonic) == null) {
                return 1;
            }
        }

        const count = counter.count.fetchAdd(1, .monotonic) + 1;

        assert(count > 0);

        return count;
    }
};

const Instant = struct {
    tick_ns: u64,
    time_ns: i64,
};

pub const bucket_count: u32 = 512;
pub const message_hashed_bytes_max: u32 = 256;
const fnv_offset_basis: u64 = 14_695_981_039_346_656_037;
const fnv_prime: u64 = 1_099_511_628_211;

comptime {
    assert(bucket_count > 0);
    assert(message_hashed_bytes_max > 0);
    assert(@sizeOf(Counter) == 16);
}

fn bucket_of(message: []const u8) u32 {
    assert(message.len <= level_module.text_bytes_max);

    const hashed = message[0..@min(message.len, message_hashed_bytes_max)];

    var hash: u64 = fnv_offset_basis;

    for (hashed) |byte| {
        hash ^= byte;
        hash *%= fnv_prime;
    }

    const result: u32 = @intCast(@rem(hash, bucket_count));

    assert(result < bucket_count);

    return result;
}

fn reset_due(reset_ns: i64, instant: *const Instant) bool {
    assert(reset_ns >= 0);
    assert(instant.time_ns >= 0);

    if (reset_ns == 0) return true;
    return instant.time_ns - reset_ns >= @as(i64, @intCast(instant.tick_ns));
}

const testing = std.testing;

const test_second_ns: i64 = std.time.ns_per_s;

fn test_sample(sampler: *Sampler, message: []const u8, time_ns: i64) bool {
    assert(message.len > 0);
    assert(time_ns >= 0);

    return sampler.sample(.information, message, time_ns);
}

test Sampler {
    const sampler = try testing.allocator.create(Sampler);
    defer testing.allocator.destroy(sampler);

    sampler.init(&.{ .first = 2, .thereafter = 0, .tick_ns = std.time.ns_per_s });

    try testing.expect(test_sample(sampler, "msg", test_second_ns));
    try testing.expect(test_sample(sampler, "msg", test_second_ns));
    try testing.expect(!test_sample(sampler, "msg", test_second_ns));
    try testing.expectEqual(@as(u64, 1), sampler.dropped_count.load(.monotonic));
}

test "a sampler keeps the first messages and then every thereafter-th one" {
    const sampler = try testing.allocator.create(Sampler);
    defer testing.allocator.destroy(sampler);

    sampler.init(&.{ .first = 2, .thereafter = 3, .tick_ns = std.time.ns_per_s });

    try testing.expect(test_sample(sampler, "msg", test_second_ns));
    try testing.expect(test_sample(sampler, "msg", test_second_ns));
    try testing.expect(!test_sample(sampler, "msg", test_second_ns));
    try testing.expect(!test_sample(sampler, "msg", test_second_ns));
    try testing.expect(test_sample(sampler, "msg", test_second_ns));
    try testing.expect(!test_sample(sampler, "msg", test_second_ns));
    try testing.expect(!test_sample(sampler, "msg", test_second_ns));
    try testing.expect(test_sample(sampler, "msg", test_second_ns));
    try testing.expectEqual(@as(u64, 4), sampler.dropped_count.load(.monotonic));
}

test "a sampler without a thereafter allowance drops everything past the first" {
    const sampler = try testing.allocator.create(Sampler);
    defer testing.allocator.destroy(sampler);

    sampler.init(&.{ .first = 2, .thereafter = 0, .tick_ns = std.time.ns_per_s });

    try testing.expect(test_sample(sampler, "msg", test_second_ns));
    try testing.expect(test_sample(sampler, "msg", test_second_ns));
    try testing.expect(!test_sample(sampler, "msg", test_second_ns));
    try testing.expect(!test_sample(sampler, "msg", test_second_ns));
    try testing.expect(test_sample(sampler, "other message", test_second_ns));
}

test "a sampler forgets its counts once the tick interval elapses" {
    const sampler = try testing.allocator.create(Sampler);
    defer testing.allocator.destroy(sampler);

    sampler.init(&.{ .first = 1, .thereafter = 0, .tick_ns = std.time.ns_per_s });

    try testing.expect(test_sample(sampler, "msg", test_second_ns));
    try testing.expect(!test_sample(sampler, "msg", test_second_ns));
    try testing.expect(!test_sample(sampler, "msg", 2 * test_second_ns - 1));
    try testing.expect(test_sample(sampler, "msg", 2 * test_second_ns));
    try testing.expect(!test_sample(sampler, "msg", 2 * test_second_ns));
}

test "each level and message pair counts on its own" {
    const sampler = try testing.allocator.create(Sampler);
    defer testing.allocator.destroy(sampler);

    sampler.init(&.{ .first = 1, .thereafter = 0, .tick_ns = std.time.ns_per_s });

    try testing.expect(sampler.sample(.information, "msg-a", test_second_ns));
    try testing.expect(sampler.sample(.information, "msg-b", test_second_ns));
    try testing.expect(sampler.sample(.warn, "msg-a", test_second_ns));
    try testing.expect(!sampler.sample(.information, "msg-a", test_second_ns));
    try testing.expect(!sampler.sample(.information, "msg-b", test_second_ns));
    try testing.expect(!sampler.sample(.warn, "msg-a", test_second_ns));
}

test "two messages that share their hashed prefix land in the same bucket" {
    var long_a: [message_hashed_bytes_max + 32]u8 = @splat('a');
    var long_b: [message_hashed_bytes_max + 32]u8 = @splat('a');
    var differing: [message_hashed_bytes_max]u8 = @splat('a');

    long_b[message_hashed_bytes_max] = 'b';
    differing[0] = 'b';

    try testing.expectEqual(bucket_of(&long_a), bucket_of(&long_b));
    try testing.expect(bucket_of(&differing) != bucket_of(long_a[0..message_hashed_bytes_max]));
}

test "the decision sequence matches a counting model for every allowance" {
    const sampler = try testing.allocator.create(Sampler);
    defer testing.allocator.destroy(sampler);

    for (1..5) |first| {
        for (0..5) |thereafter| {
            sampler.init(&.{
                .first = @intCast(first),
                .thereafter = @intCast(thereafter),
                .tick_ns = std.time.ns_per_s,
            });

            for (1..40) |count| {
                const kept_model = blk: {
                    if (count <= first) break :blk true;
                    if (thereafter == 0) break :blk false;

                    break :blk @rem(count - first, thereafter) == 0;
                };

                try testing.expectEqual(kept_model, test_sample(sampler, "m", test_second_ns));
            }
        }
    }
}
