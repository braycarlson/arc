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
const observer_mod = @import("observer.zig");

const assert = std.debug.assert;

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

pub const Logger = struct {
    io: ?std.Io,
    core: core_mod.Core,
    sampler: ?*sampler_mod.Sampler,
    clock: clock_mod.Clock,
    hooks: hook_mod.HookSet,
    error_output: writer_mod.Writer,
    context_fields: [fields_max]Field,
    context_fields_count: u32,
    name_buffer: [name_bytes_max]u8,
    name_length: u32,
    scopes_count: u32,
    caller_enabled: bool,
    stacktrace_level: Level,
    development: bool,
    dpanic_action: TerminalAction,
    fatal_action: TerminalAction,
    context_cache_buffer: [context_cache_bytes_max]u8,
    context_cache_length: u32,
    context_cache_field_count: u32,
    context_cache_namespace_depth: u32,
    context_cache_state: ContextCacheState,

    pub fn init_with_core(io: ?std.Io, core: Core, config: Config) Logger {
        if (config.sampling.enabled) {
            assert(config.sampling.tick_ns > 0);
        }

        const logger = Logger{
            .io = io,
            .core = core,
            .sampler = null,
            .clock = clock_mod.Clock.init_system(),
            .hooks = hook_mod.HookSet.init(),
            .error_output = config.error_output,
            .context_fields = @splat(unused_field),
            .context_fields_count = 0,
            .name_buffer = @splat(0),
            .name_length = 0,
            .scopes_count = 0,
            .caller_enabled = config.caller_enabled,
            .stacktrace_level = config.stacktrace_level_min,
            .development = config.is_development,
            .dpanic_action = config.dpanic_action,
            .fatal_action = config.fatal_action,
            .context_cache_buffer = @splat(0),
            .context_cache_length = 0,
            .context_cache_field_count = 0,
            .context_cache_namespace_depth = 0,
            .context_cache_state = .unbuilt,
        };

        assert(logger.is_valid());

        return logger;
    }

    pub fn init_with_config(io: ?std.Io, config: Config) Logger {
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
        var logger = init_with_config(null, Config.nop());
        logger.clock = clock_mod.Clock.init_fixed(0);

        return logger;
    }

    fn require_io(self: *const Logger) std.Io {
        return self.io orelse @panic("logger was built without an io");
    }

    pub fn is_valid(self: *const Logger) bool {
        if (self.context_fields_count > fields_max) return false;
        if (self.name_length > name_bytes_max) return false;
        if (self.scopes_count > scopes_max) return false;
        if (self.context_cache_length > context_cache_bytes_max) return false;

        return true;
    }

    pub fn set_clock(self: *Logger, clock: clock_mod.Clock) void {
        self.clock = clock;
    }

    pub fn set_hooks(self: *Logger, hooks_set: hook_mod.HookSet) void {
        assert(hooks_set.hooks_count <= hook_mod.hooks_max);

        self.hooks = hooks_set;
    }

    pub fn set_sampler(self: *Logger, sampler: *sampler_mod.Sampler) void {
        assert(sampler.tick_ns > 0);
        assert(sampler.first > 0);

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
        assert(self.name_length <= name_bytes_max);

        return self.name_buffer[0..self.name_length];
    }

    pub fn get_core(self: *Logger) *core_mod.Core {
        return &self.core;
    }

    pub fn sugar(self: *Logger) SugaredLogger {
        return SugaredLogger.init(self);
    }

    pub fn named(self: *const Logger, scope: []const u8) Logger {
        assert(scope.len > 0);
        assert(self.scopes_count < scopes_max);

        var child: Logger = self.*;
        const separator_length: u32 = if (child.name_length > 0) 1 else 0;
        const scope_length: u32 = @intCast(scope.len);
        const new_length = child.name_length + separator_length + scope_length;

        assert(new_length <= name_bytes_max);

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

        assert(self.context_fields_count + fields_length <= fields_max);
        assert(fields.len > 0);

        var child: Logger = self.*;
        child.context_cache_state = .unbuilt;

        for (fields) |field| {
            child.context_fields[child.context_fields_count] = field;
            child.context_fields_count += 1;
        }

        assert(child.context_fields_count <= fields_max);

        return child;
    }

    pub fn debug(
        self: *Logger,
        message: []const u8,
        fields: []const Field,
        source: std.builtin.SourceLocation,
    ) void {
        self.log(.debug, message, fields, source);
    }

    pub fn info(
        self: *Logger,
        message: []const u8,
        fields: []const Field,
        source: std.builtin.SourceLocation,
    ) void {
        self.log(.info, message, fields, source);
    }

    pub fn warn(
        self: *Logger,
        message: []const u8,
        fields: []const Field,
        source: std.builtin.SourceLocation,
    ) void {
        self.log(.warn, message, fields, source);
    }

    pub fn @"error"(
        self: *Logger,
        message: []const u8,
        fields: []const Field,
        source: std.builtin.SourceLocation,
    ) void {
        self.log(.err, message, fields, source);
    }

    pub fn dpanic(
        self: *Logger,
        message: []const u8,
        fields: []const Field,
        source: std.builtin.SourceLocation,
    ) void {
        self.log(.dpanic, message, fields, source);
    }

    pub fn panic(
        self: *Logger,
        message: []const u8,
        fields: []const Field,
        source: std.builtin.SourceLocation,
    ) void {
        self.log(.panic, message, fields, source);
    }

    pub fn fatal(
        self: *Logger,
        message: []const u8,
        fields: []const Field,
        source: std.builtin.SourceLocation,
    ) void {
        self.log(.fatal, message, fields, source);
    }

    pub fn sync(self: *Logger) WriteError!void {
        try self.core.sync(self.require_io());
    }

    pub fn check(self: *const Logger, at_level: Level) bool {
        return self.core.enabled(at_level);
    }

    pub fn check_entry(
        self: *Logger,
        checked_entry: *CheckedEntry,
        at_level: Level,
        message: []const u8,
        source: std.builtin.SourceLocation,
    ) bool {
        return self.check_entry_with_source(checked_entry, at_level, message, source);
    }

    fn check_entry_with_source(
        self: *Logger,
        checked_entry: *CheckedEntry,
        at_level: Level,
        message: []const u8,
        source: std.builtin.SourceLocation,
    ) bool {
        assert(self.is_valid());

        if (!self.should_log(at_level, message)) {
            return false;
        }

        var entry = self.prepare_entry(at_level, message, source);

        self.maybe_add_stack(&entry, at_level);
        self.apply_context_cache(&entry);

        checked_entry.init(.{
            .io = self.require_io(),
            .entry = &entry,
            .core = &self.core,
            .context_fields = self.context_fields[0..self.context_fields_count],
            .error_output = self.error_output,
            .hooks = &self.hooks,
        });

        const action = self.terminal_action_for_level(at_level);

        _ = checked_entry.with_terminal_action(action);

        return true;
    }

    fn should_log(self: *Logger, at_level: Level, message: []const u8) bool {
        assert(self.is_valid());

        const must_log = should_log_always(at_level);

        if (!must_log) {
            if (!self.core.enabled(at_level)) {
                return false;
            }
        }

        if (!must_log) {
            if (self.sampler) |sampler| {
                const decision = sampler.check(self.require_io(), at_level, message, &self.clock);

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
        source: std.builtin.SourceLocation,
    ) Entry {
        assert(self.is_valid());

        const logger_name = self.name();

        var entry = Entry.init_with_clock(
            self.require_io(),
            at_level,
            message,
            logger_name,
            &self.clock,
        );

        if (self.caller_enabled) {
            entry.with_caller(.{
                .file = source.file,
                .line = @intCast(source.line),
                .function = source.fn_name,
            });
        }

        return entry;
    }

    fn apply_context_cache(self: *Logger, entry: *Entry) void {
        self.apply_context_cache_build();

        if (self.context_cache_state != .ready) {
            return;
        }

        entry.context_cache = .{
            .bytes = self.context_cache_buffer[0..self.context_cache_length],
            .field_count = self.context_cache_field_count,
            .namespace_depth = self.context_cache_namespace_depth,
        };
    }

    fn apply_context_cache_build(self: *Logger) void {
        assert(self.is_valid());

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

        if (buffer.was_truncated()) {
            return;
        }

        if (buffer.length() > context_cache_bytes_max) {
            return;
        }

        const length = buffer.length();

        assert(length <= context_cache_bytes_max);
        assert(fragment.namespace_depth <= json_mod.namespace_depth_max);

        @memcpy(self.context_cache_buffer[0..length], buffer.contents());
        self.context_cache_length = length;
        self.context_cache_field_count = fragment.field_count;
        self.context_cache_namespace_depth = fragment.namespace_depth;
        self.context_cache_state = .ready;

        assert(self.is_valid());
    }

    pub fn log(
        self: *Logger,
        at_level: Level,
        message: []const u8,
        fields: []const Field,
        source: std.builtin.SourceLocation,
    ) void {
        assert(fields.len <= fields_max);
        assert(self.is_valid());

        if (!self.should_log(at_level, message)) {
            return;
        }

        var entry = self.prepare_entry(at_level, message, source);
        self.maybe_add_stack(&entry, at_level);
        self.apply_context_cache(&entry);

        const context_slice = self.context_fields[0..self.context_fields_count];

        const entry_fields: field_mod.EntryFields = .{
            .context = context_slice,
            .message = fields,
        };

        self.core.write(self.require_io(), &entry, entry_fields) catch {
            self.write_internal_error("failed to write log entry");
        };

        if (!self.hooks.is_empty()) {
            self.hooks.run(&entry);
        }

        self.execute_terminal_action(at_level);
    }

    fn terminal_action_for_level(self: *const Logger, at_level: Level) TerminalAction {
        return switch (at_level) {
            .dpanic => self.dpanic_action,
            .panic => .write_then_panic,
            .fatal => self.fatal_action,
            .debug, .info, .warn, .err => .write_then_nop,
        };
    }

    fn execute_terminal_action(self: *Logger, at_level: Level) void {
        assert(self.is_valid());

        const action = self.terminal_action_for_level(at_level);

        switch (action) {
            .nop, .write_then_nop => {},
            .write_then_panic => {
                self.core.sync(self.require_io()) catch {
                    self.write_internal_error("failed to sync before panic");
                };

                @panic("fatal log entry");
            },
            .write_then_fatal => {
                self.core.sync(self.require_io()) catch {
                    self.write_internal_error("failed to sync before exit");
                };

                std.process.exit(1);
            },
        }
    }

    fn write_internal_error(self: *Logger, message: []const u8) void {
        assert(message.len > 0);

        const prefix = "arc internal error: ";
        self.error_output.write(self.require_io(), prefix) catch return;
        self.error_output.write(self.require_io(), message) catch return;
        self.error_output.write(self.require_io(), "\n") catch return;
    }

    fn maybe_add_stack(self: *const Logger, entry: *Entry, at_level: Level) void {
        assert(self.is_valid());

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

        assert(stack_buffer.is_valid());

        if (stack_buffer.length() > 0) {
            entry.with_stack(stack_buffer.contents());
        }
    }
};

const ContextCacheState = enum(u8) {
    unbuilt,
    ready,
    unavailable,
};

pub const fields_max: u32 = field_mod.fields_max;
pub const name_bytes_max: u32 = entry_mod.name_bytes_max;
pub const scopes_max: u32 = 8;

const context_cache_bytes_max: u32 = 512;

const unused_field: Field = field_mod.skip();

comptime {
    assert(fields_max > 0);
    assert(name_bytes_max > 0);
    assert(scopes_max > 0);
    assert(context_cache_bytes_max > 0);
    assert(context_cache_bytes_max <= buffer_mod.buffer_bytes_max);
    assert(entry_mod.stack_bytes_max <= buffer_mod.buffer_bytes_max);
}

fn should_log_always(at_level: Level) bool {
    return @intFromEnum(at_level) >= @intFromEnum(Level.dpanic);
}

const testing = std.testing;

const Clock = clock_mod.Clock;
const Observer = observer_mod.Observer;
const Writer = writer_mod.Writer;

fn test_logger(output: *Buffer) Logger {
    var logger = Logger.init_with_config(
        testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = output })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    assert(logger.check(.debug));
    assert(logger.context_fields_count == 0);

    return logger;
}

fn test_observer_logger(observer: *Observer) Logger {
    var logger = Logger.init_with_config(
        testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .nop = {} })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.core = .{ .observer = observer };
    logger.set_clock(Clock.init_fixed(1_700_000_000));

    assert(logger.core.enabled(observer.minimum_level));
    assert(logger.context_fields_count == 0);

    return logger;
}

