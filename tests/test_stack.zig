const std = @import("std");
const arc = @import("arc");

const Buffer = arc.buffer_mod.Buffer;
const StackTrace = arc.stack_mod.StackTrace;

fn capture_here() StackTrace {
    return StackTrace.capture(@returnAddress());
}

test "stack capture returns at least one frame" {
    const trace = capture_here();

    try std.testing.expect(!trace.is_empty());
    try std.testing.expect(trace.count() > 0);
    try std.testing.expect(trace.count() <= arc.stack_mod.frames_max);

    std.debug.assert(!trace.is_empty());
    std.debug.assert(trace.count() > 0);
}

test "stack format_to_buffer writes hex addresses" {
    const trace = capture_here();
    var buffer = Buffer.init();

    trace.format_to_buffer(&buffer);

    try std.testing.expect(!buffer.is_empty());
    try std.testing.expect(buffer.contains("0x"));

    std.debug.assert(buffer.contains("0x"));
    std.debug.assert(buffer.len() > 0);
}

test "stack format_to_buffer separates multiple frames with newlines" {
    const trace = capture_here();
    var buffer = Buffer.init();

    trace.format_to_buffer(&buffer);

    if (trace.count() > 1) {
        try std.testing.expect(buffer.contains("\n0x"));
        std.debug.assert(buffer.contains("\n0x"));
    } else {
        try std.testing.expect(buffer.contains("0x"));
    }
}

test "stack capture count is stable enough for formatting" {
    const trace = capture_here();
    var buffer = Buffer.init();

    trace.format_to_buffer(&buffer);

    var lines = std.mem.splitScalar(u8, buffer.contents(), '\n');
    var count: u32 = 0;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(std.mem.startsWith(u8, line, "0x"));
        count += 1;
    }

    try std.testing.expectEqual(trace.count(), count);

    std.debug.assert(count == trace.count());
}

test "formatted stack is reusable across buffers" {
    const trace = capture_here();

    var a = Buffer.init();
    var b = Buffer.init();

    trace.format_to_buffer(&a);
    trace.format_to_buffer(&b);

    try std.testing.expect(a.equals(&b));
    try std.testing.expect(a.contains("0x"));

    std.debug.assert(a.equals(&b));
}
