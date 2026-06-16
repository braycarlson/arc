const std = @import("std");
const buffer_mod = @import("buffer.zig");

const posix = std.posix;
const Buffer = buffer_mod.Buffer;

pub const WriteError = error{WriteFailed};

pub const writers_tee_max: u32 = 4;
pub const buffered_writer_max: u32 = 4096;

fn stderr_fd() posix.fd_t {
    return std.Io.File.stderr().handle;
}

fn stdout_fd() posix.fd_t {
    return std.Io.File.stdout().handle;
}

fn file_for_fd(fd: posix.fd_t) std.Io.File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

pub const Writer = union(enum) {
    stderr: void,
    stdout: void,
    fd: posix.fd_t,
    buffer: *Buffer,
    nop: void,
    tee: *const Tee,
    locked: *LockedWriter,
    buffered: *BufferedWriter,
    rotating: *RotatingWriter,

    pub fn write(self: Writer, io: std.Io, data: []const u8) WriteError!void {
        std.debug.assert(data.len > 0);

        switch (self) {
            .stderr => try write_fd(io, stderr_fd(), data),
            .stdout => try write_fd(io, stdout_fd(), data),
            .fd => |fd| try write_fd(io, fd, data),
            .buffer => |buffer| buffer.append_slice(data),
            .nop => {},
            .tee => |tee| try tee.write(io, data),
            .locked => |locked| try locked.write(io, data),
            .buffered => |buffered| try buffered.write(io, data),
            .rotating => |rotating_writer| try rotating_writer.write(io, data),
        }
    }

    pub fn sync(self: Writer, io: std.Io) WriteError!void {
        switch (self) {
            .fd => |fd| {
                file_for_fd(fd).sync(io) catch return error.WriteFailed;
            },
            .tee => |tee| try tee.sync(io),
            .locked => |locked| try locked.sync(io),
            .buffered => |buffered| try buffered.sync(io),
            .rotating => |rotating_writer| try rotating_writer.sync(io),
            .stderr, .stdout, .buffer, .nop => {},
        }
    }

    pub fn is_nop(self: Writer) bool {
        return switch (self) {
            .nop => true,
            else => false,
        };
    }

    pub fn is_terminal(self: Writer, io: std.Io) bool {
        const fd = self.to_fd() orelse return false;

        return file_for_fd(fd).isTty(io) catch false;
    }

    pub fn to_fd(self: Writer) ?posix.fd_t {
        return switch (self) {
            .stderr => stderr_fd(),
            .stdout => stdout_fd(),
            .fd => |fd| fd,
            .buffer, .nop, .tee, .locked, .buffered, .rotating => null,
        };
    }
};

pub const Tee = struct {
    writers: [writers_tee_max]SingleWriter,
    writers_count: u32,

    pub fn init(targets: []const SingleWriter) Tee {
        std.debug.assert(targets.len > 0);

        if (targets.len > writers_tee_max) {
            @panic("writer count exceeds writers_tee_max");
        }

        var tee: Tee = undefined;
        tee.writers_count = @intCast(targets.len);

        for (targets, 0..) |target, index| {
            tee.writers[index] = target;
        }

        return tee;
    }

    pub fn write(self: Tee, io: std.Io, data: []const u8) WriteError!void {
        std.debug.assert(data.len > 0);
        std.debug.assert(self.writers_count > 0);

        var first_error: ?WriteError = null;
        const active = self.writers[0..self.writers_count];

        for (active) |single_writer| {
            write_single(io, single_writer, data) catch |err| {
                if (first_error == null) {
                    first_error = err;
                }
            };
        }

        if (first_error) |err| {
            return err;
        }
    }

    pub fn sync(self: Tee, io: std.Io) WriteError!void {
        std.debug.assert(self.writers_count > 0);

        var first_error: ?WriteError = null;
        const active = self.writers[0..self.writers_count];

        for (active) |single_writer| {
            sync_single(io, single_writer) catch |err| {
                if (first_error == null) {
                    first_error = err;
                }
            };
        }

        if (first_error) |err| {
            return err;
        }
    }
};

