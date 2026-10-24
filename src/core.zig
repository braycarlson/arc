const std = @import("std");

const encoding_module = @import("encoding.zig");
const level_module = @import("level.zig");
const logger_module = @import("logger.zig");
const sampler_module = @import("sampler.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const Encoding = encoding_module.Encoding;
const Level = level_module.Level;
const Logger = logger_module.Logger;
const Sampler = sampler_module.Sampler;
const Writer = writer_module.Writer;

pub const Core = struct {
    caller: bool,
    clipped_count: std.atomic.Value(u64),
    clock: Clock,
    error_output: Writer,
    failed_count: std.atomic.Value(u64),
    io: std.Io,
    level: std.atomic.Value(u8),
    level_floor: Level,
    logger: Logger,
    mutexes: [sink_count_max]std.Io.Mutex,
    sampler: Sampler,
    sampling: bool,
    sink_count: u32,
    sinks: [sink_count_max]Sink,
    terminal_development_panic: Terminal,
    terminal_fatal: Terminal,
    thread_safe: bool,
    truncated_count: std.atomic.Value(u64),

    pub const Clock = union(enum) {
        fixed_ns: i64,
        system,

        pub fn now_ns(clock: *const Clock, io: std.Io) i64 {
            switch (clock.*) {
                .fixed_ns => |time_ns| return time_ns,
                .system => {
                    const timestamp = std.Io.Timestamp.now(io, .real);
                    return std.math.lossyCast(i64, timestamp.nanoseconds);
                },
            }
        }
    };

    pub const Options = struct {
        caller: bool = true,
        clock: Clock = .system,
        error_output: Writer = .stderr,
        level: Level = .information,
        sampling: ?Sampler.Options = sampling_production,
        sinks: []const Sink = &.{.production},
        terminal_development_panic: Terminal = .none,
        terminal_fatal: Terminal = .exit,
        thread_safe: bool = true,

        pub const development: Options = .{
            .caller = true,
            .clock = .system,
            .error_output = .stderr,
            .level = .debug,
            .sampling = null,
            .sinks = &.{.development},
            .terminal_development_panic = .panic,
            .terminal_fatal = .exit,
            .thread_safe = false,
        };

        pub const production: Options = .{
            .caller = true,
            .clock = .system,
            .error_output = .stderr,
            .level = .information,
            .sampling = sampling_production,
            .sinks = &.{.production},
            .terminal_development_panic = .none,
            .terminal_fatal = .exit,
            .thread_safe = true,
        };
    };

    pub const Sink = struct {
        encoding: Encoding = .production,
        level: Level = .debug,
        writer: Writer = .stderr,

        pub const development: Sink = .{
            .encoding = .development,
            .level = .debug,
            .writer = .stderr,
        };

        pub const production: Sink = .{
            .encoding = .production,
            .level = .debug,
            .writer = .stderr,
        };
    };

    pub const Terminal = enum {
        exit,
        none,
        panic,
    };

    pub fn init(core: *Core, io: std.Io, options: *const Options) void {
        assert(options.sinks.len > 0);
        assert(options.sinks.len <= sink_count_max);
        assert(options.error_output != .observer);

        core.caller = options.caller;
        core.clipped_count = .init(0);
        core.clock = options.clock;
        core.error_output = options.error_output;
        core.failed_count = .init(0);
        core.io = io;
        core.level = .init(@backingInt(options.level));
        core.level_floor = .fatal;
        core.sampling = options.sampling != null;
        core.sink_count = @intCast(options.sinks.len);
        core.terminal_development_panic = options.terminal_development_panic;
        core.terminal_fatal = options.terminal_fatal;
        core.thread_safe = options.thread_safe;
        core.truncated_count = .init(0);

        for (options.sinks, 0..) |*sink, index| {
            assert(sink.encoding.valid());

            core.sinks[index] = sink.*;
            core.mutexes[index] = .init;

            if (!core.level_floor.enables(sink.level)) core.level_floor = sink.level;
        }

        core.sampler.init(&(options.sampling orelse sampling_production));
        core.logger.init(core);

        assert(core.sink_count == options.sinks.len);
        assert(core.logger.core == core);
    }

    pub fn enabled(core: *const Core, level: Level) bool {
        assert(core.sink_count > 0);
        assert(core.sink_count <= sink_count_max);
        assert(@backingInt(level) <= @backingInt(Level.fatal));

        if (@backingInt(level) >= @backingInt(Level.development_panic)) return true;

        const threshold: Level = @fromBackingInt(core.level.load(.acquire));
        if (!threshold.enables(level)) return false;
        return core.level_floor.enables(level);
    }

    pub fn flush(core: *Core) Writer.Error!void {
        assert(core.sink_count > 0);
        assert(core.sink_count <= sink_count_max);

        var result: Writer.Error!void = {};

        for (core.sinks[0..core.sink_count], core.mutexes[0..core.sink_count]) |*sink, *mutex| {
            if (sink.writer == .observer) continue;

            if (core.thread_safe) mutex.lockUncancelable(core.io);
            defer if (core.thread_safe) mutex.unlock(core.io);

            sink.writer.drain(core.io) catch |err| {
                result = err;
            };
        }

        return result;
    }

    pub fn level_set(core: *Core, level: Level) void {
        assert(core.sink_count > 0);
        assert(core.sink_count <= sink_count_max);
        assert(@backingInt(level) <= @backingInt(Level.fatal));

        core.level.store(@backingInt(level), .release);
    }

    pub fn fragment_encoding(core: *const Core) ?*const Encoding {
        assert(core.sink_count > 0);
        assert(core.sink_count <= sink_count_max);

        if (core.sink_count != 1) return null;

        const sink = &core.sinks[0];
        if (sink.writer == .observer) return null;

        if (sink.encoding.format == .console) {
            if (sink.encoding.console_fields == .key_value) return null;
        }

        return &sink.encoding;
    }
};

pub const sink_count_max: u32 = 4;

const sampling_production: Sampler.Options = .{
    .first = 100,
    .thereafter = 100,
    .tick_ns = std.time.ns_per_s,
};

comptime {
    assert(sink_count_max > 0);
    assert(sampling_production.first > 0);
}

const testing = std.testing;

test Core {
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

    options.clock = .{ .fixed_ns = 1_700_000_000 * std.time.ns_per_s };
    options.caller = false;
    options.sinks = &sinks;

    core.init(testing.io, &options);

    core.logger.information(
        "server starting",
        &.{
            .{ .key = "workers", .value = .{ .integer = 4 } },
        },
        &@src(),
    );

    core.logger.debug("hidden below the information threshold", &.{}, &@src());
    core.level_set(.debug);
    core.logger.debug("shown once the threshold moves", &.{}, &@src());

    try core.flush();

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"server starting\",\"workers\":4}\n" ++
            "{\"level\":\"debug\",\"ts\":1700000000,\"msg\":\"shown once the threshold moves\"}\n",
        stream.buffered(),
    );
}

