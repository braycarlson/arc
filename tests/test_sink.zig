const std = @import("std");
const arc = @import("arc");

const sink = arc.sink_mod;
const Writer = arc.Writer;

fn tag(writer: Writer) std.meta.Tag(Writer) {
    return std.meta.activeTag(writer);
}

fn nop_factory(io: std.Io, target: []const u8) sink.SinkError!Writer {
    _ = io;
    _ = target;
    return .{ .nop = {} };
}

test "open resolves builtin targets" {
    try std.testing.expect(tag(try sink.open(std.testing.io, "stderr")) == .stderr);
    try std.testing.expect(tag(try sink.open(std.testing.io, "stdout")) == .stdout);
    try std.testing.expect(tag(try sink.open(std.testing.io, "nop")) == .nop);
    try std.testing.expect(tag(try sink.open(std.testing.io, "/dev/null")) == .nop);
    try std.testing.expect(tag(try sink.open(std.testing.io, "file://stdout")) == .stdout);

    std.debug.assert(tag(try sink.open(std.testing.io, "stderr")) == .stderr);
}

test "register and open custom scheme" {
    try sink.register_sink(std.testing.io, "memtest", nop_factory);

    const writer = try sink.open(std.testing.io, "memtest://anything");
    try std.testing.expect(tag(writer) == .nop);

    try std.testing.expectError(
        error.SchemeExists,
        sink.register_sink(std.testing.io, "memtest", nop_factory),
    );
    try std.testing.expectError(
        error.SchemeExists,
        sink.register_sink(std.testing.io, "file", nop_factory),
    );
    try std.testing.expectError(
        error.InvalidScheme,
        sink.open(std.testing.io, "bogus://x"),
    );

    std.debug.assert(tag(writer) == .nop);
}

test "open_all opens multiple targets" {
    var writers: [4]Writer = undefined;
    const paths = [_][]const u8{ "stderr", "nop", "stdout" };

    const count = try sink.open_all(std.testing.io, &paths, &writers);

    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expect(tag(writers[0]) == .stderr);
    try std.testing.expect(tag(writers[1]) == .nop);
    try std.testing.expect(tag(writers[2]) == .stdout);

    std.debug.assert(count == 3);
}

test "to_single_writer converts basic writers" {
    var buffer = arc.buffer_mod.Buffer.init();

    try std.testing.expect(sink.to_single_writer(.{ .nop = {} }) != null);
    try std.testing.expect(sink.to_single_writer(.{ .buffer = &buffer }) != null);
    try std.testing.expect(sink.to_single_writer(.{ .stderr = {} }) != null);

    std.debug.assert(sink.to_single_writer(.{ .nop = {} }) != null);
}

test "file sink creates, appends past existing content, and round-trips" {
    const io = std.testing.io;
    const path = ".zz_sink_roundtrip.tmp";

    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

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

    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(content);

    try std.testing.expectEqualSlices(u8, "hello\nworld\n", content);

    std.debug.assert(content.len == 12);
}

test "open rejects oversized paths" {
    var long: [sink.path_max + 1]u8 = undefined;
    @memset(&long, 'a');

    try std.testing.expectError(error.PathTooLong, sink.open(std.testing.io, &long));
}