pub const SingleWriter = union(enum) {
    stderr: void,
    stdout: void,
    fd: posix.fd_t,
    buffer: *Buffer,
    nop: void,
};

pub const LockedWriter = struct {
    writer: Writer,
    mutex: std.Io.Mutex,

    pub fn init(writer: Writer) LockedWriter {
        std.debug.assert(!writer.is_nop());

        return .{
            .writer = writer,
            .mutex = .init,
        };
    }

    pub fn write(self: *LockedWriter, io: std.Io, data: []const u8) WriteError!void {
        std.debug.assert(data.len > 0);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        try self.writer.write(io, data);
    }

    pub fn sync(self: *LockedWriter, io: std.Io) WriteError!void {
        std.debug.assert(!self.writer.is_nop());

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        try self.writer.sync(io);
    }
};

pub const flush_chunk_ns_max: u64 = 50 * 1_000_000;

pub const BufferedWriter = struct {
    inner: Writer,
    buffer: [buffered_writer_max]u8,
    position: u32,
    mutex: std.Io.Mutex,
    thread: ?std.Thread,
    stop_flag: std.atomic.Value(bool),
    flush_interval_ns: u64,
    flush_error_count: std.atomic.Value(u64),

    pub fn init(inner: Writer) BufferedWriter {
        std.debug.assert(!inner.is_nop());

        var buffered_writer: BufferedWriter = undefined;
        buffered_writer.inner = inner;
        buffered_writer.position = 0;
        buffered_writer.mutex = .init;
        buffered_writer.thread = null;
        buffered_writer.stop_flag = std.atomic.Value(bool).init(false);
        buffered_writer.flush_interval_ns = 0;
        buffered_writer.flush_error_count = std.atomic.Value(u64).init(0);

        return buffered_writer;
    }

    pub fn start_flusher(
        self: *BufferedWriter,
        io: std.Io,
        interval_ns: u64,
    ) std.Thread.SpawnError!void {
        std.debug.assert(interval_ns > 0);
        std.debug.assert(self.thread == null);

        self.flush_interval_ns = interval_ns;
        self.stop_flag.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, flush_loop, .{ self, io });

        std.debug.assert(self.thread != null);
    }

    pub fn stop_flusher(self: *BufferedWriter, io: std.Io) void {
        if (self.thread) |thread| {
            self.stop_flag.store(true, .release);
            thread.join();
            self.thread = null;

            self.flush(io) catch {
                _ = self.flush_error_count.fetchAdd(1, .monotonic);
            };
        }

        std.debug.assert(self.thread == null);
    }

    fn flush_loop(self: *BufferedWriter, io: std.Io) void {
        std.debug.assert(self.flush_interval_ns > 0);

        while (!self.stop_flag.load(.acquire)) {
            var slept: u64 = 0;

            while (slept < self.flush_interval_ns and !self.stop_flag.load(.acquire)) {
                const step = @min(flush_chunk_ns_max, self.flush_interval_ns - slept);
                std.Io.sleep(io, std.Io.Duration.fromNanoseconds(@intCast(step)), .awake) catch {};
                slept += step;
            }

            if (self.stop_flag.load(.acquire)) {
                break;
            }

            self.flush(io) catch {
                _ = self.flush_error_count.fetchAdd(1, .monotonic);
            };
        }
    }

    pub fn write(self: *BufferedWriter, io: std.Io, data: []const u8) WriteError!void {
        std.debug.assert(data.len > 0);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.position + @as(u32, @intCast(data.len)) > buffered_writer_max) {
            try self.flush_locked(io);
        }

        if (data.len > buffered_writer_max) {
            try self.inner.write(io, data);
            return;
        }

        const data_length: u32 = @intCast(data.len);
        const new_position = self.position + data_length;

        std.debug.assert(new_position <= buffered_writer_max);

        @memcpy(self.buffer[self.position..new_position], data);
        self.position = new_position;
    }

    pub fn flush(self: *BufferedWriter, io: std.Io) WriteError!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        try self.flush_locked(io);
    }

    pub fn sync(self: *BufferedWriter, io: std.Io) WriteError!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        try self.flush_locked(io);
        try self.inner.sync(io);
    }

    fn flush_locked(self: *BufferedWriter, io: std.Io) WriteError!void {
        if (self.position == 0) {
            return;
        }

        const data = self.buffer[0..self.position];

        std.debug.assert(data.len > 0);
        try self.inner.write(io, data);
        self.position = 0;
    }

    pub fn pending(self: *const BufferedWriter) u32 {
        return self.position;
    }

    pub fn error_count(self: *const BufferedWriter) u64 {
        return self.flush_error_count.load(.monotonic);
    }
};

