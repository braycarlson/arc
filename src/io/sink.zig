const std = @import("std");
const writer_mod = @import("writer.zig");

const Writer = writer_mod.Writer;
const SingleWriter = writer_mod.SingleWriter;

pub const SinkError = error{
    OpenFailed,
    InvalidPath,
    PathTooLong,
    InvalidScheme,
    SchemeRegistryFull,
    SchemeExists,
};

pub const path_max: u32 = 256;
pub const schemes_max: u32 = 8;
pub const scheme_max: u32 = 32;
pub const paths_max: u32 = 16;

pub const SinkFactory = *const fn (io: std.Io, target: []const u8) SinkError!Writer;

const SchemeEntry = struct {
    scheme: []const u8,
    factory: SinkFactory,
};

var registry: [schemes_max]SchemeEntry = undefined;
var registry_count: u32 = 0;
var registry_mutex: std.Io.Mutex = .init;

const SchemeSplit = struct {
    scheme: []const u8,
    target: []const u8,
};

pub fn register_sink(io: std.Io, scheme: []const u8, factory: SinkFactory) SinkError!void {
    std.debug.assert(scheme.len > 0);
    std.debug.assert(scheme.len <= scheme_max);

    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);

    if (is_builtin_scheme(scheme)) {
        return error.SchemeExists;
    }

    const active = registry[0..registry_count];

    for (active) |entry| {
        if (std.mem.eql(u8, entry.scheme, scheme)) {
            return error.SchemeExists;
        }
    }

    if (registry_count >= schemes_max) {
        return error.SchemeRegistryFull;
    }

    registry[registry_count] = .{ .scheme = scheme, .factory = factory };
    registry_count += 1;

    std.debug.assert(registry_count <= schemes_max);
}

pub fn open(io: std.Io, path: []const u8) SinkError!Writer {
    std.debug.assert(path.len > 0);

    if (path.len > path_max) {
        return error.PathTooLong;
    }

    if (split_scheme(path)) |split| {
        return open_scheme(io, split.scheme, split.target);
    }

    return open_bare(io, path);
}

pub fn open_all(io: std.Io, paths: []const []const u8, writers_out: []Writer) SinkError!u32 {
    std.debug.assert(paths.len > 0);
    std.debug.assert(paths.len <= paths_max);
    std.debug.assert(paths.len <= writers_out.len);

    var opened: u32 = 0;

    for (paths, 0..) |path, index| {
        std.debug.assert(opened == index);

        writers_out[index] = try open(io, path);
        opened += 1;
    }

    std.debug.assert(opened == paths.len);
    return opened;
}

pub fn to_single_writer(writer: Writer) ?SingleWriter {
    return switch (writer) {
        .stderr => .{ .stderr = {} },
        .stdout => .{ .stdout = {} },
        .fd => |fd| .{ .fd = fd },
        .buffer => |buffer| .{ .buffer = buffer },
        .nop => .{ .nop = {} },
        .tee, .locked, .buffered, .rotating => null,
    };
}

pub fn close(io: std.Io, writer: Writer) void {
    switch (writer) {
        .fd => |fd| {
            const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
            file.close(io);
        },
        .stderr, .stdout, .nop, .buffer, .tee, .locked, .buffered, .rotating => {},
    }
}

fn open_bare(io: std.Io, path: []const u8) SinkError!Writer {
    std.debug.assert(path.len > 0);

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
    std.debug.assert(scheme.len > 0);

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

    const active = registry[0..registry_count];

    for (active) |entry| {
        if (std.mem.eql(u8, entry.scheme, scheme)) {
            return entry.factory(io, target);
        }
    }

    return error.InvalidScheme;
}

fn open_file(io: std.Io, path: []const u8) SinkError!Writer {
    if (path.len == 0) {
        return error.InvalidPath;
    }

    if (std.mem.eql(u8, path, "stdout")) {
        return .{ .stdout = {} };
    }

    if (std.mem.eql(u8, path, "stderr")) {
        return .{ .stderr = {} };
    }

    const file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .read = true }) catch {
        return error.OpenFailed;
    };

    seek_to_end(io, file) catch {
        file.close(io);
        return error.OpenFailed;
    };

    return .{ .fd = file.handle };
}

fn seek_to_end(io: std.Io, file: std.Io.File) !void {
    const file_stat = try file.stat(io);

    if (file_stat.size == 0) {
        return;
    }

    var seek_buffer: [0]u8 = undefined;
    var file_writer = file.writerStreaming(io, &seek_buffer);

    try file_writer.seekTo(file_stat.size);

    std.debug.assert(file_writer.logicalPos() == file_stat.size);
}

fn split_scheme(path: []const u8) ?SchemeSplit {
    const marker = "://";
    const index = std.mem.indexOf(u8, path, marker) orelse return null;

    std.debug.assert(index < path.len);

    const scheme = path[0..index];

    if (scheme.len == 0 or scheme.len > scheme_max) {
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
