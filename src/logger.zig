const std = @import("std");

const bounded = @import("bounded");
const buffer_module = @import("buffer.zig");
const console = @import("console.zig");
const core_module = @import("core.zig");
const datetime = @import("datetime.zig");
const field_module = @import("field.zig");
const json = @import("json.zig");
const level_module = @import("level.zig");
const record_module = @import("record.zig");

const assert = std.debug.assert;

const Buffer = buffer_module.Buffer;
const Core = core_module.Core;
const Field = field_module.Field;
const Level = level_module.Level;
const Record = record_module.Record;
const SourceLocation = std.lang.SourceLocation;

pub const Logger = struct {
    context: Context,
    core: *Core,
    name: Name,

    pub const Child = struct {
        fields: []const Field = &.{},
        name: []const u8 = "",
    };

    pub fn init(logger: *Logger, core: *Core) void {
        assert(core.sink_count > 0);
        assert(core.sink_count <= core_module.sink_count_max);

        logger.context = .empty;
        logger.core = core;
        logger.name = .empty;
    }

    pub fn child(logger: *const Logger, target: *Logger, options: *const Child) void {
        assert(options.fields.len <= context_field_count_max - logger.context.fields.count);
        assert(options.name.len <= name_bytes_max - logger.name.count);

        if (options.name.len > 0) {
            const separator_count: u32 = if (logger.name.count > 0) 1 else 0;

            assert(logger.name.count + separator_count + options.name.len <= name_bytes_max);
        }

        target.core = logger.core;
        target.name = logger.name;
        target.context.fields = logger.context.fields;

        if (options.name.len > 0) {
            if (target.name.count > 0) target.name.push_slice_assume_capacity(".");

            target.name.push_slice_assume_capacity(options.name);
        }

        for (options.fields) |*field| {
            assert(field.valid());

            target.context.fields.push_slot_assume_capacity().* = field.*;
        }

        target.fragment_build();

        assert(target.name.count >= logger.name.count);
        assert(target.context.fields.count == logger.context.fields.count + options.fields.len);
    }

    pub fn debug(
        logger: *const Logger,
        message: []const u8,
        fields: []const Field,
        source: *const SourceLocation,
    ) void {
        assert(message.len <= field_module.text_bytes_max);
        assert(fields.len <= field_module.field_count_max);

        logger.log(.debug, message, fields, source);
    }

    pub fn information(
        logger: *const Logger,
        message: []const u8,
        fields: []const Field,
        source: *const SourceLocation,
    ) void {
        assert(message.len <= field_module.text_bytes_max);
        assert(fields.len <= field_module.field_count_max);

        logger.log(.information, message, fields, source);
    }

    pub fn warn(
        logger: *const Logger,
        message: []const u8,
        fields: []const Field,
        source: *const SourceLocation,
    ) void {
        assert(message.len <= field_module.text_bytes_max);
        assert(fields.len <= field_module.field_count_max);

        logger.log(.warn, message, fields, source);
    }

    pub fn err(
        logger: *const Logger,
        message: []const u8,
        fields: []const Field,
        source: *const SourceLocation,
    ) void {
        assert(message.len <= field_module.text_bytes_max);
        assert(fields.len <= field_module.field_count_max);

        logger.log(.err, message, fields, source);
    }

    pub fn development_panic(
        logger: *const Logger,
        message: []const u8,
        fields: []const Field,
        source: *const SourceLocation,
    ) void {
        assert(message.len <= field_module.text_bytes_max);
        assert(fields.len <= field_module.field_count_max);

        logger.log(.development_panic, message, fields, source);
    }

    pub fn panic(
        logger: *const Logger,
        message: []const u8,
        fields: []const Field,
        source: *const SourceLocation,
    ) void {
        assert(message.len <= field_module.text_bytes_max);
        assert(fields.len <= field_module.field_count_max);

        logger.log(.panic, message, fields, source);
    }

    pub fn fatal(
        logger: *const Logger,
        message: []const u8,
        fields: []const Field,
        source: *const SourceLocation,
    ) void {
        assert(message.len <= field_module.text_bytes_max);
        assert(fields.len <= field_module.field_count_max);

        logger.log(.fatal, message, fields, source);
    }

    pub fn enabled(logger: *const Logger, level: Level) bool {
        assert(logger.core.sink_count > 0);
        assert(logger.context.fields.count <= context_field_count_max);
        assert(@backingInt(level) <= @backingInt(Level.fatal));

        return logger.core.enabled(level);
    }

    pub fn log(
        logger: *const Logger,
        level: Level,
        message: []const u8,
        fields: []const Field,
        source: *const SourceLocation,
    ) void {
        assert(message.len <= field_module.text_bytes_max);
        assert(fields.len <= field_module.field_count_max);
        assert(@backingInt(level) <= @backingInt(Level.fatal));

        const core = logger.core;
        if (!core.enabled(level)) return;

        const time_ns = core.clock.now_ns(core.io);
        if (!sampled(core, level, message, time_ns)) return;

        const record: Record = .{
            .caller = if (core.caller) Record.Caller.of(source) else null,
            .level = level,
            .message = message,
            .name = logger.name.slice(),
            .time_ns = time_ns,
        };

        const batch: json.Fields = .{
            .call = fields,
            .context = logger.context.fields.slice(),
            .fragment = logger.context.fragment(),
        };

        record_write(core, &record, &batch);
        terminate(core, &record);
    }

    fn fragment_build(logger: *Logger) void {
        assert(logger.context.fields.count <= context_field_count_max);
        assert(logger.core.sink_count > 0);

        logger.context.fragment_bytes = .empty;
        logger.context.fragment_state = null;

        if (logger.context.fields.count == 0) return;

        const encoding = logger.core.fragment_encoding() orelse return;

        var buffer: Buffer = undefined;
        var state: json.State = .empty;

        buffer.reset();
        json.fields_encode(&buffer, encoding, &state, logger.context.fields.slice());

        if (buffer.truncated) return;
        if (buffer.clipped) return;
        if (buffer.count > context_bytes_max) return;

        logger.context.fragment_bytes.push_slice_assume_capacity(buffer.contents());
        logger.context.fragment_state = state;
    }
};