pub const rotating_path_max: u32 = 512;
pub const rotating_backup_count_max: u32 = 9;

const rotating_path_with_suffix_max: u32 = rotating_path_max + 8;
const rotating_size_max_default: u32 = 5 * 1024 * 1024;
const rotating_backup_count_default: u32 = 5;

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
        std.debug.assert(timestamp >= 0);

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
        return self.year == other.year and self.month == other.month and self.day == other.day;
    }
};

pub const RotatingWriter = struct {
    pub const Options = struct {
        path: []const u8,
        size_max: u32 = rotating_size_max_default,
        backup_count: u32 = rotating_backup_count_default,
        roll_daily: bool = true,
    };

    file: ?std.Io.File,
    path: [rotating_path_max]u8,
    path_length: u32,
    current_size: u32,
    size_max: u32,
    backup_count: u32,
    roll_daily: bool,
    last_date: ?RollDate,
    mutex: std.Io.Mutex,

    pub fn init(io: std.Io, options: Options) RotatingError!RotatingWriter {
        std.debug.assert(options.path.len > 0);

        const path_length: u32 = @intCast(options.path.len);

        if (path_length > rotating_path_max) {
            return error.InvalidPath;
        }

        if (options.backup_count > rotating_backup_count_max) {
            return error.InvalidPath;
        }

        var rotating_writer: RotatingWriter = undefined;
        rotating_writer.file = null;
        rotating_writer.path_length = path_length;
        rotating_writer.current_size = 0;
        rotating_writer.size_max = options.size_max;
        rotating_writer.backup_count = options.backup_count;
        rotating_writer.roll_daily = options.roll_daily;
        rotating_writer.last_date = null;
        rotating_writer.mutex = .init;

        @memcpy(rotating_writer.path[0..path_length], options.path);

        std.debug.assert(rotating_writer.path_length > 0);
        std.debug.assert(rotating_writer.path_length <= rotating_path_max);

        try rotating_writer.open_file(io);

        rotating_writer.last_date = RollDate.current(io);

        std.debug.assert(rotating_writer.file != null);
        return rotating_writer;
    }

    pub fn deinit(self: *RotatingWriter, io: std.Io) void {
        if (self.file) |file| {
            file.close(io);
            self.file = null;
        }

        std.debug.assert(self.file == null);
    }

    pub fn write(self: *RotatingWriter, io: std.Io, data: []const u8) WriteError!void {
        std.debug.assert(data.len > 0);
        std.debug.assert(self.path_length > 0);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.maybe_rotate(io);

        const file = self.file orelse return error.WriteFailed;
        const data_length: u32 = @intCast(data.len);

        file.writePositionalAll(io, data, self.current_size) catch return error.WriteFailed;

        self.current_size += data_length;

        std.debug.assert(self.current_size >= data_length);
    }

    pub fn sync(self: *RotatingWriter, io: std.Io) WriteError!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const file = self.file orelse return;

        file.sync(io) catch return error.WriteFailed;
    }

    fn maybe_rotate(self: *RotatingWriter, io: std.Io) void {
        if (!self.should_rotate(io)) {
            return;
        }

        self.rotate(io) catch {};
    }

    fn should_rotate(self: *const RotatingWriter, io: std.Io) bool {
        if (self.current_size >= self.size_max) {
            return true;
        }

        if (self.roll_daily and self.has_date_changed(io)) {
            return true;
        }

        return false;
    }

    fn has_date_changed(self: *const RotatingWriter, io: std.Io) bool {
        const today = RollDate.current(io);

        if (self.last_date) |last| {
            return !today.eql(last);
        }

        return false;
    }

    fn rotate(self: *RotatingWriter, io: std.Io) RotatingError!void {
        std.debug.assert(self.path_length > 0);

        if (self.file) |file| {
            file.close(io);
            self.file = null;
        }

        self.rotate_backups(io);

        self.current_size = 0;
        self.last_date = RollDate.current(io);

        try self.open_file(io);

        std.debug.assert(self.file != null);
    }

    fn rotate_backups(self: *const RotatingWriter, io: std.Io) void {
        std.debug.assert(self.path_length > 0);
        std.debug.assert(self.backup_count <= rotating_backup_count_max);

        if (self.backup_count == 0) {
            return;
        }

        const directory = std.Io.Dir.cwd();
        const path = self.path_slice();

        var index: u32 = self.backup_count;

        while (index > 0) : (index -= 1) {
            std.debug.assert(index >= 1);
            std.debug.assert(index <= self.backup_count);

            var old_path_buffer: [rotating_path_with_suffix_max]u8 = undefined;
            var new_path_buffer: [rotating_path_with_suffix_max]u8 = undefined;

            const old_path = if (index == 1)
                path
            else
                std.fmt.bufPrint(&old_path_buffer, "{s}.{d}", .{ path, index - 1 }) catch continue;

            const new_path = std.fmt.bufPrint(&new_path_buffer, "{s}.{d}", .{ path, index }) catch continue;

            if (index == self.backup_count) {
                directory.deleteFile(io, new_path) catch {};
            }

            directory.rename(old_path, directory, new_path, io) catch {};
        }
    }

    fn open_file(self: *RotatingWriter, io: std.Io) RotatingError!void {
        std.debug.assert(self.path_length > 0);

        const directory = std.Io.Dir.cwd();
        const path = self.path_slice();

        if (std.fs.path.dirname(path)) |parent| {
            directory.createDir(io, parent, .default_dir) catch {};
        }

        self.file = directory.createFile(io, path, .{ .read = true, .truncate = false }) catch {
            return error.FileOpenFailed;
        };

        const file_stat = (self.file.?).stat(io) catch {
            return error.StatFailed;
        };

        self.current_size = @intCast(file_stat.size);

        std.debug.assert(self.file != null);
    }

    fn path_slice(self: *const RotatingWriter) []const u8 {
        std.debug.assert(self.path_length > 0);
        std.debug.assert(self.path_length <= rotating_path_max);

        return self.path[0..self.path_length];
    }
};

fn write_single(io: std.Io, single_writer: SingleWriter, data: []const u8) WriteError!void {
    std.debug.assert(data.len > 0);

    switch (single_writer) {
        .stderr => try write_fd(io, stderr_fd(), data),
        .stdout => try write_fd(io, stdout_fd(), data),
        .fd => |fd| try write_fd(io, fd, data),
        .buffer => |buffer| buffer.append_slice(data),
        .nop => {},
    }
}

fn sync_single(io: std.Io, single_writer: SingleWriter) WriteError!void {
    switch (single_writer) {
        .fd => |fd| {
            file_for_fd(fd).sync(io) catch return error.WriteFailed;
        },
        .stderr, .stdout, .buffer, .nop => {},
    }
}

fn write_fd(io: std.Io, fd: posix.fd_t, data: []const u8) WriteError!void {
    std.debug.assert(data.len > 0);

    file_for_fd(fd).writeStreamingAll(io, data) catch return error.WriteFailed;
}
