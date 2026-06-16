const std = @import("std");
const arc = @import("arc");

const Buffer = arc.buffer_mod.Buffer;
const Clock = arc.Clock;
const Config = arc.Config;
const Field = arc.Field;
const Logger = arc.Logger;

fn json_logger(output: *Buffer) Logger {
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

    return logger;
}

test "pre-encoded context equals the same fields passed at the call site" {
    const context = [_]Field{
        arc.int("a", 1),
        arc.string("b", "x"),
        arc.namespace("ns"),
        arc.int("c", 3),
    };
    const call = [_]Field{
        arc.int("d", 4),
        arc.boolean("e", true),
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

    try std.testing.expectEqualSlices(u8, out_plain.contents(), out_cached.contents());

    std.debug.assert(out_cached.len() == out_plain.len());
}

test "chained with rebuilds the cache and reuse stays correct" {
    const first = [_]Field{arc.int("a", 1)};
    const second = [_]Field{ arc.string("b", "two"), arc.boolean("c", true) };

    var out_cached = Buffer.init();
    var base = json_logger(&out_cached);
    var child = base.with(&first).with(&second);

    child.info("m", &.{}, @src());
    out_cached.reset();
    child.info("m", &.{arc.int("d", 4)}, @src());

    var out_plain = Buffer.init();
    var plain = json_logger(&out_plain);

    plain.info("m", &.{
        arc.int("a", 1),
        arc.string("b", "two"),
        arc.boolean("c", true),
        arc.int("d", 4),
    }, @src());

    try std.testing.expectEqualSlices(u8, out_plain.contents(), out_cached.contents());

    std.debug.assert(out_cached.len() == out_plain.len());
}
