const std = @import("std");
const writer_mod = @import("writer.zig");
const buffer_mod = @import("buffer.zig");

const assert = std.debug.assert;

const Writer = writer_mod.Writer;
const SingleWriter = writer_mod.SingleWriter;

pub const SinkFactory = *const fn (io: std.Io, target: []const u8) SinkError!Writer;

pub const SinkError = error{
    OpenFailed,
    InvalidPath,
    PathTooLong,
    InvalidScheme,
    SchemeRegistryFull,
    SchemeExists,
};

const SchemeEntry = struct {
    scheme: []const u8,
    factory: SinkFactory,
};

const SchemeSplit = struct {
    scheme: []const u8,
    target: []const u8,
};

pub const path_bytes_max: u32 = 256;
pub const schemes_count_max: u32 = 8;
pub const scheme_bytes_max: u32 = 32;
pub const paths_count_max: u32 = 16;

comptime {
    assert(path_bytes_max > 0);
    assert(schemes_count_max > 0);
    assert(scheme_bytes_max > 0);
    assert(scheme_bytes_max < path_bytes_max);
    assert(paths_count_max > 0);
}

var registry: [schemes_count_max]SchemeEntry = undefined;
var registry_count: u32 = 0;
var registry_mutex: std.Io.Mutex = .init;

fn registry_is_valid() bool {
    return registry_count <= schemes_count_max;
}

fn registry_active() []const SchemeEntry {
    assert(registry_is_valid());

    return registry[0..registry_count];
}

pub fn register_sink(io: std.Io, scheme: []const u8, factory: SinkFactory) SinkError!void {
    assert(scheme.len > 0);
    assert(scheme.len <= scheme_bytes_max);

    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);

    assert(registry_is_valid());

    if (is_builtin_scheme(scheme)) {
        return error.SchemeExists;
    }

    for (registry_active()) |entry| {
        if (std.mem.eql(u8, entry.scheme, scheme)) {
            return error.SchemeExists;
        }
    }

    if (registry_count >= schemes_count_max) {
        return error.SchemeRegistryFull;
    }

    registry[registry_count] = .{ .scheme = scheme, .factory = factory };
    registry_count += 1;

    assert(registry_is_valid());
}

pub fn open(io: std.Io, path: []const u8) SinkError!Writer {
    assert(path.len > 0);

    if (path.len > path_bytes_max) {
        return error.PathTooLong;
    }

    if (split_scheme(path)) |split| {
        return open_scheme(io, split.scheme, split.target);
    }

    return open_bare(io, path);
}

pub fn open_all(io: std.Io, paths: []const []const u8, writers_out: []Writer) SinkError!u32 {
    assert(paths.len > 0);
    assert(paths.len <= paths_count_max);
    assert(paths.len <= writers_out.len);

    var opened: u32 = 0;

    for (paths, 0..) |path, index| {
        writers_out[index] = try open(io, path);
        opened += 1;
    }

    assert(opened == paths.len);

    return opened;
}

pub fn to_single_writer(writer: Writer) ?SingleWriter {
    return switch (writer) {
        .stderr => .{ .stderr = {} },
        .stdout => .{ .stdout = {} },
        .file_descriptor => |file_descriptor| .{ .file_descriptor = file_descriptor },
        .buffer => |buffer| .{ .buffer = buffer },
        .nop => .{ .nop = {} },
        .tee, .locked, .buffered, .rotating => null,
    };
}

pub fn close(io: std.Io, writer: Writer) void {
    switch (writer) {
        .file_descriptor => |file_descriptor| {
            const file = std.Io.File{
                .handle = file_descriptor,
                .flags = .{ .nonblocking = false },
            };

            file.close(io);
        },
        .stderr, .stdout, .nop, .buffer, .tee, .locked, .buffered, .rotating => {},
    }
}

fn open_bare(io: std.Io, path: []const u8) SinkError!Writer {
    assert(path.len > 0);

    if (std.mem.eql(u8, path, "stderr")) {
        return .{ .stderr = {} };
    }

    if (std.mem.eql(u8, path, "stdout")) {
        return .{ .stdout = {} };
    }

    if (std.mem.eql(u8, path, "nop") or std.mem.eql(u8, path, "/dev/null")) {
        return .{ .nop = {} };
    }

    return open_file(io, path);
}

fn open_scheme(io: std.Io, scheme: []const u8, target: []const u8) SinkError!Writer {
    assert(scheme.len > 0);

    if (std.mem.eql(u8, scheme, "file")) {
        return open_file(io, target);
    }

    if (std.mem.eql(u8, scheme, "stdout")) {
        return .{ .stdout = {} };
    }

    if (std.mem.eql(u8, scheme, "stderr")) {
        return .{ .stderr = {} };
    }

    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);

    assert(registry_is_valid());

    for (registry_active()) |entry| {
        if (std.mem.eql(u8, entry.scheme, scheme)) {
            return entry.factory(io, target);
        }
    }

    return error.InvalidScheme;
}

