const std = @import("std");
const arc = @import("arc");

const Buffer = arc.buffer_mod.Buffer;
const Clock = arc.Clock;
const Config = arc.Config;
const Logger = arc.Logger;

test "write failure is reported to error output and logging continues" {
    const io = std.testing.io;
    const path = ".zz_error_path.tmp";

    // Create a file, capture its descriptor, then close it so every write through
    // that descriptor fails. No descriptor is opened between the close and the
    // failing writes, so it cannot be reused underneath us.
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch unreachable;
    const stale_fd = file.handle;
    file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var errors = Buffer.init();

    var logger = Logger.init_with_config(
        io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .fd = stale_fd })
            .with_error_output(.{ .buffer = &errors })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    logger.info("first", &.{}, @src());

    try std.testing.expect(errors.contains("arc internal error"));

    const after_first = errors.len();

    logger.info("second", &.{}, @src());

    try std.testing.expect(errors.len() > after_first);

    std.debug.assert(errors.len() > after_first);
}
