const std = @import("std");
const writer_mod = @import("writer.zig");
const config_mod = @import("../config.zig");
const encoder_config_mod = @import("../encoding/config.zig");
const logger_mod = @import("../logger.zig");
const clock_mod = @import("../core/clock.zig");
const field_mod = @import("../core/field.zig");

const assert = std.debug.assert;

const WriteError = writer_mod.WriteError;

pub const RotatingWriter = struct {
    pub const Options = struct {
        path: []const u8,
        size_max: u32 = rotating_size_max_default,
        backup_count: u32 = rotating_backup_count_default,
        roll_daily: bool = true,
    };

    file: ?std.Io.File,
    path: [rotating_path_bytes_max]u8,
    path_length: u32,
    size_current: u32,
    size_max: u32,
    backup_count: u32,
    roll_daily: bool,
    last_date: ?RollDate,
    mutex: std.Io.Mutex,
    rotate_error_count: std.atomic.Value(u64),

    pub fn init(io: std.Io, options: Options) RotatingError!RotatingWriter {
        assert(options.path.len > 0);

        const path_length: u32 = @intCast(options.path.len);

        if (path_length > rotating_path_bytes_max) {
            return error.InvalidPath;
        }

        if (options.backup_count > rotating_backup_count_max) {
            return error.InvalidPath;
        }

        var rotating_writer: RotatingWriter = undefined;
        rotating_writer.file = null;
        rotating_writer.path_length = path_length;
        rotating_writer.size_current = 0;
        rotating_writer.size_max = options.size_max;
        rotating_writer.backup_count = options.backup_count;
        rotating_writer.roll_daily = options.roll_daily;
        rotating_writer.last_date = null;
        rotating_writer.mutex = .init;
        rotating_writer.rotate_error_count = std.atomic.Value(u64).init(0);

        @memcpy(rotating_writer.path[0..path_length], options.path);

        assert(rotating_writer.path_length > 0);
        assert(rotating_writer.path_length <= rotating_path_bytes_max);

        try rotating_writer.open_file(io);
        errdefer rotating_writer.deinit(io);

        rotating_writer.last_date = RollDate.current(io);

        assert(rotating_writer.file != null);

        return rotating_writer;
    }

    pub fn is_valid(self: *const RotatingWriter) bool {
        if (self.path_length == 0) return false;
        if (self.path_length > rotating_path_bytes_max) return false;
        if (self.backup_count > rotating_backup_count_max) return false;

        return true;
    }

    pub fn deinit(self: *RotatingWriter, io: std.Io) void {
        if (self.file) |file| {
            file.close(io);
            self.file = null;
        }

        assert(self.file == null);
    }

    pub fn write(self: *RotatingWriter, io: std.Io, data: []const u8) WriteError!void {
        assert(data.len > 0);
        assert(self.is_valid());

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.maybe_rotate(io) catch return error.WriteFailed;

        const file = self.file orelse return error.WriteFailed;
        const data_length: u32 = @intCast(data.len);

        file.writePositionalAll(io, data, self.size_current) catch return error.WriteFailed;

        self.size_current += data_length;

        assert(self.is_valid());
    }

    pub fn sync(self: *RotatingWriter, io: std.Io) WriteError!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const file = self.file orelse return;

        file.sync(io) catch return error.WriteFailed;
    }

    fn maybe_rotate(self: *RotatingWriter, io: std.Io) RotatingError!void {
        assert(self.is_valid());

        if (!self.should_rotate(io)) {
            return;
        }

        self.rotate(io) catch |rotate_error| {
            _ = self.rotate_error_count.fetchAdd(1, .monotonic);

            return rotate_error;
        };

        assert(self.file != null);
    }

    pub fn error_count(self: *const RotatingWriter) u64 {
        return self.rotate_error_count.load(.monotonic);
    }

    fn should_rotate(self: *const RotatingWriter, io: std.Io) bool {
        assert(self.is_valid());

        if (self.size_current >= self.size_max) {
            return true;
        }

        if (self.roll_daily and self.has_date_changed(io)) {
            return true;
        }

        return false;
    }

    fn has_date_changed(self: *const RotatingWriter, io: std.Io) bool {
        assert(self.roll_daily);

        const today = RollDate.current(io);

        if (self.last_date) |last| {
            return !today.eql(last);
        }

        return false;
    }

    fn rotate(self: *RotatingWriter, io: std.Io) RotatingError!void {
        assert(self.is_valid());

        if (self.file) |file| {
            file.close(io);
            self.file = null;
        }

        self.rotate_backups(io);

        self.size_current = 0;
        self.last_date = RollDate.current(io);

        try self.open_file(io);

        assert(self.file != null);
    }

    fn rotate_backups(self: *RotatingWriter, io: std.Io) void {
        assert(self.is_valid());

        if (self.backup_count == 0) {
            return;
        }

        const directory = std.Io.Dir.cwd();
        const path = self.path_slice();

        var index: u32 = self.backup_count;

        while (index > 0) : (index -= 1) {
            assert(index >= 1);
            assert(index <= self.backup_count);

            var old_path_buffer: [rotating_path_with_suffix_bytes_max]u8 = undefined;
            var new_path_buffer: [rotating_path_with_suffix_bytes_max]u8 = undefined;

            const old_path = if (index == 1)
                path
            else
                path_with_suffix(&old_path_buffer, path, index - 1);

            const new_path = path_with_suffix(&new_path_buffer, path, index);

            if (index == self.backup_count) {
                directory.deleteFile(io, new_path) catch |delete_error| switch (delete_error) {
                    error.FileNotFound => {},
                    else => _ = self.rotate_error_count.fetchAdd(1, .monotonic),
                };
            }

            directory.rename(old_path, directory, new_path, io) catch |failure| switch (failure) {
                error.FileNotFound => {},
                else => _ = self.rotate_error_count.fetchAdd(1, .monotonic),
            };
        }
    }

    fn open_file(self: *RotatingWriter, io: std.Io) RotatingError!void {
        assert(self.path_length > 0);

        const directory = std.Io.Dir.cwd();
        const path = self.path_slice();

        if (std.fs.path.dirname(path)) |parent| {
            directory.createDir(io, parent, .default_dir) catch |failure| switch (failure) {
                error.PathAlreadyExists => {},
                else => return error.FileOpenFailed,
            };
        }

        const options: std.Io.Dir.CreateFileOptions = .{ .read = true, .truncate = false };

        const file = directory.createFile(io, path, options) catch return error.FileOpenFailed;
        errdefer file.close(io);

        const file_stat = file.stat(io) catch {
            return error.StatFailed;
        };

        self.file = file;
        self.size_current = @intCast(file_stat.size);

        assert(self.file != null);
    }

    fn path_with_suffix(
        buffer: *[rotating_path_with_suffix_bytes_max]u8,
        path: []const u8,
        index: u32,
    ) []const u8 {
        assert(path.len > 0);
        assert(path.len <= rotating_path_bytes_max);
        assert(index > 0);
        assert(index <= rotating_backup_count_max);

        @memcpy(buffer[0..path.len], path);

        buffer[path.len] = '.';
        buffer[path.len + 1] = @intCast('0' + index);

        return buffer[0 .. path.len + rotating_suffix_bytes];
    }

    fn path_slice(self: *const RotatingWriter) []const u8 {
        assert(self.is_valid());

        return self.path[0..self.path_length];
    }
};

