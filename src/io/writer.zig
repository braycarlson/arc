const std = @import("std");
const buffer_mod = @import("buffer.zig");
const buffered_writer_mod = @import("buffered_writer.zig");
const rotating_writer_mod = @import("rotating_writer.zig");

const assert = std.debug.assert;
const posix = std.posix;

const Buffer = buffer_mod.Buffer;
const BufferedWriter = buffered_writer_mod.BufferedWriter;
const RotatingWriter = rotating_writer_mod.RotatingWriter;

pub const Writer = union(enum) {
    stderr: void,
    stdout: void,
    file_descriptor: posix.fd_t,
    buffer: *Buffer,
    nop: void,
    tee: *const Tee,
    locked: *LockedWriter,
    buffered: *BufferedWriter,
    rotating: *RotatingWriter,

    pub fn write(self: Writer, io: std.Io, data: []const u8) WriteError!void {
        assert(data.len > 0);

        switch (self) {
            .stderr => try write_file_descriptor(io, stderr_file_descriptor(), data),
            .stdout => try write_file_descriptor(io, stdout_file_descriptor(), data),
            .file_descriptor => |handle| try write_file_descriptor(io, handle, data),
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
            .file_descriptor => |file_descriptor| {
                file_from_descriptor(file_descriptor).sync(io) catch return error.WriteFailed;
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
            .stderr,
            .stdout,
            .file_descriptor,
            .buffer,
            .tee,
            .locked,
            .buffered,
            .rotating,
            => false,
        };
    }

    pub fn is_terminal(self: Writer, io: std.Io) bool {
        const file_descriptor = self.to_file_descriptor() orelse return false;

        return file_from_descriptor(file_descriptor).isTty(io) catch false;
    }

    pub fn to_file_descriptor(self: Writer) ?posix.fd_t {
        return switch (self) {
            .stderr => stderr_file_descriptor(),
            .stdout => stdout_file_descriptor(),
            .file_descriptor => |file_descriptor| file_descriptor,
            .buffer, .nop, .tee, .locked, .buffered, .rotating => null,
        };
    }
};

pub const WriteError = error{WriteFailed};

pub const Tee = struct {
    writers: [tee_writers_max]SingleWriter,
    writers_count: u32,

    pub fn init(targets: []const SingleWriter) Tee {
        assert(targets.len > 0);

        if (targets.len > tee_writers_max) {
            @panic("writer count exceeds tee_writers_max");
        }

        var tee: Tee = undefined;
        tee.writers_count = @intCast(targets.len);

        for (targets, 0..) |target, index| {
            tee.writers[index] = target;
        }

        return tee;
    }

    pub fn write(self: Tee, io: std.Io, data: []const u8) WriteError!void {
        assert(data.len > 0);
        assert(self.writers_count > 0);

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
        assert(self.writers_count > 0);

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
    file_descriptor: posix.fd_t,
    buffer: *Buffer,
    nop: void,
};

pub const LockedWriter = struct {
    writer: Writer,
    mutex: std.Io.Mutex,

    pub fn init(writer: Writer) LockedWriter {
        assert(!writer.is_nop());

        return .{
            .writer = writer,
            .mutex = .init,
        };
    }

    pub fn write(self: *LockedWriter, io: std.Io, data: []const u8) WriteError!void {
        assert(data.len > 0);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        try self.writer.write(io, data);
    }

    pub fn sync(self: *LockedWriter, io: std.Io) WriteError!void {
        assert(!self.writer.is_nop());

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        try self.writer.sync(io);
    }
};

pub const tee_writers_max: u32 = 4;
pub const buffered_writer_bytes_max: u32 = 4096;

comptime {
    assert(tee_writers_max > 0);
    assert(buffered_writer_bytes_max > 0);
    assert(buffered_writer_bytes_max <= buffer_mod.buffer_bytes_max);
}

fn stderr_file_descriptor() posix.fd_t {
    return std.Io.File.stderr().handle;
}

fn stdout_file_descriptor() posix.fd_t {
    return std.Io.File.stdout().handle;
}

fn file_from_descriptor(file_descriptor: posix.fd_t) std.Io.File {
    return .{ .handle = file_descriptor, .flags = .{ .nonblocking = false } };
}

fn write_single(io: std.Io, single_writer: SingleWriter, data: []const u8) WriteError!void {
    assert(data.len > 0);

    switch (single_writer) {
        .stderr => try write_file_descriptor(io, stderr_file_descriptor(), data),
        .stdout => try write_file_descriptor(io, stdout_file_descriptor(), data),
        .file_descriptor => |file_descriptor| try write_file_descriptor(io, file_descriptor, data),
        .buffer => |buffer| buffer.append_slice(data),
        .nop => {},
    }
}

fn sync_single(io: std.Io, single_writer: SingleWriter) WriteError!void {
    switch (single_writer) {
        .file_descriptor => |file_descriptor| {
            file_from_descriptor(file_descriptor).sync(io) catch return error.WriteFailed;
        },
        .stderr, .stdout, .buffer, .nop => {},
    }
}

fn write_file_descriptor(io: std.Io, handle: posix.fd_t, data: []const u8) WriteError!void {
    assert(data.len > 0);

    const file = file_from_descriptor(handle);

    file.writeStreamingAll(io, data) catch return error.WriteFailed;
}
