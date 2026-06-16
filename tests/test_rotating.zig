const std = @import("std");
const arc = @import("arc");

fn read_file(io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(4096));
}

test "rotating writer appends and tracks size without rotating" {
    const io = std.testing.io;
    const path = ".zz_rot_append.tmp";

    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var writer = try arc.RotatingWriter.init(io, .{
            .path = path,
            .size_max = 1024,
            .backup_count = 3,
            .roll_daily = false,
        });
        defer writer.deinit(io);

        try writer.write(io, "hello\n");
        try writer.write(io, "world\n");
    }

    const content = try read_file(io, path);
    defer std.testing.allocator.free(content);

    try std.testing.expectEqualSlices(u8, "hello\nworld\n", content);

    std.debug.assert(content.len == 12);
}

test "rotating writer rotates to backup when size_max exceeded" {
    const io = std.testing.io;
    const path = ".zz_rot_size.tmp";
    const backup_one = ".zz_rot_size.tmp.1";

    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, backup_one) catch {};

    {
        var writer = try arc.RotatingWriter.init(io, .{
            .path = path,
            .size_max = 8,
            .backup_count = 3,
            .roll_daily = false,
        });
        defer writer.deinit(io);

        try writer.write(io, "aaaa\n");
        try writer.write(io, "bbbb\n");
        try writer.write(io, "cccc\n");
    }

    const base = try read_file(io, path);
    defer std.testing.allocator.free(base);

    const rolled = try read_file(io, backup_one);
    defer std.testing.allocator.free(rolled);

    try std.testing.expectEqualSlices(u8, "cccc\n", base);
    try std.testing.expectEqualSlices(u8, "aaaa\nbbbb\n", rolled);

    std.debug.assert(base.len == 5);
}

test "rotating writer caps backups and shifts oldest out" {
    const io = std.testing.io;
    const path = ".zz_rot_cap.tmp";
    const backup_one = ".zz_rot_cap.tmp.1";
    const backup_two = ".zz_rot_cap.tmp.2";
    const backup_three = ".zz_rot_cap.tmp.3";

    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, backup_one) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, backup_two) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, backup_three) catch {};

    {
        var writer = try arc.RotatingWriter.init(io, .{
            .path = path,
            .size_max = 1,
            .backup_count = 2,
            .roll_daily = false,
        });
        defer writer.deinit(io);

        try writer.write(io, "g0\n");
        try writer.write(io, "g1\n");
        try writer.write(io, "g2\n");
        try writer.write(io, "g3\n");
    }

    const base = try read_file(io, path);
    defer std.testing.allocator.free(base);

    const first = try read_file(io, backup_one);
    defer std.testing.allocator.free(first);

    const second = try read_file(io, backup_two);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualSlices(u8, "g3\n", base);
    try std.testing.expectEqualSlices(u8, "g2\n", first);
    try std.testing.expectEqualSlices(u8, "g1\n", second);

    try std.testing.expectError(error.FileNotFound, read_file(io, backup_three));
}

test "rotating writer rejects oversized paths" {
    const io = std.testing.io;

    var long: [arc.rotating_path_max + 1]u8 = undefined;
    @memset(&long, 'a');

    try std.testing.expectError(error.InvalidPath, arc.RotatingWriter.init(io, .{ .path = &long }));
}

test "logger writes encoded entries through rotating writer" {
    const io = std.testing.io;
    const path = ".zz_rot_logger.tmp";

    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var writer = try arc.RotatingWriter.init(io, .{ .path = path, .roll_daily = false });
        defer writer.deinit(io);

        const config = arc.Config.development()
            .without_caller()
            .with_encoder_config(arc.EncoderConfig.development()
                .with_level_encoding(.capital)
                .with_time_encoding(.rfc3339_nano))
            .with_writer(.{ .rotating = &writer });

        var logger = arc.Logger.init_with_config(io, config);
        logger.set_clock(arc.Clock.init_fixed(1));
        defer logger.sync() catch {};

        logger.info("integration message", &.{arc.string("phase", "startup")}, @src());

        try logger.sync();
    }

    const content = try read_file(io, path);
    defer std.testing.allocator.free(content);

    try std.testing.expect(content.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, content, "integration message") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "phase") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, content, 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "1970-01-01T00:00:01.000000000Z") != null);
}
