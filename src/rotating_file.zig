const std = @import("std");

const bounded = @import("bounded.zig");

const assert = std.debug.assert;

const Path = bounded.BoundedArrayType(u8, path_bytes_max);

pub const RotatingFile = struct {
    backup_count: u32,
    day: u64,
    failure_count: u64,
    file: ?std.Io.File,
    path: Path,
    roll_daily: bool,
    size: u64,
    size_max: u64,

    pub const CapacityError = error{
        BackupCountTooLarge,
        PathTooLong,
    };

    pub const Error = CapacityError || FileError;

    pub const FileError = error{
        FileOpenFailed,
        FileStatFailed,
    };

    pub const Options = struct {
        backup_count: u32 = 5,
        path: []const u8,
        roll_daily: bool = true,
        size_max: u64 = 5 * 1024 * 1024,
    };

    pub fn init(rotating_file: *RotatingFile, io: std.Io, options: *const Options) Error!void {
        assert(options.path.len > 0);
        assert(options.size_max > 0);

        if (options.path.len > path_bytes_max) return error.PathTooLong;
        if (options.backup_count > backup_count_max) return error.BackupCountTooLarge;

        rotating_file.* = .{
            .backup_count = options.backup_count,
            .day = today(io),
            .failure_count = 0,
            .file = null,
            .path = .empty,
            .roll_daily = options.roll_daily,
            .size = 0,
            .size_max = options.size_max,
        };

        rotating_file.path.push_slice_assume_capacity(options.path);

        try rotating_file.open(io);

        assert(rotating_file.file != null);
    }

    pub fn deinit(rotating_file: *RotatingFile, io: std.Io) void {
        assert(rotating_file.path.count > 0);

        if (rotating_file.file) |file| file.close(io);

        rotating_file.file = null;
    }

    pub fn write(
        rotating_file: *RotatingFile,
        io: std.Io,
        bytes: []const u8,
    ) error{WriteFailed}!void {
        assert(bytes.len > 0);
        assert(rotating_file.path.count > 0);

        if (rotating_file.rotation_due(io)) {
            rotating_file.rotate(io) catch {
                rotating_file.failure_count += 1;

                return error.WriteFailed;
            };
        } else if (rotating_file.file == null) {
            rotating_file.open(io) catch {
                rotating_file.failure_count += 1;

                return error.WriteFailed;
            };
        } else {}

        const file = rotating_file.file orelse return error.WriteFailed;

        file.writePositionalAll(io, bytes, rotating_file.size) catch return error.WriteFailed;
        rotating_file.size += bytes.len;
    }

    pub fn flush(rotating_file: *RotatingFile, io: std.Io) error{WriteFailed}!void {
        assert(rotating_file.path.count > 0);
        assert(rotating_file.size_max > 0);

        const file = rotating_file.file orelse return;

        file.sync(io) catch return error.WriteFailed;
    }

    fn rotation_due(rotating_file: *const RotatingFile, io: std.Io) bool {
        assert(rotating_file.size_max > 0);
        assert(rotating_file.path.count > 0);

        if (rotating_file.size >= rotating_file.size_max) return true;
        if (!rotating_file.roll_daily) return false;
        return today(io) != rotating_file.day;
    }

    fn rotate(rotating_file: *RotatingFile, io: std.Io) FileError!void {
        assert(rotating_file.path.count > 0);
        assert(rotating_file.backup_count <= backup_count_max);

        if (rotating_file.file) |file| file.close(io);

        rotating_file.file = null;

        rotating_file.backups_shift(io);
        rotating_file.size = 0;
        rotating_file.day = today(io);

        try rotating_file.open(io);
    }

    fn backups_shift(rotating_file: *RotatingFile, io: std.Io) void {
        assert(rotating_file.file == null);
        assert(rotating_file.backup_count <= backup_count_max);

        const directory = std.Io.Dir.cwd();
        const path = rotating_file.path.slice();

        var index = rotating_file.backup_count;

        for (0..rotating_file.backup_count) |_| {
            var source_buffer: [path_suffixed_bytes_max]u8 = undefined;
            var target_buffer: [path_suffixed_bytes_max]u8 = undefined;

            const source = if (index == 1) path else suffixed(&source_buffer, path, index - 1);
            const target = suffixed(&target_buffer, path, index);

            if (index == rotating_file.backup_count) {
                directory.deleteFile(io, target) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => rotating_file.failure_count += 1,
                };
            }

            directory.rename(source, directory, target, io) catch |err| switch (err) {
                error.FileNotFound => {},
                else => rotating_file.failure_count += 1,
            };

            index -= 1;
        }

        assert(index == 0);
    }

    fn open(rotating_file: *RotatingFile, io: std.Io) FileError!void {
        assert(rotating_file.file == null);
        assert(rotating_file.path.count > 0);

        const directory = std.Io.Dir.cwd();
        const path = rotating_file.path.slice();

        if (std.Io.Dir.path.dirname(path)) |parent| {
            directory.createDirPath(io, parent) catch return error.FileOpenFailed;
        }

        const file = directory.createFile(io, path, .{
            .exclusive = false,
            .lock = .none,
            .lock_nonblocking = false,
            .permissions = .default_file,
            .read = true,
            .truncate = false,
        }) catch return error.FileOpenFailed;

        errdefer file.close(io);

        const stat = file.stat(io) catch return error.FileStatFailed;

        rotating_file.file = file;
        rotating_file.size = stat.size;
    }
};

