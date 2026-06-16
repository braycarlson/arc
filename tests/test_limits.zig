const std = @import("std");
const arc = @import("arc");

const Buffer = arc.buffer_mod.Buffer;
const Clock = arc.Clock;
const Config = arc.Config;
const Field = arc.Field;
const Logger = arc.Logger;

fn limits_logger(output: *Buffer) Logger {
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

test "exactly fields_max fields encode to valid json with all present" {
    var output = Buffer.init();
    var logger = limits_logger(&output);

    var fields: [arc.fields_max]Field = undefined;
    var keys: [arc.fields_max][8]u8 = undefined;

    var index: usize = 0;

    while (index < arc.fields_max) : (index += 1) {
        const key = std.fmt.bufPrint(&keys[index], "k{d}", .{index}) catch unreachable;
        fields[index] = arc.int(key, @intCast(index));
    }

    logger.info("max", &fields, @src());

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        std.mem.trimEnd(u8, output.contents(), "\n"),
        .{},
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(output.contains("\"k0\":0"));
    try std.testing.expect(output.contains("\"k31\":31"));

    std.debug.assert(output.contains("\"k31\":31"));
}

test "scopes_max named scopes compose into the logger name" {
    var output = Buffer.init();
    var logger = limits_logger(&output);

    var index: usize = 0;

    while (index < arc.scopes_max) : (index += 1) {
        logger = logger.named("s");
    }

    const expected_length: usize = arc.scopes_max + (arc.scopes_max - 1);

    try std.testing.expectEqual(expected_length, logger.name().len);

    logger.info("named", &.{}, @src());

    try std.testing.expect(output.contains("s.s.s.s.s.s.s.s"));

    std.debug.assert(logger.name().len == expected_length);
}

test "name_max length scope fits" {
    var output = Buffer.init();
    var base = limits_logger(&output);

    var scope: [arc.name_max]u8 = undefined;
    @memset(&scope, 'x');

    const logger = base.named(&scope);

    try std.testing.expectEqual(@as(usize, arc.name_max), logger.name().len);

    std.debug.assert(logger.name().len == arc.name_max);
}
