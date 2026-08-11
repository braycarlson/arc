const std = @import("std");
const core_mod = @import("core.zig");
const entry_mod = @import("entry.zig");
const field_mod = @import("field.zig");
const hook_mod = @import("hook.zig");
const level_mod = @import("level.zig");
const writer_mod = @import("../io/writer.zig");
const buffer_mod = @import("../io/buffer.zig");
const encoder_mod = @import("../encoding/encoder.zig");
const encoder_config_mod = @import("../encoding/config.zig");

const assert = std.debug.assert;

const Core = core_mod.Core;
const Entry = entry_mod.Entry;
const Field = field_mod.Field;
const HookSet = hook_mod.HookSet;
const Level = level_mod.Level;
const Writer = writer_mod.Writer;

pub const CheckedEntry = struct {
    entry: Entry,
    core: *Core,
    io: std.Io,
    error_output: Writer,
    context_fields: []const Field,
    hooks: *const HookSet,
    armed: bool,
    after_hooks: [after_hooks_max]AfterHook,
    after_hooks_count: u32,
    terminal_action: TerminalAction,

    pub const Options = struct {
        io: std.Io,
        entry: *const Entry,
        core: *Core,
        context_fields: []const Field,
        error_output: Writer,
        hooks: *const HookSet,
    };

    pub fn init(checked_entry: *CheckedEntry, options: Options) void {
        assert(options.context_fields.len <= field_mod.fields_max);

        options.entry.copy_into(&checked_entry.entry);

        checked_entry.core = options.core;
        checked_entry.io = options.io;
        checked_entry.error_output = options.error_output;
        checked_entry.context_fields = options.context_fields;
        checked_entry.hooks = options.hooks;
        checked_entry.armed = true;
        checked_entry.after_hooks_count = 0;
        checked_entry.terminal_action = .write_then_nop;

        assert(checked_entry.is_valid());
        assert(checked_entry.is_armed());
    }

    pub fn with_terminal_action(self: *CheckedEntry, action: TerminalAction) *CheckedEntry {
        assert(self.armed);
        assert(self.is_valid());

        self.terminal_action = action;
        return self;
    }

    pub fn after(self: *CheckedEntry, hook: AfterHook) *CheckedEntry {
        assert(self.armed);

        if (self.after_hooks_count >= after_hooks_max) {
            @panic("after-hook count exceeds after_hooks_max");
        }

        self.after_hooks[self.after_hooks_count] = hook;
        self.after_hooks_count += 1;

        assert(self.is_valid());

        return self;
    }

    pub fn write(self: *CheckedEntry, fields: []const Field) void {
        assert(self.armed);
        assert(self.is_valid());
        assert(fields.len <= field_mod.fields_max);

        self.core.write(self.io, &self.entry, .{
            .context = self.context_fields,
            .message = fields,
        }) catch {
            self.write_internal_error("failed to write log entry");
        };

        if (!self.hooks.is_empty()) {
            self.hooks.run(&self.entry);
        }

        self.run_after_hooks();
        self.armed = false;

        self.execute_terminal_action();
    }

    fn run_after_hooks(self: *const CheckedEntry) void {
        assert(self.armed);
        assert(self.is_valid());

        const active = self.after_hooks[0..self.after_hooks_count];

        for (active) |hook| {
            switch (hook) {
                .nop => {},
                .sync => self.core.sync(self.io) catch {
                    self.write_internal_error("failed to sync after log entry");
                },
                .terminal => {},
            }
        }
    }

    fn execute_terminal_action(self: *const CheckedEntry) void {
        assert(!self.armed);

        switch (self.terminal_action) {
            .nop, .write_then_nop => {},
            .write_then_panic => {
                self.core.sync(self.io) catch {
                    self.write_internal_error("failed to sync before panic");
                };

                @panic("fatal log entry");
            },
            .write_then_fatal => {
                self.core.sync(self.io) catch {
                    self.write_internal_error("failed to sync before exit");
                };

                std.process.exit(1);
            },
        }
    }

    fn write_internal_error(self: *const CheckedEntry, message: []const u8) void {
        assert(message.len > 0);

        const prefix = "arc internal error: ";
        self.error_output.write(self.io, prefix) catch return;
        self.error_output.write(self.io, message) catch return;
        self.error_output.write(self.io, "\n") catch return;
    }

    pub fn is_valid(self: *const CheckedEntry) bool {
        if (self.after_hooks_count > after_hooks_max) return false;
        if (self.context_fields.len > field_mod.fields_max) return false;

        return true;
    }

    pub fn is_armed(self: *const CheckedEntry) bool {
        return self.armed;
    }
};

pub const TerminalAction = enum(u8) {
    nop,
    write_then_nop,
    write_then_panic,
    write_then_fatal,
};

pub const AfterHook = union(enum) {
    nop: void,
    sync: void,
    terminal: TerminalAction,
};

pub const after_hooks_max: u32 = 4;

comptime {
    assert(after_hooks_max > 0);
}

const testing = std.testing;

const temporary = @import("../testing/temporary.zig");

const Buffer = buffer_mod.Buffer;
const IoCore = core_mod.IoCore;
const Encoding = encoder_mod.Encoding;
const EncoderConfig = encoder_config_mod.EncoderConfig;

fn buffer_core(output: *Buffer, at_level: Level) Core {
    return .{
        .io = IoCore.init(
            at_level,
            Encoding.json,
            EncoderConfig.production(),
            .{ .buffer = output },
            false,
        ),
    };
}

