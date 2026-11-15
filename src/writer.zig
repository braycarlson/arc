const std = @import("std");

const buffer_module = @import("buffer.zig");
const observer_module = @import("observer.zig");
const rotating_file_module = @import("rotating_file.zig");

const assert = std.debug.assert;

const Observer = observer_module.Observer;
const RotatingFile = rotating_file_module.RotatingFile;

pub const Writer = union(enum) {
    discard,
    file: std.Io.File,
    observer: *Observer,
    rotating_file: *RotatingFile,
    stderr,
    stdout,
    stream: *std.Io.Writer,

    pub const Error = error{WriteFailed};

    pub fn write(writer: *const Writer, io: std.Io, bytes: []const u8) Error!void {
        assert(writer.* != .observer);
        assert(bytes.len > 0);
        assert(bytes.len <= buffer_module.entry_bytes_max);

        switch (writer.*) {
            .discard => {},
            .file => |file| file.writeStreamingAll(io, bytes) catch return error.WriteFailed,
            .observer => unreachable,
            .rotating_file => |rotating_file| try rotating_file.write(io, bytes),
            .stderr => {
                const file = std.Io.File.stderr();

                file.writeStreamingAll(io, bytes) catch return error.WriteFailed;
            },
            .stdout => {
                const file = std.Io.File.stdout();

                file.writeStreamingAll(io, bytes) catch return error.WriteFailed;
            },
            .stream => |stream| stream.writeAll(bytes) catch return error.WriteFailed,
        }
    }

    pub fn drain(writer: *const Writer, io: std.Io) Error!void {
        assert(writer.* != .observer);

        switch (writer.*) {
            .discard, .stderr, .stdout => {},
            .observer => unreachable,
            .file => |file| file.sync(io) catch return error.WriteFailed,
            .rotating_file => |rotating_file| try rotating_file.flush(io),
            .stream => |stream| stream.flush() catch return error.WriteFailed,
        }
    }
};

const testing = std.testing;

fn test_remove(path: []const u8) void {
    assert(path.len > 0);
    assert(path.len <= 64);

    std.Io.Dir.cwd().deleteFile(testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.panic("failed to remove {s}: {t}", .{ path, err }),
    };
}

test Writer {
    var bytes: [64]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&bytes);

    const writer: Writer = .{ .stream = &stream };
    const discard: Writer = .discard;

    try writer.write(testing.io, "first\n");
    try writer.write(testing.io, "second\n");
    try writer.drain(testing.io);
    try discard.write(testing.io, "ignored\n");
    try discard.drain(testing.io);

    try testing.expectEqualStrings("first\nsecond\n", stream.buffered());
}

test "a full stream reports a failed write" {
    var bytes: [4]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&bytes);

    const writer: Writer = .{ .stream = &stream };
    const refused = writer.write(testing.io, "too long");

    try testing.expectError(error.WriteFailed, refused);
    try testing.expectEqualStrings("too ", stream.buffered());
}

test "a file writer appends and drains to disk" {
    const path = ".zz_writer_file.tmp";
    defer test_remove(path);

    const directory = std.Io.Dir.cwd();

    {
        const file = try directory.createFile(testing.io, path, .{
            .exclusive = false,
            .lock = .none,
            .lock_nonblocking = false,
            .permissions = .default_file,
            .read = true,
            .truncate = true,
        });

        defer file.close(testing.io);

        const writer: Writer = .{ .file = file };

        try writer.write(testing.io, "first\n");
        try writer.write(testing.io, "second\n");
        try writer.drain(testing.io);

        try testing.expectEqual(@as(u64, 13), (try file.stat(testing.io)).size);
    }

    var bytes: [64]u8 = undefined;

    const contents = try directory.readFile(testing.io, path, &bytes);

    try testing.expectEqualStrings("first\nsecond\n", contents);
}