test "a logger writes json output" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    logger.info("server started", &.{}, @src());

    try testing.expect(output.contains("server started"));
    try testing.expect(output.contains("info"));

    assert(output.contains("server started"));
    assert(!output.is_empty());
}

test "a logger writes nothing below its level threshold" {
    var output = Buffer.init();

    var logger = Logger.init_with_config(
        testing.io,
        Config.production()
            .with_level(.warn)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.debug("should not appear", &.{}, @src());
    logger.info("should not appear", &.{}, @src());

    try testing.expect(output.is_empty());

    logger.warn("should appear", &.{}, @src());

    try testing.expect(output.contains("should appear"));

    assert(output.contains("should appear"));
    assert(!output.contains("should not appear"));
}

test "a logger writes the structured fields it was given" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    logger.info("request", &.{
        field_mod.string("method", "GET"),
        field_mod.string("path", "/health"),
        field_mod.int("status", 200),
    }, @src());

    try testing.expect(output.contains("method"));
    try testing.expect(output.contains("GET"));
    try testing.expect(output.contains("path"));
    try testing.expect(output.contains("/health"));
    try testing.expect(output.contains("status"));
    try testing.expect(output.contains("200"));

    assert(output.contains("GET"));
    assert(output.contains("/health"));
}

test "a logger encodes numeric and float fields" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    logger.info("metrics", &.{
        field_mod.uint64("bytes", 1024),
        field_mod.float64("ratio", 0.95),
        field_mod.int32("offset", -42),
    }, @src());

    try testing.expect(output.contains("bytes"));
    try testing.expect(output.contains("1024"));
    try testing.expect(output.contains("ratio"));
    try testing.expect(output.contains("offset"));
    try testing.expect(output.contains("-42"));

    assert(output.contains("1024"));
    assert(output.contains("-42"));
}