pub const RotatingError = error{
    InvalidPath,
    FileOpenFailed,
    StatFailed,
};

const RollDate = struct {
    year: u16,
    month: u4,
    day: u5,

    fn current(io: std.Io) RollDate {
        const timestamp = std.Io.Timestamp.now(io, .real).toSeconds();

        return RollDate.from_timestamp(timestamp);
    }

    fn from_timestamp(timestamp: i64) RollDate {
        assert(timestamp >= 0);

        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        return .{
            .year = year_day.year,
            .month = month_day.month.numeric(),
            .day = month_day.day_index + 1,
        };
    }

    fn eql(self: RollDate, other: RollDate) bool {
        if (self.year != other.year) return false;
        if (self.month != other.month) return false;
        if (self.day != other.day) return false;

        return true;
    }
};

pub const rotating_path_bytes_max: u32 = 512;
pub const rotating_backup_count_max: u32 = 9;

const rotating_path_with_suffix_bytes_max: u32 = rotating_path_bytes_max + 8;
const rotating_suffix_bytes: u32 = 2;
const rotating_size_max_default: u32 = 5 * 1024 * 1024;
const rotating_backup_count_default: u32 = 5;

comptime {
    assert(rotating_path_bytes_max > 0);
    assert(rotating_backup_count_max > 0);
    assert(rotating_backup_count_max < 10);
    assert(rotating_suffix_bytes == 2);
    assert(rotating_path_with_suffix_bytes_max >= rotating_path_bytes_max + rotating_suffix_bytes);
    assert(rotating_size_max_default > 0);
    assert(rotating_backup_count_default <= rotating_backup_count_max);
}

const testing = std.testing;

const temporary = @import("../testing/temporary.zig");

fn read_file(io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(4096));
}

