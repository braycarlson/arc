const std = @import("std");
const arc = @import("arc");

const Entry = arc.entry_mod.Entry;
const Hook = arc.Hook;
const HookSet = arc.HookSet;
const Level = arc.Level;

const levels_count = arc.hook_mod.levels_count;
const hooks_max = arc.hook_mod.hooks_max;

fn entry_at(at_level: Level) Entry {
    return Entry.init(std.testing.io, at_level, "msg", "test");
}

var callback_hits: u32 = 0;
var callback_last_level: Level = .debug;

fn record_hook(entry: *const Entry) void {
    callback_hits += 1;
    callback_last_level = entry.level;
}

test "hookset init is empty" {
    const set = HookSet.init();

    try std.testing.expect(set.is_empty());

    std.debug.assert(set.hooks_count == 0);
    std.debug.assert(set.is_empty());
}

test "hookset add and run counter hook" {
    var set = HookSet.init();
    var counter = std.atomic.Value(u64).init(0);

    set.add(.{ .counter = &counter });

    try std.testing.expect(!set.is_empty());

    const info_entry = entry_at(.info);
    const warn_entry = entry_at(.warn);
    set.run(&info_entry);
    set.run(&warn_entry);

    try std.testing.expectEqual(@as(u64, 2), counter.load(.acquire));

    std.debug.assert(!set.is_empty());
    std.debug.assert(counter.load(.acquire) == 2);
}

test "hookset level_counter tracks per level" {
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

    try std.testing.expectEqual(@as(u64, 2), counters[@intFromEnum(Level.info)].load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), counters[@intFromEnum(Level.err)].load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), counters[@intFromEnum(Level.debug)].load(.acquire));

    std.debug.assert(counters[@intFromEnum(Level.info)].load(.acquire) == 2);
    std.debug.assert(counters[@intFromEnum(Level.debug)].load(.acquire) == 0);
}

test "hookset multiple hooks all fire" {
    var set = HookSet.init();
    var counter_a = std.atomic.Value(u64).init(0);
    var counter_b = std.atomic.Value(u64).init(0);

    set.add(.{ .counter = &counter_a });
    set.add(.{ .counter = &counter_b });

    const info_entry = entry_at(.info);
    set.run(&info_entry);

    try std.testing.expectEqual(@as(u64, 1), counter_a.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), counter_b.load(.acquire));

    std.debug.assert(counter_a.load(.acquire) == 1);
    std.debug.assert(counter_b.load(.acquire) == 1);
}

test "hookset callback receives entry" {
    callback_hits = 0;
    callback_last_level = .debug;

    var set = HookSet.init();
    set.add(.{ .callback = record_hook });

    const warn_entry = entry_at(.warn);
    set.run(&warn_entry);

    try std.testing.expectEqual(@as(u32, 1), callback_hits);
    try std.testing.expectEqual(Level.warn, callback_last_level);

    std.debug.assert(callback_hits == 1);
    std.debug.assert(callback_last_level == .warn);
}

test "nop hook does nothing" {
    const hook = Hook{ .nop = {} };

    const info_entry = entry_at(.info);
    const err_entry = entry_at(.err);
    hook.on_write(&info_entry);
    hook.on_write(&err_entry);

    std.debug.assert(hook == .nop);
    std.debug.assert(@as(std.meta.Tag(Hook), hook) == .nop);
}