test "a logger encodes boolean and duration fields" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    logger.info("config", &.{
        field_mod.boolean("verbose", true),
        field_mod.boolean("dry_run", false),
        field_mod.duration_ns("timeout", 5_000_000_000),
    }, @src());

    try testing.expect(output.contains("verbose"));
    try testing.expect(output.contains("true"));
    try testing.expect(output.contains("dry_run"));
    try testing.expect(output.contains("false"));
    try testing.expect(output.contains("timeout"));

    assert(output.contains("true"));
    assert(output.contains("false"));
}

test "a named child logger carries its name into the output" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    var child = logger.named("http");

    child.info("request", &.{}, @src());

    try testing.expect(output.contains("http"));
    try testing.expect(output.contains("request"));

    assert(child.name().len > 0);
    assert(output.contains("http"));
}

test "a logger with context fields writes them on every call" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    var child = logger.with(&.{
        field_mod.string("service", "api"),
    });

    child.info("test", &.{}, @src());

    try testing.expect(output.contains("service"));
    try testing.expect(output.contains("api"));

    assert(child.context_fields_count == 1);
    assert(output.contains("service"));
}

test "setting the level at runtime changes what a logger writes" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    logger.set_level(.err);

    logger.info("hidden", &.{}, @src());

    try testing.expect(output.is_empty());

    logger.@"error"("visible", &.{}, @src());

    try testing.expect(output.contains("visible"));
    try testing.expect(!output.contains("hidden"));

    assert(output.contains("visible"));
    assert(!output.contains("hidden"));
}

