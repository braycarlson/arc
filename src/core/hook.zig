const std = @import("std");
const entry_mod = @import("entry.zig");
const level_mod = @import("level.zig");

const Entry = entry_mod.Entry;
const Level = level_mod.Level;

pub const hooks_max: u32 = 4;
pub const levels_count: u32 = 7;

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
                const index: usize = @intFromEnum(entry.level);

                std.debug.assert(index < levels_count);
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
        if (self.hooks_count >= hooks_max) {
            @panic("hook count exceeds hooks_max");
        }

        self.hooks[self.hooks_count] = hook;
        self.hooks_count += 1;

        std.debug.assert(self.hooks_count <= hooks_max);
    }

    pub fn run(self: *const HookSet, entry: *const Entry) void {
        std.debug.assert(self.hooks_count <= hooks_max);

        const active = self.hooks[0..self.hooks_count];

        for (active) |hook| {
            hook.on_write(entry);
        }
    }

    pub fn is_empty(self: *const HookSet) bool {
        return self.hooks_count == 0;
    }
};
