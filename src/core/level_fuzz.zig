const std = @import("std");
const level_mod = @import("level.zig");
const fuzz = @import("../testing/fuzz.zig");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const AtomicLevel = level_mod.AtomicLevel;
const Level = level_mod.Level;

const text_bytes_max: u32 = 16;

comptime {
    assert(text_bytes_max > 0);
    assert(level_mod.levels_count > 0);
}

pub fn main(gpa: Allocator, args: fuzz.FuzzArgs) !void {
    assert(args.events_max >= 1);

    _ = gpa;

    var prng = std.Random.DefaultPrng.init(args.seed);
    const random = prng.random();

    try verify_round_trip();

    var event: u32 = 0;

    while (event < args.events_max) : (event += 1) {
        try verify_garbage(random);
        try verify_atomic(random);
    }

    assert(event == args.events_max);
}

fn verify_round_trip() !void {
    inline for (@typeInfo(Level).@"enum".fields) |field| {
        const at_level: Level = @enumFromInt(field.value);
        const lower = at_level.to_string();
        const upper = at_level.to_string_upper();

        if (try level_mod.parse_level(lower) != at_level) {
            return error.LowerRoundTripDiverged;
        }

        if (try level_mod.parse_level(upper) != at_level) {
            return error.UpperRoundTripDiverged;
        }
    }
}

fn verify_garbage(random: std.Random) !void {
    var scratch: [text_bytes_max]u8 = undefined;

    const length = 1 + random.uintLessThan(usize, text_bytes_max);
    const text = fuzz.random_bytes(random, scratch[0..length]);

    if (text.len == 0) {
        return;
    }

    const parsed = level_mod.parse_level(text) catch |parse_error| switch (parse_error) {
        error.InvalidLevel => return,
    };

    const rendered = parsed.to_string();

    if (try level_mod.parse_level(rendered) != parsed) {
        return error.ParsedLevelDoesNotRoundTrip;
    }
}

fn verify_atomic(random: std.Random) !void {
    const at_level = fuzz.random_enum_uniform(random, Level);

    var atomic = AtomicLevel.init(at_level);

    if (atomic.level() != at_level) {
        return error.AtomicLevelDiverged;
    }

    const next = fuzz.random_enum_uniform(random, Level);

    atomic.set_level(next);

    if (atomic.level() != next) {
        return error.AtomicSetDiverged;
    }

    if (atomic.enabled(next) != next.enabled(next)) {
        return error.AtomicEnabledDiverged;
    }
}

const testing = std.testing;

test "fuzz: level parsing round-trips and survives garbage" {
    try main(testing.allocator, .{ .seed = 11, .events_max = fuzz.events_max_smoke });
}