test "the development preset writes a colored console line and keeps the caller" {
    var bytes: [256]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&bytes);

    const core = try testing.allocator.create(Core);
    defer testing.allocator.destroy(core);

    const sinks = [_]Core.Sink{.{
        .encoding = .development,
        .level = .debug,
        .writer = .{ .stream = &stream },
    }};

    const source: std.lang.SourceLocation = .{
        .module = "arc",
        .file = "src/main.zig",
        .line = 7,
        .column = 1,
        .fn_name = "main",
    };

    var options: Core.Options = .development;

    options.clock = .{ .fixed_ns = 0 };
    options.sinks = &sinks;

    core.init(testing.io, &options);
    core.logger.debug("ready", &.{}, &source);

    try testing.expectEqualStrings(
        "1970-01-01T00:00:00Z\t\x1b[35mDEBUG\x1b[0m\tsrc/main.zig:7\tready\n",
        stream.buffered(),
    );

    try testing.expect(!core.sampling);
    try testing.expectEqual(Core.Terminal.panic, core.terminal_development_panic);
}

test "a production core samples and the threshold is the stricter of core and sinks" {
    const core = try testing.allocator.create(Core);
    defer testing.allocator.destroy(core);

    const sinks = [_]Core.Sink{
        .{ .encoding = .production, .level = .warn, .writer = .discard },
        .{ .encoding = .production, .level = .err, .writer = .discard },
    };

    var options: Core.Options = .production;

    options.sinks = &sinks;

    core.init(testing.io, &options);

    try testing.expect(core.sampling);
    try testing.expectEqual(Level.warn, core.level_floor);
    try testing.expect(!core.enabled(.information));
    try testing.expect(core.enabled(.warn));

    core.level_set(.debug);

    try testing.expect(!core.enabled(.information));
    try testing.expect(core.enabled(.development_panic));
    try testing.expect(core.fragment_encoding() == null);
}

test "a system clock reads an instant after the year 2020" {
    const clock: Core.Clock = .system;
    const year_2020_ns: i64 = 1_577_836_800 * std.time.ns_per_s;

    try testing.expect(clock.now_ns(testing.io) > year_2020_ns);
}

test "a fixed clock keeps its instant until it is moved" {
    var clock: Core.Clock = .{ .fixed_ns = -1 };

    try testing.expectEqual(@as(i64, -1), clock.now_ns(testing.io));

    clock.fixed_ns += 2 * std.time.ns_per_s;

    try testing.expectEqual(@as(i64, 1_999_999_999), clock.now_ns(testing.io));
}
