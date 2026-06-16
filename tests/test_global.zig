const std = @import("std");
const arc = @import("arc");

const Buffer = arc.buffer_mod.Buffer;
const Clock = arc.Clock;
const Config = arc.Config;
const Level = arc.Level;
const Logger = arc.Logger;

const global = arc.global_mod;

fn make_global_logger(output: *Buffer) Logger {
    var logger = Logger.init_with_config(
        std.testing.io,
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

    std.debug.assert(logger.check(.debug));
    std.debug.assert(logger.context_fields_count == 0);
    return logger;
}

test "global replace and log" {
    var output = Buffer.init();

    var logger = make_global_logger(&output);

    global.replace(std.testing.io, &logger);

    global.l().info("global test", &.{}, @src());

    try std.testing.expect(output.contains("global test"));
    try std.testing.expect(output.contains("info"));

    std.debug.assert(output.contains("global test"));
    std.debug.assert(!output.is_empty());
}

test "global replace preserves previous" {
    var output_a = Buffer.init();
    var output_b = Buffer.init();

    var logger_a = Logger.init_with_config(
        std.testing.io,
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
        std.testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output_b })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    global.replace(std.testing.io, &logger_a);
    global.replace(std.testing.io, &logger_b);

    global.l().info("on b", &.{}, @src());

    try std.testing.expect(output_b.contains("on b"));
    try std.testing.expect(output_a.is_empty());
    try std.testing.expect(global.can_restore(std.testing.io));

    std.debug.assert(output_b.contains("on b"));
    std.debug.assert(output_a.is_empty());
}

test "global restore reverts to previous logger" {
    var output_a = Buffer.init();
    var output_b = Buffer.init();

    var logger_a = Logger.init_with_config(
        std.testing.io,
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
        std.testing.io,
        Config.production()
            .with_level(.err)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output_b })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    global.replace(std.testing.io, &logger_a);
    global.replace(std.testing.io, &logger_b);

    global.l().info("hidden", &.{}, @src());
    try std.testing.expect(output_b.is_empty());

    global.restore(std.testing.io);

    global.l().info("restored", &.{}, @src());

    try std.testing.expect(output_a.contains("restored"));
    try std.testing.expect(!output_a.contains("hidden"));

    std.debug.assert(output_a.contains("restored"));
    std.debug.assert(!global.can_restore(std.testing.io));
}

test "global l returns the caller owned pointer not a copy" {
    var output_a = Buffer.init();
    var output_b = Buffer.init();

    var logger_a = make_global_logger(&output_a);
    var logger_b = make_global_logger(&output_b);

    global.replace(std.testing.io, &logger_a);
    try std.testing.expect(global.l() == &logger_a);
    try std.testing.expect(global.s().logger == &logger_a);

    global.replace(std.testing.io, &logger_b);
    try std.testing.expect(global.l() == &logger_b);

    global.restore(std.testing.io);
    try std.testing.expect(global.l() == &logger_a);

    std.debug.assert(global.l() == &logger_a);
}

test "global l returns pointer to active logger" {
    var output = Buffer.init();
    var logger = make_global_logger(&output);

    global.replace(std.testing.io, &logger);

    const ptr = global.l();

    try std.testing.expect(ptr.check(.debug));
    try std.testing.expect(ptr.check(.info));

    std.debug.assert(ptr.context_fields_count == 0);
    std.debug.assert(ptr.name_length == 0);
}

test "global replace twice then restore once" {
    var output_a = Buffer.init();
    var output_b = Buffer.init();
    var output_c = Buffer.init();

    var logger_a = Logger.init_with_config(
        std.testing.io,
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
        std.testing.io,
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
        std.testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output_c })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    global.replace(std.testing.io, &logger_a);
    global.replace(std.testing.io, &logger_b);
    global.replace(std.testing.io, &logger_c);

    global.l().info("on c", &.{}, @src());
    try std.testing.expect(output_c.contains("on c"));
    try std.testing.expect(output_b.is_empty());
    try std.testing.expect(output_a.is_empty());

    global.restore(std.testing.io);

    global.l().info("on b after restore", &.{}, @src());
    try std.testing.expect(output_b.contains("on b after restore"));

    std.debug.assert(output_b.contains("on b after restore"));
}

test "global logger can be named and used" {
    var output = Buffer.init();
    var logger = make_global_logger(&output);

    global.replace(std.testing.io, &logger);

    var named = global.l().named("global-child");
    named.info("from child", &.{}, @src());

    try std.testing.expect(output.contains("global-child"));
    try std.testing.expect(output.contains("from child"));

    std.debug.assert(output.contains("global-child"));
}

test "global logger with context fields" {
    var output = Buffer.init();
    var logger = make_global_logger(&output);

    global.replace(std.testing.io, &logger);

    var child = global.l().with(&.{
        arc.string("app", "test-suite"),
    });

    child.info("contextual", &.{}, @src());

    try std.testing.expect(output.contains("app"));
    try std.testing.expect(output.contains("test-suite"));
    try std.testing.expect(output.contains("contextual"));

    std.debug.assert(output.contains("test-suite"));
}

test "global logger level change affects subsequent logs" {
    var output = Buffer.init();
    var logger = make_global_logger(&output);

    global.replace(std.testing.io, &logger);

    global.l().info("before", &.{}, @src());
    try std.testing.expect(output.contains("before"));

    output.reset();
    global.l().set_level(.err);

    global.l().info("hidden after level change", &.{}, @src());
    try std.testing.expect(output.is_empty());

    global.l().@"error"("visible after level change", &.{}, @src());
    try std.testing.expect(output.contains("visible after level change"));

    std.debug.assert(output.contains("visible after level change"));
}

test "global sugar returns sugared logger" {
    var output = Buffer.init();
    var logger = make_global_logger(&output);

    global.replace(std.testing.io, &logger);

    const sugared = global.s();

    try std.testing.expect(sugared.logger == global.l());

    std.debug.assert(sugared.logger == global.l());
}

test "global can_restore returns false after restore" {
    var output_a = Buffer.init();
    var output_b = Buffer.init();

    var logger_a = Logger.init_with_config(
        std.testing.io,
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
        std.testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output_b })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    global.replace(std.testing.io, &logger_a);
    global.replace(std.testing.io, &logger_b);

    try std.testing.expect(global.can_restore(std.testing.io));

    global.restore(std.testing.io);

    try std.testing.expect(!global.can_restore(std.testing.io));

    std.debug.assert(!global.can_restore(std.testing.io));
}