test "checking a level reports whether the logger would write it" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    try testing.expect(logger.check(.debug));
    try testing.expect(logger.check(.info));
    try testing.expect(logger.check(.fatal));

    logger.set_level(.err);

    try testing.expect(!logger.check(.debug));
    try testing.expect(!logger.check(.info));
    try testing.expect(logger.check(.err));
    try testing.expect(logger.check(.fatal));

    assert(!logger.check(.debug));
    assert(logger.check(.err));
}

test "a nop logger writes nothing" {
    var logger = Logger.init_nop();

    logger.info("nothing", &.{}, @src());
    logger.@"error"("nothing", &.{}, @src());

    try testing.expect(!logger.check(.debug));
    try testing.expect(!logger.check(.info));
    try testing.expect(!logger.check(.err));
    try testing.expect(logger.check(.fatal));

    assert(!logger.check(.info));
    assert(logger.check(.fatal));
}

test "every level method on a logger produces output" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    logger.debug("d", &.{}, @src());
    try testing.expect(output.contains("d"));

    output.reset();
    logger.info("i", &.{}, @src());
    try testing.expect(output.contains("i"));

    output.reset();
    logger.warn("w", &.{}, @src());
    try testing.expect(output.contains("w"));

    output.reset();
    logger.@"error"("e", &.{}, @src());
    try testing.expect(output.contains("e"));

    assert(!output.is_empty());
    assert(output.length() > 0);
}

