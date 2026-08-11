const std = @import("std");
const writer_mod = @import("writer.zig");

const assert = std.debug.assert;

const Writer = writer_mod.Writer;
const WriteError = writer_mod.WriteError;

pub const BufferedWriter = struct {
    inner: Writer,
    buffer: [buffered_writer_bytes_max]u8,
    position: u32,
    mutex: std.Io.Mutex,
    thread: ?std.Thread,
    stop_flag: std.atomic.Value(bool),
    flush_interval_ns: u64,
    flush_error_count: std.atomic.Value(u64),

    pub fn init(inner: Writer) BufferedWriter {
        assert(!inner.is_nop());

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
        assert(interval_ns > 0);
        assert(self.thread == null);

        self.flush_interval_ns = interval_ns;
        self.stop_flag.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, flush_loop, .{ self, io });

        assert(self.thread != null);
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

        assert(self.thread == null);
    }

    fn flush_loop(self: *BufferedWriter, io: std.Io) void {
        assert(self.flush_interval_ns > 0);

        while (!self.stop_flag.load(.acquire)) {
            var slept: u64 = 0;

            while (slept < self.flush_interval_ns and !self.stop_flag.load(.acquire)) {
                const step = @min(flush_chunk_ns_max, self.flush_interval_ns - slept);
                const duration = std.Io.Duration.fromNanoseconds(@intCast(step));

                std.Io.sleep(io, duration, .awake) catch {
                    self.stop_flag.store(true, .release);

                    break;
                };

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
        assert(data.len > 0);
        assert(self.is_valid());

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (data.len > buffered_writer_bytes_max) {
            try self.flush_locked(io);
            try self.inner.write(io, data);

            return;
        }

        const data_length: u32 = @intCast(data.len);

        assert(data_length <= buffered_writer_bytes_max);
        assert(self.position <= buffered_writer_bytes_max);

        if (self.position + data_length > buffered_writer_bytes_max) {
            try self.flush_locked(io);
        }

        const new_position = self.position + data_length;

        assert(new_position <= buffered_writer_bytes_max);

        @memcpy(self.buffer[self.position..new_position], data);
        self.position = new_position;

        assert(self.is_valid());
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

        assert(data.len > 0);
        try self.inner.write(io, data);
        self.position = 0;
    }

    pub fn is_valid(self: *const BufferedWriter) bool {
        return self.position <= buffered_writer_bytes_max;
    }

    pub fn pending(self: *const BufferedWriter) u32 {
        return self.position;
    }

    pub fn error_count(self: *const BufferedWriter) u64 {
        return self.flush_error_count.load(.monotonic);
    }
};

const buffered_writer_bytes_max = writer_mod.buffered_writer_bytes_max;

pub const flush_chunk_ns_max: u64 = 50 * 1_000_000;

comptime {
    assert(flush_chunk_ns_max > 0);
}
