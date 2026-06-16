const std = @import("std");
const buffer_mod = @import("io/buffer.zig");
const checked_mod = @import("core/checked.zig");
const clock_mod = @import("core/clock.zig");
const config_mod = @import("config.zig");
const core_mod = @import("core/core.zig");
const entry_mod = @import("core/entry.zig");
const field_mod = @import("core/field.zig");
const hook_mod = @import("core/hook.zig");
const json_mod = @import("encoding/json.zig");
const level_mod = @import("core/level.zig");
const sampler_mod = @import("core/sampler.zig");
const stack_mod = @import("core/stack.zig");
const sugar_mod = @import("sugar.zig");
const writer_mod = @import("io/writer.zig");

const Buffer = buffer_mod.Buffer;
const CheckedEntry = checked_mod.CheckedEntry;
const Config = config_mod.Config;
const Core = core_mod.Core;
const Entry = entry_mod.Entry;
const Field = field_mod.Field;
const Level = level_mod.Level;
const SugaredLogger = sugar_mod.SugaredLogger;
const TerminalAction = checked_mod.TerminalAction;
const WriteError = writer_mod.WriteError;

pub const fields_max: u32 = field_mod.fields_max;
pub const name_max: u32 = entry_mod.name_max;
pub const scopes_max: u32 = 8;

const context_cache_max: u32 = 512;

const ContextCacheState = enum(u8) {
    unbuilt,
    ready,
    unavailable,
};