const Context = struct {
    fields: bounded.ArrayType(Field, context_field_count_max),
    fragment_bytes: bounded.ArrayType(u8, context_bytes_max),
    fragment_state: ?json.State,

    const empty: Context = .{ .fields = .empty, .fragment_bytes = .empty, .fragment_state = null };

    fn fragment(context: *const Context) ?json.Fragment {
        assert(context.fields.count <= context_field_count_max);
        assert(context.fragment_bytes.count <= context_bytes_max);

        const state = context.fragment_state orelse return null;
        return .{ .bytes = context.fragment_bytes.slice(), .state = state };
    }
};

const Failure = enum {
    flush,
    write,
};

const Name = bounded.ArrayType(u8, name_bytes_max);
pub const context_bytes_max: u32 = 512;
pub const context_field_count_max: u32 = field_module.field_count_max;
pub const name_bytes_max: u32 = 128;

comptime {
    assert(context_bytes_max <= buffer_module.entry_bytes_max);
    assert(context_field_count_max > 0);
    assert(name_bytes_max > 0);
}

fn sampled(core: *Core, level: Level, message: []const u8, time_ns: i64) bool {
    assert(message.len <= field_module.text_bytes_max);
    assert(core.sink_count > 0);
    assert(@backingInt(level) <= @backingInt(Level.fatal));
    assert(@divFloor(time_ns, std.time.ns_per_s) >= datetime.seconds_min);
    assert(@divFloor(time_ns, std.time.ns_per_s) <= datetime.seconds_max);

    if (!core.sampling) return true;
    if (@backingInt(level) >= @backingInt(Level.development_panic)) return true;
    return core.sampler.sample(level, message, @max(time_ns, 0));
}

