const std = @import("std");
const arc = @import("arc");

const Buffer = arc.buffer_mod.Buffer;
const Clock = arc.Clock;
const Config = arc.Config;
const Logger = arc.Logger;

fn depth_logger(output: *Buffer) Logger {
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

fn count_byte(text: []const u8, byte: u8) u32 {
    var total: u32 = 0;

    for (text) |character| {
        if (character == byte) total += 1;
    }

    return total;
}

test "dict nesting beyond marshal_depth_max is dropped, output stays balanced" {
    var output = Buffer.init();
    var logger = depth_logger(&output);

    logger.info("nested", &.{
        arc.dict("l1", &.{
            arc.dict("l2", &.{
                arc.dict("l3", &.{
                    arc.dict("l4", &.{
                        arc.dict("l5", &.{
                            arc.dict("l6", &.{
                                arc.dict("l7", &.{
                                    arc.dict("l8", &.{
                                        arc.dict("l9", &.{
                                            arc.dict("l10", &.{
                                                arc.string("deep", "value"),
                                            }),
                                        }),
                                    }),
                                }),
                            }),
                        }),
                    }),
                }),
            }),
        }),
    }, @src());

    const text = output.contents();

    try std.testing.expect(!output.is_empty());
    try std.testing.expectEqual(count_byte(text, '{'), count_byte(text, '}'));
    try std.testing.expectEqual(count_byte(text, '['), count_byte(text, ']'));
    try std.testing.expect(output.contains("l1"));
    try std.testing.expect(!output.contains("l10"));
    try std.testing.expect(!output.contains("deep"));

    std.debug.assert(count_byte(text, '{') == count_byte(text, '}'));
}

test "namespaces beyond namespace_depth_max are dropped, output stays balanced" {
    var output = Buffer.init();
    var logger = depth_logger(&output);

    logger.info("namespaced", &.{
        arc.namespace("n1"),
        arc.namespace("n2"),
        arc.namespace("n3"),
        arc.namespace("n4"),
        arc.namespace("n5"),
        arc.namespace("n6"),
        arc.namespace("n7"),
        arc.namespace("n8"),
        arc.namespace("n9"),
        arc.namespace("n10"),
        arc.string("leaf", "value"),
    }, @src());

    const text = output.contents();

    try std.testing.expect(!output.is_empty());
    try std.testing.expectEqual(count_byte(text, '{'), count_byte(text, '}'));
    try std.testing.expect(output.contains("n1"));

    std.debug.assert(count_byte(text, '{') == count_byte(text, '}'));
}

test "deep nesting never exceeds the buffer" {
    var output = Buffer.init();
    var logger = depth_logger(&output);

    logger.info("nested", &.{
        arc.dict("a", &.{
            arc.dict("b", &.{
                arc.dict("c", &.{
                    arc.dict("d", &.{
                        arc.dict("e", &.{
                            arc.string("leaf", "value"),
                        }),
                    }),
                }),
            }),
        }),
    }, @src());

    try std.testing.expect(output.len() <= arc.buffer_mod.buffer_max);
    try std.testing.expect(output.contains("leaf"));

    std.debug.assert(output.len() <= arc.buffer_mod.buffer_max);
}