fn open_file(io: std.Io, path: []const u8) SinkError!Writer {
    assert(path.len <= path_bytes_max);

    if (path.len == 0) {
        return error.InvalidPath;
    }

    if (std.mem.eql(u8, path, "stdout")) {
        return .{ .stdout = {} };
    }

    if (std.mem.eql(u8, path, "stderr")) {
        return .{ .stderr = {} };
    }

    const directory = std.Io.Dir.cwd();
    const options: std.Io.Dir.CreateFileOptions = .{ .truncate = false, .read = true };

    const file = directory.createFile(io, path, options) catch return error.OpenFailed;
    errdefer file.close(io);

    seek_to_end(io, file) catch {
        return error.OpenFailed;
    };

    return .{ .file_descriptor = file.handle };
}

fn seek_to_end(io: std.Io, file: std.Io.File) !void {
    const file_stat = try file.stat(io);

    if (file_stat.size == 0) {
        return;
    }

    var seek_buffer: [0]u8 = undefined;
    var file_writer = file.writerStreaming(io, &seek_buffer);

    try file_writer.seekTo(file_stat.size);

    assert(file_writer.logicalPos() == file_stat.size);
}

fn split_scheme(path: []const u8) ?SchemeSplit {
    const marker = "://";
    const index = std.mem.indexOf(u8, path, marker) orelse return null;

    assert(index < path.len);

    const scheme = path[0..index];

    if (scheme.len == 0 or scheme.len > scheme_bytes_max) {
        return null;
    }

    return .{
        .scheme = scheme,
        .target = path[index + marker.len ..],
    };
}

fn is_builtin_scheme(scheme: []const u8) bool {
    return std.mem.eql(u8, scheme, "file") or
        std.mem.eql(u8, scheme, "stdout") or
        std.mem.eql(u8, scheme, "stderr");
}

const testing = std.testing;

const temporary = @import("../testing/temporary.zig");

const sink = @This();

fn tag(writer: Writer) std.meta.Tag(Writer) {
    return std.meta.activeTag(writer);
}

fn nop_factory(io: std.Io, target: []const u8) sink.SinkError!Writer {
    _ = io;
    _ = target;
    return .{ .nop = {} };
}

test "opening a builtin target name yields the matching writer" {
    try testing.expect(tag(try sink.open(testing.io, "stderr")) == .stderr);
    try testing.expect(tag(try sink.open(testing.io, "stdout")) == .stdout);
    try testing.expect(tag(try sink.open(testing.io, "nop")) == .nop);
    try testing.expect(tag(try sink.open(testing.io, "/dev/null")) == .nop);
    try testing.expect(tag(try sink.open(testing.io, "file://stdout")) == .stdout);

    assert(tag(try sink.open(testing.io, "stderr")) == .stderr);
}

test "a registered scheme opens through its own factory and cannot be registered twice" {
    try sink.register_sink(testing.io, "memtest", nop_factory);

    const writer = try sink.open(testing.io, "memtest://anything");

    try testing.expect(tag(writer) == .nop);

    try testing.expectError(
        error.SchemeExists,
        sink.register_sink(testing.io, "memtest", nop_factory),
    );

    try testing.expectError(
        error.SchemeExists,
        sink.register_sink(testing.io, "file", nop_factory),
    );

    try testing.expectError(
        error.InvalidScheme,
        sink.open(testing.io, "bogus://x"),
    );

    assert(tag(writer) == .nop);
}

test "opening many targets fills the writer slice in order" {
    var writers: [4]Writer = undefined;
    const paths = [_][]const u8{ "stderr", "nop", "stdout" };

    const count = try sink.open_all(testing.io, &paths, &writers);

    try testing.expectEqual(@as(u32, 3), count);
    try testing.expect(tag(writers[0]) == .stderr);
    try testing.expect(tag(writers[1]) == .nop);
    try testing.expect(tag(writers[2]) == .stdout);

    assert(count == 3);
}

test "a basic writer converts to a single writer and a composite one does not" {
    var buffer = buffer_mod.Buffer.init();

    try testing.expect(sink.to_single_writer(.{ .nop = {} }) != null);
    try testing.expect(sink.to_single_writer(.{ .buffer = &buffer }) != null);
    try testing.expect(sink.to_single_writer(.{ .stderr = {} }) != null);

    assert(sink.to_single_writer(.{ .nop = {} }) != null);
}

test "a file sink creates its file, appends past existing content, and reads back" {
    const io = testing.io;
    const path = ".zz_sink_roundtrip.tmp";

    defer temporary.remove_file(io, path);

    {
        const writer = try sink.open(io, path);
        defer sink.close(io, writer);

        try writer.write(io, "hello\n");
    }

    {
        const writer = try sink.open(io, path);
        defer sink.close(io, writer);

        try writer.write(io, "world\n");
    }

    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(4096));
    defer testing.allocator.free(content);

    try testing.expectEqualSlices(u8, "hello\nworld\n", content);

    assert(content.len == 12);
}

test "opening a path longer than the limit is refused" {
    var long: [sink.path_bytes_max + 1]u8 = undefined;
    @memset(&long, 'a');

    try testing.expectError(error.PathTooLong, sink.open(testing.io, &long));
}