test "a logger encodes the instant its clock reports" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    logger.info("timestamped", &.{}, @src());

    try testing.expect(output.contains("1700000000"));

    assert(output.contains("1700000000"));
    assert(output.contains("timestamped"));
}

test "an observer core records the entries a logger writes" {
    var observer: Observer = undefined;

    observer.init(.debug);
    var logger = test_observer_logger(&observer);

    logger.info("hello", &.{}, @src());
    logger.debug("world", &.{}, @src());

    try testing.expectEqual(@as(u32, 2), observer.count());
    try testing.expect(!observer.is_empty());

    const first = observer.first().?;

    try testing.expectEqualStrings("hello", first.message());
    try testing.expectEqual(Level.info, first.at_level);

    const last = observer.last().?;

    try testing.expectEqualStrings("world", last.message());
    try testing.expectEqual(Level.debug, last.at_level);

    assert(observer.count() == 2);
    assert(first.at_level == .info);
}

test "an observer core records only entries at or above its minimum level" {
    var observer: Observer = undefined;

    observer.init(.warn);
    var logger = test_observer_logger(&observer);

    logger.core = .{ .observer = &observer };

    logger.debug("hidden-d", &.{}, @src());
    logger.info("hidden-i", &.{}, @src());
    logger.warn("visible-w", &.{}, @src());
    logger.@"error"("visible-e", &.{}, @src());

    try testing.expectEqual(@as(u32, 2), observer.count());
    try testing.expectEqual(@as(u32, 1), observer.count_by_level(.warn));
    try testing.expectEqual(@as(u32, 1), observer.count_by_level(.err));
    try testing.expectEqual(@as(u32, 0), observer.count_by_level(.info));

    assert(observer.count_by_level(.debug) == 0);
    assert(observer.count_by_level(.warn) == 1);
}

test "an observer core records the context fields of an entry" {
    var observer: Observer = undefined;

    observer.init(.debug);
    var logger = test_observer_logger(&observer);

    logger.info("request", &.{
        field_mod.string("service", "api"),
        field_mod.int32("version", 2),
        field_mod.string("method", "GET"),
    }, @src());

    try testing.expectEqual(@as(u32, 1), observer.count());

    const entry = observer.first().?;

    try testing.expectEqualStrings("request", entry.message());
    try testing.expect(entry.has_field("service"));
    try testing.expect(entry.has_field("version"));
    try testing.expect(entry.has_field("method"));
    try testing.expectEqual(@as(u32, 3), entry.fields_count);

    assert(entry.fields_count == 3);
    assert(entry.has_field("service"));
}

test "an observer core records the name of the logger that wrote the entry" {
    var observer: Observer = undefined;

    observer.init(.debug);
    var logger = test_observer_logger(&observer);

    var child = logger.named("http").named("server");

    child.info("serving", &.{}, @src());

    try testing.expectEqual(@as(u32, 1), observer.count());

    const entry = observer.first().?;

    try testing.expectEqualStrings("http.server", entry.logger_name());

    assert(entry.logger_name().len == "http.server".len);
}