fn record_write(core: *Core, record: *const Record, fields: *const json.Fields) void {
    assert(core.sink_count > 0);
    assert(fields.call.len <= field_module.field_count_max);

    for (0..core.sink_count) |index| {
        const sink = &core.sinks[index];
        if (!sink.level.enables(record.level)) continue;

        switch (sink.writer) {
            .observer => |observer| {
                const mutex = &core.mutexes[index];

                if (core.thread_safe) mutex.lockUncancelable(core.io);
                defer if (core.thread_safe) mutex.unlock(core.io);

                observer.observe(record, fields);
            },
            else => sink_write(core, @intCast(index), record, fields),
        }
    }
}

fn sink_write(core: *Core, index: u32, record: *const Record, fields: *const json.Fields) void {
    assert(index < core.sink_count);
    assert(core.sinks[index].writer != .observer);

    const sink = &core.sinks[index];

    var buffer: Buffer = undefined;

    buffer.reset();

    switch (sink.encoding.format) {
        .console => console.record_encode(&buffer, &sink.encoding, record, fields),
        .json => json.record_encode(&buffer, &sink.encoding, record, fields),
    }

    if (buffer.truncated) {
        _ = core.truncated_count.fetchAdd(1, .monotonic);

        switch (sink.encoding.format) {
            .console => console.truncation_encode(&buffer, &sink.encoding, record),
            .json => json.truncation_encode(&buffer, &sink.encoding, record),
        }
    } else if (buffer.clipped) {
        _ = core.clipped_count.fetchAdd(1, .monotonic);
    } else {}

    if (buffer.count == 0) return;

    const mutex = &core.mutexes[index];

    if (core.thread_safe) mutex.lockUncancelable(core.io);
    defer if (core.thread_safe) mutex.unlock(core.io);

    sink.writer.write(core.io, buffer.contents()) catch failure_report(core, .write);
}

fn terminate(core: *Core, record: *const Record) void {
    assert(core.sink_count > 0);
    assert(record.message.len <= field_module.text_bytes_max);

    const terminal: Core.Terminal = switch (record.level) {
        .debug, .information, .warn, .err => return,
        .development_panic => core.terminal_development_panic,
        .panic => .panic,
        .fatal => core.terminal_fatal,
    };

    if (terminal == .none) return;

    core.flush() catch failure_report(core, .flush);

    switch (terminal) {
        .exit => std.process.exit(1),
        .none => unreachable,
        .panic => @panic("fatal log entry"),
    }
}

fn failure_report(core: *Core, failure: Failure) void {
    assert(core.error_output != .observer);
    assert(core.sink_count > 0);

    const message = switch (failure) {
        .flush => "arc internal error: failed to flush before a terminal entry\n",
        .write => "arc internal error: failed to write log entry\n",
    };

    _ = core.failed_count.fetchAdd(1, .monotonic);

    core.error_output.write(core.io, message) catch {
        _ = core.failed_count.fetchAdd(1, .monotonic);
    };
}

const testing = std.testing;

test Logger {
    var bytes: [256]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&bytes);

    const core = try testing.allocator.create(Core);
    defer testing.allocator.destroy(core);

    const sinks = [_]Core.Sink{.{
        .encoding = .production,
        .level = .debug,
        .writer = .{ .stream = &stream },
    }};

    var options: Core.Options = .production;

    options.caller = false;
    options.clock = .{ .fixed_ns = 1_700_000_000 * std.time.ns_per_s };
    options.sinks = &sinks;

    core.init(testing.io, &options);

    var http: Logger = undefined;

    core.logger.child(&http, &.{
        .fields = &.{.{ .key = "route", .value = .{ .string = "/health" } }},
        .name = "http",
    });

    http.warn(
        "slow response",
        &.{
            .{ .key = "elapsed", .value = .{ .duration_ns = 1_500_000_000 } },
        },
        &@src(),
    );

    try testing.expectEqualStrings(
        "{\"level\":\"warn\",\"ts\":1700000000,\"logger\":\"http\",\"msg\":\"slow response\"," ++
            "\"route\":\"/health\",\"elapsed\":1.5}\n",
        stream.buffered(),
    );

    try testing.expect(http.enabled(.information));
    try testing.expect(!http.enabled(.debug));
}
