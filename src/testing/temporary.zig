const std = @import("std");

const assert = std.debug.assert;

pub fn remove_file(io: std.Io, path: []const u8) void {
    assert(path.len > 0);

    std.Io.Dir.cwd().deleteFile(io, path) catch |delete_error| switch (delete_error) {
        error.FileNotFound => {},
        else => std.debug.panic("failed to remove {s}: {t}", .{ path, delete_error }),
    };
}

pub fn remove_directory(io: std.Io, path: []const u8) void {
    assert(path.len > 0);

    std.Io.Dir.cwd().deleteDir(io, path) catch |delete_error| switch (delete_error) {
        error.FileNotFound => {},
        else => std.debug.panic("failed to remove {s}: {t}", .{ path, delete_error }),
    };
}