test "an observer core returns the indexes of entries matching a message" {
    var observer: Observer = undefined;

    observer.init(.debug);
    var logger = test_observer_logger(&observer);

    logger.info("alpha", &.{}, @src());
    logger.info("beta", &.{}, @src());
    logger.info("alpha", &.{}, @src());
    logger.warn("gamma", &.{}, @src());

    try testing.expectEqual(@as(u32, 4), observer.count());
    try testing.expectEqual(@as(u32, 2), observer.count_by_message("alpha"));
    try testing.expectEqual(@as(u32, 1), observer.count_by_message("beta"));
    try testing.expectEqual(@as(u32, 1), observer.count_by_message("gamma"));

    assert(observer.count_by_message("alpha") == 2);
    assert(observer.count_by_message("nonexistent") == 0);
}

test "an observer core returns the indexes of entries at a level" {
    var observer: Observer = undefined;

    observer.init(.debug);
    var logger = test_observer_logger(&observer);

    logger.debug("d1", &.{}, @src());
    logger.debug("d2", &.{}, @src());
    logger.info("i1", &.{}, @src());
    logger.warn("w1", &.{}, @src());
    logger.@"error"("e1", &.{}, @src());

    try testing.expectEqual(@as(u32, 5), observer.count());
    try testing.expectEqual(@as(u32, 2), observer.count_by_level(.debug));
    try testing.expectEqual(@as(u32, 1), observer.count_by_level(.info));
    try testing.expectEqual(@as(u32, 1), observer.count_by_level(.warn));
    try testing.expectEqual(@as(u32, 1), observer.count_by_level(.err));

    assert(observer.count_by_level(.debug) == 2);
    assert(observer.count_by_level(.fatal) == 0);
}

test "resetting an observer core discards the entries it held" {
    var observer: Observer = undefined;

    observer.init(.debug);
    var logger = test_observer_logger(&observer);

    logger.info("one", &.{}, @src());
    logger.info("two", &.{}, @src());

    try testing.expectEqual(@as(u32, 2), observer.count());

    observer.reset();

    try testing.expectEqual(@as(u32, 0), observer.count());
    try testing.expect(observer.is_empty());
    try testing.expect(observer.first() == null);
    try testing.expect(observer.last() == null);

    assert(observer.is_empty());
}

test "an observer core records the instant of each entry" {
    var observer: Observer = undefined;

    observer.init(.debug);
    var logger = test_observer_logger(&observer);

    logger.info("timed", &.{}, @src());

    const entry = observer.first().?;

    try testing.expectEqual(@as(i64, 1_700_000_000), entry.timestamp_s);

    assert(entry.timestamp_s == 1_700_000_000);
}

test "naming a child logger leaves the parent unchanged" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    const child = logger.named("child");

    try testing.expectEqualStrings("", logger.name());
    try testing.expectEqualStrings("child", child.name());

    assert(logger.name().len == 0);
    assert(logger.scopes_count == 0);
}

test "adding context to a child logger leaves the parent unchanged" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    const child = logger.with(&.{
        field_mod.string("k", "v"),
    });

    try testing.expectEqual(@as(u32, 0), logger.context_fields_count);
    try testing.expectEqual(@as(u32, 1), child.context_fields_count);

    assert(logger.context_fields_count == 0);
}

test "two children of one logger do not share the context added to either" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    var child_a = logger.with(&.{
        field_mod.string("branch", "a"),
    });

    var child_b = logger.with(&.{
        field_mod.string("branch", "b"),
    });

    child_a.info("from-a", &.{}, @src());
    try testing.expect(output.contains("branch"));
    try testing.expect(output.contains("\"a\""));
    try testing.expect(!output.contains("\"b\""));

    output.reset();

    child_b.info("from-b", &.{}, @src());
    try testing.expect(output.contains("branch"));
    try testing.expect(output.contains("\"b\""));
    try testing.expect(!output.contains("\"a\""));

    assert(child_a.context_fields_count == 1);
    assert(child_b.context_fields_count == 1);
}

