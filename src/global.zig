const std = @import("std");
const entry_mod = @import("core/entry.zig");
const sugar_mod = @import("sugar.zig");
const buffer_mod = @import("io/buffer.zig");
const clock_mod = @import("core/clock.zig");
const config_mod = @import("config.zig");
const field_mod = @import("core/field.zig");

const assert = std.debug.assert;

const Logger = @import("logger.zig").Logger;
const SugaredLogger = sugar_mod.SugaredLogger;

var default_logger: Logger = Logger.init_nop();
var current_logger: std.atomic.Value(*Logger) = std.atomic.Value(*Logger).init(&default_logger);
var previous_logger: std.atomic.Value(?*Logger) = std.atomic.Value(?*Logger).init(null);
var global_mutex: std.Io.Mutex = .init;

pub fn replace(io: std.Io, new_logger: *Logger) void {
    assert(new_logger.name_length <= entry_mod.name_bytes_max);

    global_mutex.lockUncancelable(io);
    defer global_mutex.unlock(io);

    const prior = current_logger.load(.acquire);
    previous_logger.store(prior, .release);
    current_logger.store(new_logger, .release);

    assert(current_logger.load(.acquire) == new_logger);
}

pub fn restore(io: std.Io) void {
    global_mutex.lockUncancelable(io);
    defer global_mutex.unlock(io);

    const prior = previous_logger.load(.acquire) orelse @panic("restore requires a prior replace");

    current_logger.store(prior, .release);
    previous_logger.store(null, .release);

    assert(current_logger.load(.acquire) == prior);
    assert(previous_logger.load(.acquire) == null);
}

pub fn can_restore(io: std.Io) bool {
    global_mutex.lockUncancelable(io);
    defer global_mutex.unlock(io);

    return previous_logger.load(.acquire) != null;
}

pub fn logger() *Logger {
    const logger_pointer = current_logger.load(.acquire);

    assert(logger_pointer.name_length <= entry_mod.name_bytes_max);

    return logger_pointer;
}

pub fn sugared() SugaredLogger {
    const logger_pointer = current_logger.load(.acquire);

    assert(logger_pointer.name_length <= entry_mod.name_bytes_max);

    return SugaredLogger.init(logger_pointer);
}

const testing = std.testing;

const Buffer = buffer_mod.Buffer;
const Clock = clock_mod.Clock;
const Config = config_mod.Config;

const global = @This();

fn make_global_logger(output: *Buffer) Logger {
    var active_logger = Logger.init_with_config(
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

    active_logger.set_clock(Clock.init_fixed(1_700_000_000));

    assert(active_logger.check(.debug));
    assert(active_logger.context_fields_count == 0);

    return active_logger;
}

test "replacing the global active_logger sends later calls to it" {
    var output = Buffer.init();

    var active_logger = make_global_logger(&output);

    global.replace(testing.io, &active_logger);

    global.logger().info("global test", &.{}, @src());

    try testing.expect(output.contains("global test"));
    try testing.expect(output.contains("info"));

    assert(output.contains("global test"));
    assert(!output.is_empty());
}

test "replacing the global active_logger keeps the one it displaced" {
    var output_a = Buffer.init();
    var output_b = Buffer.init();

    var logger_a = Logger.init_with_config(
        testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output_a })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    var logger_b = Logger.init_with_config(
        testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output_b })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    global.replace(testing.io, &logger_a);
    global.replace(testing.io, &logger_b);

    global.logger().info("on b", &.{}, @src());

    try testing.expect(output_b.contains("on b"));
    try testing.expect(output_a.is_empty());
    try testing.expect(global.can_restore(testing.io));

    assert(output_b.contains("on b"));
    assert(output_a.is_empty());
}

test "restoring the global active_logger brings back the one it displaced" {
    var output_a = Buffer.init();
    var output_b = Buffer.init();

    var logger_a = Logger.init_with_config(
        testing.io,
        Config.production()
            .with_level(.info)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output_a })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    var logger_b = Logger.init_with_config(
        testing.io,
        Config.production()
            .with_level(.err)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output_b })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    global.replace(testing.io, &logger_a);
    global.replace(testing.io, &logger_b);

    global.logger().info("hidden", &.{}, @src());
    try testing.expect(output_b.is_empty());

    global.restore(testing.io);

    global.logger().info("restored", &.{}, @src());

    try testing.expect(output_a.contains("restored"));
    try testing.expect(!output_a.contains("hidden"));

    assert(output_a.contains("restored"));
    assert(!global.can_restore(testing.io));
}