pub const Logger = struct {
    io: std.Io,
    core: core_mod.Core,
    sampler: ?*sampler_mod.Sampler,
    clock: clock_mod.Clock,
    hooks: hook_mod.HookSet,
    error_output: writer_mod.Writer,
    context_fields: [fields_max]Field,
    context_fields_count: u32,
    name_buffer: [name_max]u8,
    name_length: u32,
    scopes_count: u32,
    add_caller: bool,
    stacktrace_level: Level,
    development: bool,
    on_dpanic: TerminalAction,
    on_fatal: TerminalAction,
    context_cache_buffer: [context_cache_max]u8,
    context_cache_length: u32,
    context_cache_field_count: u32,
    context_cache_namespace_depth: u32,
    context_cache_state: ContextCacheState,

    pub fn init_with_core(io: std.Io, core: Core, config: Config) Logger {
        if (config.sampling.enabled) {
            std.debug.assert(config.sampling.tick_ns > 0);
        }

        var logger: Logger = undefined;
        logger.io = io;
        logger.core = core;
        logger.context_fields_count = 0;
        logger.name_length = 0;
        logger.scopes_count = 0;
        logger.add_caller = config.add_caller;
        logger.stacktrace_level = config.add_stacktrace_level;
        logger.development = config.is_development;
        logger.error_output = config.error_output;
        logger.sampler = null;
        logger.clock = clock_mod.Clock.init_system();
        logger.hooks = hook_mod.HookSet.init();
        logger.on_dpanic = config.on_dpanic;
        logger.on_fatal = config.on_fatal;
        logger.context_cache_length = 0;
        logger.context_cache_field_count = 0;
        logger.context_cache_namespace_depth = 0;
        logger.context_cache_state = .unbuilt;

        return logger;
    }

    pub fn init_with_config(io: std.Io, config: Config) Logger {
        const core = Core{
            .io = core_mod.IoCore.init(
                config.level,
                config.encoding,
                config.encoder_config,
                config.writer,
                config.thread_safe,
            ),
        };

        return init_with_core(io, core, config);
    }

    pub fn init_production(io: std.Io) Logger {
        return init_with_config(io, Config.production());
    }

    pub fn init_development(io: std.Io) Logger {
        return init_with_config(io, Config.development());
    }

    pub fn init_nop() Logger {
        var logger = init_with_config(undefined, Config.nop());
        logger.clock = clock_mod.Clock.init_fixed(0);

        return logger;
    }

    pub fn set_clock(self: *Logger, clock: clock_mod.Clock) void {
        self.clock = clock;
    }

    pub fn set_hooks(self: *Logger, hooks_set: hook_mod.HookSet) void {
        std.debug.assert(hooks_set.hooks_count <= hook_mod.hooks_max);

        self.hooks = hooks_set;
    }

    pub fn set_sampler(self: *Logger, sampler: *sampler_mod.Sampler) void {
        std.debug.assert(sampler.tick_ns > 0);
        std.debug.assert(sampler.first > 0);

        self.sampler = sampler;
    }

    pub fn set_drop_counter(self: *Logger, counter: *std.atomic.Value(u64)) void {
        self.core.set_drop_counter(counter);
    }

    pub fn set_error_output(self: *Logger, writer: writer_mod.Writer) void {
        self.error_output = writer;
    }

    pub fn set_level(self: *Logger, at_level: Level) void {
        if (self.core.atomic_level()) |atomic| {
            atomic.set_level(at_level);
        }
    }

    pub fn current_level(self: *const Logger) ?Level {
        return self.core.current_level();
    }

    pub fn name(self: *const Logger) []const u8 {
        std.debug.assert(self.name_length <= name_max);

        return self.name_buffer[0..self.name_length];
    }

    pub fn get_core(self: *Logger) *core_mod.Core {
        return &self.core;
    }

    pub fn sugar(self: *Logger) SugaredLogger {
        return SugaredLogger.init(self);
    }

    pub fn named(self: *const Logger, scope: []const u8) Logger {
        std.debug.assert(scope.len > 0);
        std.debug.assert(self.scopes_count < scopes_max);

        var child: Logger = self.*;
        const separator_length: u32 = if (child.name_length > 0) 1 else 0;
        const scope_length: u32 = @intCast(scope.len);
        const new_length = child.name_length + separator_length + scope_length;

        std.debug.assert(new_length <= name_max);

        if (separator_length > 0) {
            child.name_buffer[child.name_length] = '.';
            child.name_length += 1;
        }

        const destination_start = child.name_length;
        const destination_end = destination_start + scope_length;
        @memcpy(child.name_buffer[destination_start..destination_end], scope);
        child.name_length = new_length;
        child.scopes_count += 1;

        return child;
    }

    pub fn with(self: *const Logger, fields: []const Field) Logger {
        const fields_length: u32 = @intCast(fields.len);

        std.debug.assert(self.context_fields_count + fields_length <= fields_max);
        std.debug.assert(fields.len > 0);

        var child: Logger = self.*;
        child.context_cache_state = .unbuilt;

        for (fields) |field| {
            child.context_fields[child.context_fields_count] = field;
            child.context_fields_count += 1;
        }

        std.debug.assert(child.context_fields_count <= fields_max);
        return child;
    }

    pub fn debug(
        self: *Logger,
        message: []const u8,
        fields: []const Field,
        src: std.builtin.SourceLocation,
    ) void {
        self.log(.debug, message, fields, src);
    }

    pub fn info(
        self: *Logger,
        message: []const u8,
        fields: []const Field,
        src: std.builtin.SourceLocation,
    ) void {
        self.log(.info, message, fields, src);
    }

    pub fn warn(
        self: *Logger,
        message: []const u8,
        fields: []const Field,
        src: std.builtin.SourceLocation,
    ) void {
        self.log(.warn, message, fields, src);
    }

    pub fn @"error"(
        self: *Logger,
        message: []const u8,
        fields: []const Field,
        src: std.builtin.SourceLocation,
    ) void {
        self.log(.err, message, fields, src);
    }

    pub fn dpanic(
        self: *Logger,
        message: []const u8,
        fields: []const Field,
        src: std.builtin.SourceLocation,
    ) void {
        self.log(.dpanic, message, fields, src);
    }

    pub fn panic(
        self: *Logger,
        message: []const u8,
        fields: []const Field,
        src: std.builtin.SourceLocation,
    ) void {
        self.log(.panic, message, fields, src);
    }

    pub fn fatal(
        self: *Logger,
        message: []const u8,
        fields: []const Field,
        src: std.builtin.SourceLocation,
    ) void {
        self.log(.fatal, message, fields, src);
    }

    pub fn sync(self: *Logger) WriteError!void {
        try self.core.sync(self.io);
    }

    pub fn check(self: *const Logger, at_level: Level) bool {
        return self.core.enabled(at_level);
    }

    pub fn check_entry(
        self: *Logger,
        at_level: Level,
        message: []const u8,
        src: std.builtin.SourceLocation,
    ) ?CheckedEntry {
        return self.check_entry_with_source(at_level, message, src);
    }

    fn check_entry_with_source(
        self: *Logger,
        at_level: Level,
        message: []const u8,
        src: std.builtin.SourceLocation,
    ) ?CheckedEntry {
        std.debug.assert(self.context_fields_count <= fields_max);

        if (!self.should_log(at_level, message)) {
            return null;
        }

        var entry = self.prepare_entry(at_level, message, src);
        self.maybe_add_stack(&entry, at_level);
        self.apply_context_cache(&entry);

        const context_slice = self.context_fields[0..self.context_fields_count];

        var checked_entry = CheckedEntry.init(
            self.io,
            &entry,
            &self.core,
            context_slice,
            self.error_output,
            &self.hooks,
        );

        const action = self.terminal_action_for_level(at_level);
        _ = checked_entry.with_terminal_action(action);

        return checked_entry;
    }

    fn should_log(self: *Logger, at_level: Level, message: []const u8) bool {
        const must_log = level_must_log(at_level);

        if (!must_log and !self.core.enabled(at_level)) {
            return false;
        }

        if (!must_log) {
            if (self.sampler) |sampler| {
                const decision = sampler.check(self.io, at_level, message, &self.clock);

                if (decision == .dropped) {
                    return false;
                }
            }
        }

        return true;
    }

    fn prepare_entry(
        self: *Logger,
        at_level: Level,
        message: []const u8,
        src: std.builtin.SourceLocation,
    ) Entry {
        std.debug.assert(self.name_length <= name_max);

        const logger_name = self.name();

        var entry = Entry.init_with_clock(self.io, at_level, message, logger_name, &self.clock);

        if (self.add_caller) {
            entry.with_caller(src.file, @intCast(src.line), src.fn_name);
        }

        return entry;
    }

    fn ensure_context_cache(self: *Logger) void {
        if (self.context_cache_state != .unbuilt) {
            return;
        }

        self.context_cache_state = .unavailable;

        if (self.context_fields_count == 0) {
            return;
        }

        const io_core = self.core.single_io_core() orelse return;

        const config = switch (io_core.encoder) {
            .json => |*json_encoder| &json_encoder.config,
            .console => return,
        };

        var buffer = Buffer.init();
        const context_slice = self.context_fields[0..self.context_fields_count];
        const fragment = json_mod.encode_context_fragment(&buffer, config, context_slice);

        if (buffer.was_truncated() or buffer.len() > context_cache_max) {
            return;
        }

        const length = buffer.len();

        @memcpy(self.context_cache_buffer[0..length], buffer.contents());
        self.context_cache_length = length;
        self.context_cache_field_count = fragment.field_count;
        self.context_cache_namespace_depth = fragment.namespace_depth;
        self.context_cache_state = .ready;
    }

    fn apply_context_cache(self: *Logger, entry: *Entry) void {
        self.ensure_context_cache();

        if (self.context_cache_state != .ready) {
            return;
        }

        entry.context_cache = .{
            .bytes = self.context_cache_buffer[0..self.context_cache_length],
            .field_count = self.context_cache_field_count,
            .namespace_depth = self.context_cache_namespace_depth,
        };
    }

    pub fn log(
        self: *Logger,
        at_level: Level,
        message: []const u8,
        fields: []const Field,
        source: std.builtin.SourceLocation,
    ) void {
        std.debug.assert(fields.len <= fields_max);

        if (!self.should_log(at_level, message)) {
            return;
        }

        var entry = self.prepare_entry(at_level, message, source);
        self.maybe_add_stack(&entry, at_level);
        self.apply_context_cache(&entry);

        const context_slice = self.context_fields[0..self.context_fields_count];

        self.core.write(self.io, &entry, context_slice, fields) catch {
            self.write_internal_error("failed to write log entry");
        };

        if (!self.hooks.is_empty()) {
            self.hooks.run(&entry);
        }

        self.execute_terminal_action(at_level);
    }

    fn terminal_action_for_level(self: *const Logger, at_level: Level) TerminalAction {
        return switch (at_level) {
            .dpanic => self.on_dpanic,
            .panic => .write_then_panic,
            .fatal => self.on_fatal,
            .debug, .info, .warn, .err => .write_then_nop,
        };
    }

    fn execute_terminal_action(self: *Logger, at_level: Level) void {
        const action = self.terminal_action_for_level(at_level);

        switch (action) {
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

    fn write_internal_error(self: *Logger, message: []const u8) void {
        std.debug.assert(message.len > 0);

        const prefix = "arc internal error: ";
        self.error_output.write(self.io, prefix) catch return;
        self.error_output.write(self.io, message) catch return;
        self.error_output.write(self.io, "\n") catch return;
    }

    fn maybe_add_stack(self: *const Logger, entry: *Entry, at_level: Level) void {
        if (!self.stacktrace_level.enabled(at_level)) {
            return;
        }

        const return_address = @returnAddress();

        if (return_address == 0) {
            return;
        }

        var trace = stack_mod.StackTrace.capture(return_address);
        var stack_buffer: Buffer = Buffer.init();
        trace.format_to_buffer(&stack_buffer);

        if (stack_buffer.len() > 0) {
            entry.with_stack(stack_buffer.contents());
        }
    }
};

fn level_must_log(at_level: Level) bool {
    return @intFromEnum(at_level) >= @intFromEnum(Level.dpanic);
}