pub const backup_count_max: u32 = 9;
pub const path_bytes_max: u32 = 512;
const path_suffixed_bytes_max: u32 = path_bytes_max + 2;

comptime {
    assert(backup_count_max < 10);
    assert(path_bytes_max > 0);
}

fn today(io: std.Io) u64 {
    const timestamp = std.Io.Timestamp.now(io, .real);
    const day = @divFloor(timestamp.nanoseconds, std.time.ns_per_day);

    return std.math.lossyCast(u64, day);
}

fn suffixed(buffer: *[path_suffixed_bytes_max]u8, path: []const u8, index: u32) []const u8 {
    assert(path.len <= path_bytes_max);
    assert(index > 0);
    assert(index <= backup_count_max);

    @memcpy(buffer[0..path.len], path);

    buffer[path.len] = '.';

    buffer[path.len + 1] = '0' + @as(u8, @intCast(index));

    return buffer[0 .. path.len + 2];
}

const testing = std.testing;

const test_bytes_max: u32 = 4096;

fn test_remove(path: []const u8) void {
    assert(path.len > 0);
    assert(path.len <= path_suffixed_bytes_max);

    std.Io.Dir.cwd().deleteFile(testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.panic("failed to remove {s}: {t}", .{ path, err }),
    };
}

fn test_read(path: []const u8, buffer: *[test_bytes_max]u8) ![]const u8 {
    assert(path.len > 0);
    assert(buffer.len == test_bytes_max);

    return std.Io.Dir.cwd().readFile(testing.io, path, buffer);
}

test RotatingFile {
    const path = ".zz_rotating_doctest.tmp";
    defer test_remove(path);

    var rotating_file: RotatingFile = undefined;

    try rotating_file.init(testing.io, &.{
        .backup_count = 3,
        .path = path,
        .roll_daily = false,
        .size_max = 1024,
    });

    defer rotating_file.deinit(testing.io);

    try rotating_file.write(testing.io, "hello\n");
    try rotating_file.write(testing.io, "world\n");
    try rotating_file.flush(testing.io);

    var buffer: [test_bytes_max]u8 = undefined;

    try testing.expectEqualStrings("hello\nworld\n", try test_read(path, &buffer));
    try testing.expectEqual(@as(u64, 12), rotating_file.size);
}