test "chained naming builds a dotted logger name" {
    var logger = Logger.init_nop();

    var child = logger.named("a").named("b").named("c");

    try testing.expectEqualStrings("a.b.c", child.name());

    assert(child.name_length == 5);
    assert(child.scopes_count == 3);
}

test "checking an entry below the threshold returns nothing" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    logger.set_level(.err);

    var checked: CheckedEntry = undefined;
    const checkable = logger.check_entry(&checked, .info, "hidden", @src());

    try testing.expect(!checkable);
    try testing.expect(output.is_empty());

    assert(!checkable);
}

test "checking an entry at or above the threshold returns a checked entry" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    var checked: CheckedEntry = undefined;
    const checkable = logger.check_entry(&checked, .info, "visible", @src());

    try testing.expect(checkable);
    try testing.expect(checked.is_armed());

    assert(checkable);
}

test "a dpanic entry writes without panicking under a production config" {
    var output = Buffer.init();

    var logger = Logger.init_with_config(
        testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal)
            .with_dpanic_hook(.write_then_nop),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    logger.dpanic("production dpanic", &.{}, @src());

    try testing.expect(output.contains("production dpanic"));
    try testing.expect(output.contains("dpanic"));

    assert(output.contains("production dpanic"));
    assert(!output.is_empty());
}

test "syncing a logger backed by a buffer succeeds" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    logger.info("before sync", &.{}, @src());

    try logger.sync();

    try testing.expect(output.contains("before sync"));

    assert(!output.is_empty());
}

test "a production logger carries the production defaults" {
    const logger = Logger.init_production(testing.io);

    try testing.expect(logger.check(.info));
    try testing.expect(logger.check(.warn));
    try testing.expect(logger.check(.err));
    try testing.expect(!logger.check(.debug));
    try testing.expect(logger.caller_enabled);
    try testing.expectEqual(@as(u32, 0), logger.context_fields_count);
    try testing.expectEqual(@as(u32, 0), logger.name_length);

    assert(logger.caller_enabled);
    assert(logger.context_fields_count == 0);
}

test "a development logger carries the development defaults" {
    const logger = Logger.init_development(testing.io);

    try testing.expect(logger.check(.debug));
    try testing.expect(logger.check(.info));
    try testing.expect(logger.development);
    try testing.expect(logger.caller_enabled);
    try testing.expectEqual(@as(u32, 0), logger.context_fields_count);
    try testing.expectEqual(@as(u32, 0), logger.name_length);

    assert(logger.development);
    assert(logger.check(.debug));
}

test "a logger reports the level it was configured with" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    const initial = logger.current_level();

    try testing.expect(initial != null);
    try testing.expectEqual(Level.debug, initial.?);

    logger.set_level(.warn);

    const updated = logger.current_level();

    try testing.expect(updated != null);
    try testing.expectEqual(Level.warn, updated.?);

    assert(updated.? == .warn);
}

test "a nop logger reports fatal as its level" {
    const logger = Logger.init_nop();

    const lvl = logger.current_level();

    try testing.expect(lvl != null);
    try testing.expectEqual(Level.fatal, lvl.?);

    assert(lvl.? == .fatal);
}

test "an empty field slice adds nothing to the output" {
    var observer: Observer = undefined;

    observer.init(.debug);
    var logger = test_observer_logger(&observer);

    logger.info("no-fields", &.{}, @src());

    try testing.expectEqual(@as(u32, 1), observer.count());

    const entry = observer.first().?;

    try testing.expectEqual(@as(u32, 0), entry.fields_count);
    try testing.expectEqualStrings("no-fields", entry.message());

    assert(entry.fields_count == 0);
}

test "the sugar accessor wraps the logger it was called on" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    const sugared = logger.sugar();

    try testing.expect(sugared.logger == &logger);

    assert(sugared.logger == &logger);
}

test "successive context additions accumulate on a logger" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    var child = logger
        .with(&.{field_mod.string("a", "1")})
        .with(&.{field_mod.string("b", "2")});

    child.info("multi-ctx", &.{}, @src());

    try testing.expect(output.contains("multi-ctx"));
    try testing.expect(output.contains("\"a\""));
    try testing.expect(output.contains("\"1\""));
    try testing.expect(output.contains("\"b\""));
    try testing.expect(output.contains("\"2\""));

    assert(child.context_fields_count == 2);
    assert(!output.is_empty());
}