fn checked_for(
    core: *Core,
    at_level: Level,
    message: []const u8,
    hooks: *const HookSet,
    checked_entry: *CheckedEntry,
) void {
    const entry = Entry.init(testing.io, at_level, message, "checked");

    checked_entry.init(.{
        .io = testing.io,
        .entry = &entry,
        .core = core,
        .context_fields = &.{},
        .error_output = .{ .nop = {} },
        .hooks = hooks,
    });
}

test "a new checked entry is armed and defaults to writing without a terminal action" {
    var output = Buffer.init();
    var core = buffer_core(&output, .debug);
    const hooks = HookSet.init();

    var checked: CheckedEntry = undefined;

    checked_for(&core, .info, "ready", &hooks, &checked);

    try testing.expect(checked.is_armed());
    try testing.expectEqual(TerminalAction.write_then_nop, checked.terminal_action);
    try testing.expectEqual(@as(u32, 0), checked.after_hooks_count);

    assert(checked.armed);
}

test "writing a checked entry emits the entry and disarms it" {
    var output = Buffer.init();
    var core = buffer_core(&output, .debug);
    const hooks = HookSet.init();

    var checked: CheckedEntry = undefined;

    checked_for(&core, .info, "written once", &hooks, &checked);

    checked.write(&.{field_mod.string("phase", "start")});

    try testing.expect(output.contains("written once"));
    try testing.expect(output.contains("\"phase\":\"start\""));
    try testing.expect(!checked.is_armed());

    assert(!checked.armed);
}

test "a checked entry carries its context fields ahead of the call fields" {
    var output = Buffer.init();
    var core = buffer_core(&output, .debug);
    const hooks = HookSet.init();
    const context = [_]Field{field_mod.string("service", "api")};

    const entry = Entry.init(testing.io, .info, "ordered", "checked");

    var checked: CheckedEntry = undefined;

    checked.init(.{
        .io = testing.io,
        .entry = &entry,
        .core = &core,
        .context_fields = &context,
        .error_output = .{ .nop = {} },
        .hooks = &hooks,
    });

    checked.write(&.{field_mod.int64("status", 200)});

    const service_at = std.mem.indexOf(u8, output.contents(), "\"service\"") orelse unreachable;
    const status_at = std.mem.indexOf(u8, output.contents(), "\"status\"") orelse unreachable;

    try testing.expect(service_at < status_at);

    assert(output.contains("\"status\":200"));
}

test "a checked entry runs the hook set once for the entry it writes" {
    var output = Buffer.init();
    var core = buffer_core(&output, .debug);

    var counter = std.atomic.Value(u64).init(0);
    var hooks = HookSet.init();

    hooks.add(.{ .counter = &counter });

    var checked: CheckedEntry = undefined;

    checked_for(&core, .warn, "hooked", &hooks, &checked);

    checked.write(&.{});

    try testing.expectEqual(@as(u64, 1), counter.load(.acquire));

    assert(counter.load(.acquire) == 1);
}

test "a sync after-hook flushes the core once the entry is written" {
    var output = Buffer.init();
    var core = buffer_core(&output, .debug);
    const hooks = HookSet.init();

    var checked: CheckedEntry = undefined;

    checked_for(&core, .info, "synced", &hooks, &checked);

    _ = checked.after(.{ .sync = {} });

    try testing.expectEqual(@as(u32, 1), checked.after_hooks_count);

    checked.write(&.{});

    try testing.expect(output.contains("synced"));

    assert(checked.after_hooks_count == 1);
}

test "after-hooks accumulate up to their maximum" {
    var output = Buffer.init();
    var core = buffer_core(&output, .debug);
    const hooks = HookSet.init();

    var checked: CheckedEntry = undefined;

    checked_for(&core, .info, "many hooks", &hooks, &checked);

    var index: u32 = 0;

    while (index < after_hooks_max) : (index += 1) {
        _ = checked.after(.{ .nop = {} });
    }

    try testing.expectEqual(after_hooks_max, checked.after_hooks_count);

    checked.write(&.{});

    try testing.expect(output.contains("many hooks"));

    assert(checked.after_hooks_count == after_hooks_max);
}

test "setting a terminal action replaces the default and returns the same entry" {
    var output = Buffer.init();
    var core = buffer_core(&output, .debug);
    const hooks = HookSet.init();

    var checked: CheckedEntry = undefined;

    checked_for(&core, .info, "terminal", &hooks, &checked);

    const returned = checked.with_terminal_action(.nop);

    try testing.expect(returned == &checked);
    try testing.expectEqual(TerminalAction.nop, checked.terminal_action);

    checked.write(&.{});

    try testing.expect(output.contains("terminal"));

    assert(checked.terminal_action == .nop);
}

test "a failing write reports an internal error to the error output" {
    const io = testing.io;
    const path = ".zz_checked_error.tmp";

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    const stale_file_descriptor = file.handle;
    file.close(io);
    defer temporary.remove_file(io, path);

    var errors = Buffer.init();
    const hooks = HookSet.init();

    var core = Core{
        .io = IoCore.init(
            .debug,
            Encoding.json,
            EncoderConfig.production(),
            .{ .file_descriptor = stale_file_descriptor },
            false,
        ),
    };

    const entry = Entry.init(io, .info, "doomed", "checked");

    var checked: CheckedEntry = undefined;

    checked.init(.{
        .io = io,
        .entry = &entry,
        .core = &core,
        .context_fields = &.{},
        .error_output = .{ .buffer = &errors },
        .hooks = &hooks,
    });

    checked.write(&.{});

    try testing.expect(errors.contains("arc internal error"));
    try testing.expect(errors.contains("failed to write log entry"));
    try testing.expect(!checked.is_armed());

    assert(!checked.armed);
}
