const std = @import("std");
const core_mod = @import("core.zig");
const entry_mod = @import("entry.zig");
const field_mod = @import("field.zig");
const hook_mod = @import("hook.zig");
const level_mod = @import("level.zig");
const writer_mod = @import("../io/writer.zig");

const Core = core_mod.Core;
const Entry = entry_mod.Entry;
const Field = field_mod.Field;
const HookSet = hook_mod.HookSet;
const Level = level_mod.Level;
const Writer = writer_mod.Writer;
const WriteError = writer_mod.WriteError;

pub const TerminalAction = enum(u8) {
    nop,
    write_then_nop,
    write_then_panic,
    write_then_fatal,
};

pub const after_hooks_max: u32 = 4;

pub const AfterHook = union(enum) {
    nop: void,
    sync: void,
    terminal: TerminalAction,
};

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

    pub fn init(
        io: std.Io,
        entry: *const Entry,
        core: *Core,
        context_fields: []const Field,
        error_output: Writer,
        hooks: *const HookSet,
    ) CheckedEntry {
        std.debug.assert(context_fields.len <= field_mod.fields_max);

        var checked_entry: CheckedEntry = undefined;
        checked_entry.entry = entry.*;
        checked_entry.core = core;
        checked_entry.io = io;
        checked_entry.error_output = error_output;
        checked_entry.context_fields = context_fields;
        checked_entry.hooks = hooks;
        checked_entry.armed = true;
        checked_entry.after_hooks_count = 0;
        checked_entry.terminal_action = .write_then_nop;

        return checked_entry;
    }

    pub fn with_terminal_action(self: *CheckedEntry, action: TerminalAction) *CheckedEntry {
        std.debug.assert(self.armed);

        self.terminal_action = action;
        return self;
    }

    pub fn after(self: *CheckedEntry, hook: AfterHook) *CheckedEntry {
        std.debug.assert(self.armed);

        if (self.after_hooks_count >= after_hooks_max) {
            @panic("after-hook count exceeds after_hooks_max");
        }

        self.after_hooks[self.after_hooks_count] = hook;
        self.after_hooks_count += 1;

        std.debug.assert(self.after_hooks_count <= after_hooks_max);
        return self;
    }

    pub fn write(self: *CheckedEntry, fields: []const Field) void {
        std.debug.assert(self.armed);
        std.debug.assert(fields.len <= field_mod.fields_max);

        self.core.write(self.io, &self.entry, self.context_fields, fields) catch {
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
        std.debug.assert(self.armed);
        std.debug.assert(self.after_hooks_count <= after_hooks_max);

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
        std.debug.assert(!self.armed);

        switch (self.terminal_action) {
            .nop, .write_then_nop => {},
            .write_then_panic => {
                self.core.sync(self.io) catch {};
                @panic("fatal log entry");
            },
            .write_then_fatal => {
                self.core.sync(self.io) catch {};
                std.process.exit(1);
            },
        }
    }

    fn write_internal_error(self: *const CheckedEntry, message: []const u8) void {
        std.debug.assert(message.len > 0);

        const prefix = "arc internal error: ";
        self.error_output.write(self.io, prefix) catch return;
        self.error_output.write(self.io, message) catch return;
        self.error_output.write(self.io, "\n") catch return;
    }

    pub fn is_valid(self: *const CheckedEntry) bool {
        return self.armed;
    }
};