test "a rotating writer appends and tracks its size while it stays under the limit" {
    const io = testing.io;
    const path = ".zz_rot_append.tmp";

    defer temporary.remove_file(io, path);

    {
        var writer = try RotatingWriter.init(io, .{
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
    defer testing.allocator.free(content);

    try testing.expectEqualSlices(u8, "hello\nworld\n", content);

    assert(content.len == 12);
}

test "a rotating writer rolls the current file to a backup once it passes its size limit" {
    const io = testing.io;
    const path = ".zz_rot_size.tmp";
    const backup_one = ".zz_rot_size.tmp.1";

    defer temporary.remove_file(io, path);
    defer temporary.remove_file(io, backup_one);

    {
        var writer = try RotatingWriter.init(io, .{
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
    defer testing.allocator.free(base);

    const rolled = try read_file(io, backup_one);
    defer testing.allocator.free(rolled);

    try testing.expectEqualSlices(u8, "cccc\n", base);
    try testing.expectEqualSlices(u8, "aaaa\nbbbb\n", rolled);

    assert(base.len == 5);
}

test "a rotating writer keeps only its backup allowance and discards the oldest" {
    const io = testing.io;
    const path = ".zz_rot_cap.tmp";
    const backup_one = ".zz_rot_cap.tmp.1";
    const backup_two = ".zz_rot_cap.tmp.2";
    const backup_three = ".zz_rot_cap.tmp.3";

    defer temporary.remove_file(io, path);
    defer temporary.remove_file(io, backup_one);
    defer temporary.remove_file(io, backup_two);
    defer temporary.remove_file(io, backup_three);

    {
        var writer = try RotatingWriter.init(io, .{
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
    defer testing.allocator.free(base);

    const first = try read_file(io, backup_one);
    defer testing.allocator.free(first);

    const second = try read_file(io, backup_two);
    defer testing.allocator.free(second);

    try testing.expectEqualSlices(u8, "g3\n", base);
    try testing.expectEqualSlices(u8, "g2\n", first);
    try testing.expectEqualSlices(u8, "g1\n", second);

    try testing.expectError(error.FileNotFound, read_file(io, backup_three));
}

test "a rotating writer refuses a path longer than the limit" {
    const io = testing.io;

    var long: [rotating_path_bytes_max + 1]u8 = undefined;
    @memset(&long, 'a');

    try testing.expectError(error.InvalidPath, RotatingWriter.init(io, .{ .path = &long }));
}

test "a logger writes encoded entries through a rotating writer" {
    const io = testing.io;
    const path = ".zz_rot_logger.tmp";

    defer temporary.remove_file(io, path);

    {
        var writer = try RotatingWriter.init(io, .{ .path = path, .roll_daily = false });
        defer writer.deinit(io);

        const config = config_mod.Config.development()
            .without_caller()
            .with_encoder_config(encoder_config_mod.EncoderConfig.development()
                .with_level_encoding(.capital)
                .with_time_encoding(.rfc3339_nano))
            .with_writer(.{ .rotating = &writer });

        var logger = logger_mod.Logger.init_with_config(io, config);
        logger.set_clock(clock_mod.Clock.init_fixed(1));

        logger.info("integration message", &.{field_mod.string("phase", "startup")}, @src());

        try logger.sync();
    }

    const content = try read_file(io, path);
    defer testing.allocator.free(content);

    try testing.expect(content.len > 0);
    try testing.expect(std.mem.indexOf(u8, content, "integration message") != null);
    try testing.expect(std.mem.indexOf(u8, content, "phase") != null);
    try testing.expect(std.mem.indexOfScalar(u8, content, 0x1b) == null);
    try testing.expect(std.mem.indexOf(u8, content, "1970-01-01T00:00:01.000000000Z") != null);
}

test "a rotating writer reports a rotation that cannot reopen its file" {
    const io = testing.io;
    const path = ".zz_rot_reopen.tmp";

    defer temporary.remove_directory(io, path);

    var writer = try RotatingWriter.init(io, .{
        .path = path,
        .size_max = 8,
        .backup_count = 0,
        .roll_daily = false,
    });

    defer writer.deinit(io);

    try writer.write(io, "aaaaaaaaaa\n");
    try testing.expectEqual(@as(u64, 0), writer.error_count());

    writer.deinit(io);

    try std.Io.Dir.cwd().deleteFile(io, path);
    try std.Io.Dir.cwd().createDir(io, path, .default_dir);

    try testing.expectError(error.WriteFailed, writer.write(io, "bbbb\n"));
    try testing.expectEqual(@as(u64, 1), writer.error_count());

    assert(writer.error_count() == 1);
}