test "the global accessor returns the caller owned pointer rather than a copy" {
    var output_a = Buffer.init();
    var output_b = Buffer.init();

    var logger_a = make_global_logger(&output_a);
    var logger_b = make_global_logger(&output_b);

    global.replace(testing.io, &logger_a);
    try testing.expect(global.logger() == &logger_a);
    try testing.expect(global.sugared().logger == &logger_a);

    global.replace(testing.io, &logger_b);
    try testing.expect(global.logger() == &logger_b);

    global.restore(testing.io);
    try testing.expect(global.logger() == &logger_a);

    assert(global.logger() == &logger_a);
}

test "the global accessor returns the active_logger currently installed" {
    var output = Buffer.init();
    var active_logger = make_global_logger(&output);

    global.replace(testing.io, &active_logger);

    const ptr = global.logger();

    try testing.expect(ptr.check(.debug));
    try testing.expect(ptr.check(.info));

    assert(ptr.context_fields_count == 0);
    assert(ptr.name_length == 0);
}

test "restoring once after two replacements returns the second active_logger" {
    var output_a = Buffer.init();
    var output_b = Buffer.init();
    var output_c = Buffer.init();

    var logger_a = Logger.init_with_config(
        testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output_a })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    var logger_b = Logger.init_with_config(
        testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output_b })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    var logger_c = Logger.init_with_config(
        testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output_c })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    global.replace(testing.io, &logger_a);
    global.replace(testing.io, &logger_b);
    global.replace(testing.io, &logger_c);

    global.logger().info("on c", &.{}, @src());
    try testing.expect(output_c.contains("on c"));
    try testing.expect(output_b.is_empty());
    try testing.expect(output_a.is_empty());

    global.restore(testing.io);

    global.logger().info("on b after restore", &.{}, @src());
    try testing.expect(output_b.contains("on b after restore"));

    assert(output_b.contains("on b after restore"));
}

test "a named global active_logger carries its name into the output" {
    var output = Buffer.init();
    var active_logger = make_global_logger(&output);

    global.replace(testing.io, &active_logger);

    var named = global.logger().named("global-child");
    named.info("from child", &.{}, @src());

    try testing.expect(output.contains("global-child"));
    try testing.expect(output.contains("from child"));

    assert(output.contains("global-child"));
}

test "a global active_logger with context fields writes them on every call" {
    var output = Buffer.init();
    var active_logger = make_global_logger(&output);

    global.replace(testing.io, &active_logger);

    var child = global.logger().with(&.{
        field_mod.string("app", "test-suite"),
    });

    child.info("contextual", &.{}, @src());

    try testing.expect(output.contains("app"));
    try testing.expect(output.contains("test-suite"));
    try testing.expect(output.contains("contextual"));

    assert(output.contains("test-suite"));
}

test "changing the global active_logger level takes effect on later calls" {
    var output = Buffer.init();
    var active_logger = make_global_logger(&output);

    global.replace(testing.io, &active_logger);

    global.logger().info("before", &.{}, @src());
    try testing.expect(output.contains("before"));

    output.reset();
    global.logger().set_level(.err);

    global.logger().info("hidden after level change", &.{}, @src());
    try testing.expect(output.is_empty());

    global.logger().@"error"("visible after level change", &.{}, @src());
    try testing.expect(output.contains("visible after level change"));

    assert(output.contains("visible after level change"));
}

test "the global sugar accessor wraps the installed active_logger" {
    var output = Buffer.init();
    var active_logger = make_global_logger(&output);

    global.replace(testing.io, &active_logger);

    const sugared_logger = global.sugared();

    try testing.expect(sugared_logger.logger == global.logger());

    assert(sugared_logger.logger == global.logger());
}

test "the global reports nothing left to restore once it has restored" {
    var output_a = Buffer.init();
    var output_b = Buffer.init();

    var logger_a = Logger.init_with_config(
        testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output_a })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    var logger_b = Logger.init_with_config(
        testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output_b })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    global.replace(testing.io, &logger_a);
    global.replace(testing.io, &logger_b);

    try testing.expect(global.can_restore(testing.io));

    global.restore(testing.io);

    try testing.expect(!global.can_restore(testing.io));

    assert(!global.can_restore(testing.io));
}
