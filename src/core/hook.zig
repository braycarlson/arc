const std = @import("std");
const entry_mod = @import("entry.zig");
const level_mod = @import("level.zig");

const assert = std.debug.assert;

const Entry = entry_mod.Entry;
const Level = level_mod.Level;

pub const Callback = *const fn (entry: *const Entry) void;

pub const Hook = union(enum) {
    nop: void,
    counter: *std.atomic.Value(u64),
    level_counter: *[levels_count]std.atomic.Value(u64),
    callback: Callback,

    pub fn on_write(self: Hook, entry: *const Entry) void {
        switch (self) {
            .nop => {},
            .counter => |atomic_counter| {
                _ = atomic_counter.fetchAdd(1, .monotonic);
            },
            .level_counter => |counters| {
                const index: u8 = @intFromEnum(entry.level);

                assert(index < levels_count);
                _ = counters[index].fetchAdd(1, .monotonic);
            },
            .callback => |function| function(entry),
        }
    }
};

pub const HookSet = struct {
    hooks: [hooks_max]Hook,
    hooks_count: u32,

    pub fn init() HookSet {
        var set: HookSet = undefined;
        set.hooks_count = 0;

        return set;
    }

    pub fn add(self: *HookSet, hook: Hook) void {
        assert(self.is_valid());

        if (self.hooks_count >= hooks_max) {
            @panic("hook count exceeds hooks_max");
        }

        self.hooks[self.hooks_count] = hook;
        self.hooks_count += 1;

        assert(self.is_valid());
    }

    pub fn run(self: *const HookSet, entry: *const Entry) void {
        assert(self.is_valid());

        const active = self.hooks[0..self.hooks_count];

        for (active) |hook| {
            hook.on_write(entry);
        }
    }

    pub fn is_empty(self: *const HookSet) bool {
        return self.hooks_count == 0;
    }

    pub fn is_valid(self: *const HookSet) bool {
        return self.hooks_count <= hooks_max;
    }
};

pub const hooks_max: u32 = 4;
pub const levels_count: u32 = level_mod.levels_count;

comptime {
    assert(hooks_max > 0);
}

comptime {
    assert(@intFromEnum(Level.fatal) < levels_count);
}

const testing = std.testing;

fn entry_at(at_level: Level) Entry {
    return Entry.init(testing.io, at_level, "msg", "test");
}

var callback_hits: u32 = 0;
var callback_last_level: Level = .debug;

fn record_hook(entry: *const Entry) void {
    callback_hits += 1;
    callback_last_level = entry.level;
}

test "a new hook set holds no hooks" {
    const set = HookSet.init();

    try testing.expect(set.is_empty());

    assert(set.hooks_count == 0);
    assert(set.is_empty());
}

test "a counter hook counts every entry the set runs" {
    var set = HookSet.init();
    var counter = std.atomic.Value(u64).init(0);

    set.add(.{ .counter = &counter });

    try testing.expect(!set.is_empty());

    const info_entry = entry_at(.info);
    const warn_entry = entry_at(.warn);
    set.run(&info_entry);
    set.run(&warn_entry);

    try testing.expectEqual(@as(u64, 2), counter.load(.acquire));

    assert(!set.is_empty());
    assert(counter.load(.acquire) == 2);
}

test "a level counter hook counts entries into its own level slot" {
    var set = HookSet.init();
    var counters: [levels_count]std.atomic.Value(u64) = undefined;

    for (&counters) |*c| {
        c.* = std.atomic.Value(u64).init(0);
    }

    set.add(.{ .level_counter = &counters });

    const info_entry = entry_at(.info);
    const err_entry = entry_at(.err);
    set.run(&info_entry);
    set.run(&info_entry);
    set.run(&err_entry);

    try testing.expectEqual(@as(u64, 2), counters[@intFromEnum(Level.info)].load(.acquire));
    try testing.expectEqual(@as(u64, 1), counters[@intFromEnum(Level.err)].load(.acquire));
    try testing.expectEqual(@as(u64, 0), counters[@intFromEnum(Level.debug)].load(.acquire));

    assert(counters[@intFromEnum(Level.info)].load(.acquire) == 2);
    assert(counters[@intFromEnum(Level.debug)].load(.acquire) == 0);
}

test "every hook in a set runs for one entry" {
    var set = HookSet.init();
    var counter_a = std.atomic.Value(u64).init(0);
    var counter_b = std.atomic.Value(u64).init(0);

    set.add(.{ .counter = &counter_a });
    set.add(.{ .counter = &counter_b });

    const info_entry = entry_at(.info);
    set.run(&info_entry);

    try testing.expectEqual(@as(u64, 1), counter_a.load(.acquire));
    try testing.expectEqual(@as(u64, 1), counter_b.load(.acquire));

    assert(counter_a.load(.acquire) == 1);
    assert(counter_b.load(.acquire) == 1);
}

test "a callback hook receives the entry that triggered it" {
    callback_hits = 0;
    callback_last_level = .debug;

    var set = HookSet.init();
    set.add(.{ .callback = record_hook });

    const warn_entry = entry_at(.warn);
    set.run(&warn_entry);

    try testing.expectEqual(@as(u32, 1), callback_hits);
    try testing.expectEqual(Level.warn, callback_last_level);

    assert(callback_hits == 1);
    assert(callback_last_level == .warn);
}

test "a nop hook leaves the entry untouched" {
    const hook = Hook{ .nop = {} };

    const info_entry = entry_at(.info);
    const err_entry = entry_at(.err);
    hook.on_write(&info_entry);
    hook.on_write(&err_entry);

    assert(hook == .nop);
    assert(@as(std.meta.Tag(Hook), hook) == .nop);
}