test "a logger keeps both its name and its context when given each in turn" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    var child = logger
        .named("db")
        .with(&.{field_mod.string("engine", "postgres")});

    child.info("query", &.{
        field_mod.int32("rows", 42),
    }, @src());

    try testing.expect(output.contains("db"));
    try testing.expect(output.contains("engine"));
    try testing.expect(output.contains("postgres"));
    try testing.expect(output.contains("rows"));
    try testing.expect(output.contains("42"));
    try testing.expect(output.contains("query"));

    assert(child.name().len == 2);
    assert(child.context_fields_count == 1);
}

test "an observed entry returns nothing for a key it does not hold" {
    var observer: Observer = undefined;

    observer.init(.debug);
    var logger = test_observer_logger(&observer);

    logger.info("sparse", &.{
        field_mod.string("present", "yes"),
    }, @src());

    const entry = observer.first().?;

    try testing.expect(entry.field_by_key("present") != null);
    try testing.expect(entry.field_by_key("absent") == null);

    assert(entry.field_by_key("absent") == null);
}

test "an observer core returns every entry it recorded" {
    var observer: Observer = undefined;

    observer.init(.debug);
    var logger = test_observer_logger(&observer);

    logger.info("one", &.{}, @src());
    logger.info("two", &.{}, @src());
    logger.info("three", &.{}, @src());

    const entries = observer.all();

    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqualStrings("one", entries[0].message());
    try testing.expectEqualStrings("two", entries[1].message());
    try testing.expectEqualStrings("three", entries[2].message());

    assert(entries.len == 3);
}

test "an empty observer core reports no entries at any level" {
    var observer: Observer = undefined;

    observer.init(.debug);

    try testing.expect(observer.is_empty());
    try testing.expectEqual(@as(u32, 0), observer.count());
    try testing.expect(observer.first() == null);
    try testing.expect(observer.last() == null);
    try testing.expectEqual(@as(usize, 0), observer.all().len);

    assert(observer.is_empty());
}

fn json_logger(output: *Buffer) Logger {
    var logger = Logger.init_with_config(
        testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = output })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    return logger;
}

test "pre-encoded context matches the same fields passed at the call site" {
    const context = [_]Field{
        field_mod.int("a", 1),
        field_mod.string("b", "x"),
        field_mod.namespace("ns"),
        field_mod.int("c", 3),
    };

    const call = [_]Field{
        field_mod.int("d", 4),
        field_mod.boolean("e", true),
    };

    var out_cached = Buffer.init();
    var base = json_logger(&out_cached);
    var child = base.with(&context);

    child.info("msg", &call, @src());

    var out_plain = Buffer.init();
    var plain = json_logger(&out_plain);

    var combined: [context.len + call.len]Field = undefined;
    @memcpy(combined[0..context.len], &context);
    @memcpy(combined[context.len..], &call);

    plain.info("msg", &combined, @src());

    try testing.expectEqualSlices(u8, out_plain.contents(), out_cached.contents());

    assert(out_cached.length() == out_plain.length());
}

test "chained context additions rebuild the cache and stay correct on reuse" {
    const first = [_]Field{field_mod.int("a", 1)};
    const second = [_]Field{ field_mod.string("b", "two"), field_mod.boolean("c", true) };

    var out_cached = Buffer.init();
    var base = json_logger(&out_cached);
    var child = base.with(&first).with(&second);

    child.info("m", &.{}, @src());
    out_cached.reset();
    child.info("m", &.{field_mod.int("d", 4)}, @src());

    var out_plain = Buffer.init();
    var plain = json_logger(&out_plain);

    plain.info("m", &.{
        field_mod.int("a", 1),
        field_mod.string("b", "two"),
        field_mod.boolean("c", true),
        field_mod.int("d", 4),
    }, @src());

    try testing.expectEqualSlices(u8, out_plain.contents(), out_cached.contents());

    assert(out_cached.length() == out_plain.length());
}