test "a file past its size limit rolls to the first backup" {
    const path = ".zz_rotating_size.tmp";
    defer test_remove(path);

    const backup = ".zz_rotating_size.tmp.1";
    defer test_remove(backup);

    {
        var rotating_file: RotatingFile = undefined;

        try rotating_file.init(testing.io, &.{
            .backup_count = 3,
            .path = path,
            .roll_daily = false,
            .size_max = 8,
        });

        defer rotating_file.deinit(testing.io);

        try rotating_file.write(testing.io, "aaaa\n");
        try rotating_file.write(testing.io, "bbbb\n");
        try rotating_file.write(testing.io, "cccc\n");
    }

    var base_buffer: [test_bytes_max]u8 = undefined;
    var backup_buffer: [test_bytes_max]u8 = undefined;

    try testing.expectEqualStrings("cccc\n", try test_read(path, &base_buffer));
    try testing.expectEqualStrings("aaaa\nbbbb\n", try test_read(backup, &backup_buffer));
}

test "only the backup allowance is kept and the oldest backup is discarded" {
    const path = ".zz_rotating_cap.tmp";
    defer test_remove(path);

    const backups = [_][]const u8{
        ".zz_rotating_cap.tmp.1",
        ".zz_rotating_cap.tmp.2",
        ".zz_rotating_cap.tmp.3",
    };

    defer for (backups) |backup| test_remove(backup);

    {
        var rotating_file: RotatingFile = undefined;

        try rotating_file.init(testing.io, &.{
            .backup_count = 2,
            .path = path,
            .roll_daily = false,
            .size_max = 1,
        });

        defer rotating_file.deinit(testing.io);

        try rotating_file.write(testing.io, "g0\n");
        try rotating_file.write(testing.io, "g1\n");
        try rotating_file.write(testing.io, "g2\n");
        try rotating_file.write(testing.io, "g3\n");

        try testing.expectEqual(@as(u64, 0), rotating_file.failure_count);
    }

    var buffer: [test_bytes_max]u8 = undefined;

    try testing.expectEqualStrings("g3\n", try test_read(path, &buffer));
    try testing.expectEqualStrings("g2\n", try test_read(backups[0], &buffer));
    try testing.expectEqualStrings("g1\n", try test_read(backups[1], &buffer));
    try testing.expectError(error.FileNotFound, test_read(backups[2], &buffer));
}

test "a path or backup count past its bound is refused" {
    const path_long: [path_bytes_max + 1]u8 = @splat('a');

    var rotating_file: RotatingFile = undefined;

    const too_long = rotating_file.init(testing.io, &.{
        .backup_count = 1,
        .path = &path_long,
        .roll_daily = false,
        .size_max = 1,
    });

    const too_many = rotating_file.init(testing.io, &.{
        .backup_count = backup_count_max + 1,
        .path = ".zz_rotating_never.tmp",
        .roll_daily = false,
        .size_max = 1,
    });

    try testing.expectError(error.PathTooLong, too_long);
    try testing.expectError(error.BackupCountTooLarge, too_many);
}

test "a rotation that cannot reopen its file fails the write and retries on the next one" {
    const path = ".zz_rotating_reopen.tmp";

    var rotating_file: RotatingFile = undefined;

    try rotating_file.init(testing.io, &.{
        .backup_count = 0,
        .path = path,
        .roll_daily = false,
        .size_max = 8,
    });

    try rotating_file.write(testing.io, "aaaaaaaaaa\n");
    try testing.expectEqual(@as(u64, 0), rotating_file.failure_count);

    rotating_file.deinit(testing.io);

    try std.Io.Dir.cwd().deleteFile(testing.io, path);
    try std.Io.Dir.cwd().createDir(testing.io, path, .default_dir);

    const refused = rotating_file.write(testing.io, "bbbb\n");

    try testing.expectError(error.WriteFailed, refused);
    try testing.expectEqual(@as(u64, 1), rotating_file.failure_count);

    try std.Io.Dir.cwd().deleteDir(testing.io, path);
    defer test_remove(path);

    try rotating_file.write(testing.io, "cccc\n");
    defer rotating_file.deinit(testing.io);

    var buffer: [test_bytes_max]u8 = undefined;

    try testing.expectEqual(@as(u64, 1), rotating_file.failure_count);
    try testing.expectEqualStrings("cccc\n", try test_read(path, &buffer));
}

test "the current day counts whole days since the epoch" {
    const day_2023: u64 = 19_358;
    const day = today(testing.io);

    try testing.expect(day > day_2023);
    try testing.expect(day < day_2023 * 2);
}
