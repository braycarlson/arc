const std = @import("std");
const buffer_mod = @import("../io/buffer.zig");

const assert = std.debug.assert;

const Buffer = buffer_mod.Buffer;

pub const StackTrace = struct {
    addresses: [frames_max]usize,
    frames_count: u32,

    pub fn capture(return_address: usize) StackTrace {
        assert(return_address != 0);

        var trace: StackTrace = undefined;
        trace.frames_count = 0;

        const captured = std.debug.captureCurrentStackTrace(
            .{ .first_address = return_address },
            &trace.addresses,
        );

        trace.frames_count = @intCast(captured.return_addresses.len);

        if (trace.frames_count == 0) {
            trace.addresses[0] = return_address;
            trace.frames_count = 1;
        }

        assert(trace.frames_count > 0);

        return trace;
    }

    pub fn format_to_buffer(self: *const StackTrace, buffer: *Buffer) void {
        assert(self.frames_count <= frames_max);

        const active = self.addresses[0..self.frames_count];

        for (active, 0..) |address, index| {
            if (index > 0) {
                buffer.append_byte('\n');
            }

            var scratch: [16]u8 = undefined;

            buffer.append_slice("0x");
            buffer.append_slice(buffer_mod.format_hex(&scratch, @intCast(address)));
        }
    }

    pub fn is_empty(self: *const StackTrace) bool {
        return self.frames_count == 0;
    }

    pub fn count(self: *const StackTrace) u32 {
        return self.frames_count;
    }
};

pub const frames_max: u32 = 64;

comptime {
    assert(frames_max > 0);
}

const testing = std.testing;

fn capture_here() StackTrace {
    return StackTrace.capture(@returnAddress());
}

test "capturing a stack returns at least one frame" {
    const trace = capture_here();

    try testing.expect(!trace.is_empty());
    try testing.expect(trace.count() > 0);
    try testing.expect(trace.count() <= frames_max);

    assert(!trace.is_empty());
    assert(trace.count() > 0);
}

test "formatting a stack writes hexadecimal addresses" {
    const trace = capture_here();
    var buffer = Buffer.init();

    trace.format_to_buffer(&buffer);

    try testing.expect(!buffer.is_empty());
    try testing.expect(buffer.contains("0x"));

    assert(buffer.contains("0x"));
    assert(buffer.length() > 0);
}

test "formatting a stack separates its frames with newlines" {
    const trace = capture_here();
    var buffer = Buffer.init();

    trace.format_to_buffer(&buffer);

    if (trace.count() > 1) {
        try testing.expect(buffer.contains("\n0x"));
        assert(buffer.contains("\n0x"));
    } else {
        try testing.expect(buffer.contains("0x"));
    }
}

test "a captured stack reports a frame count it can format" {
    const trace = capture_here();
    var buffer = Buffer.init();

    trace.format_to_buffer(&buffer);

    var lines = std.mem.splitScalar(u8, buffer.contents(), '\n');
    var count: u32 = 0;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try testing.expect(std.mem.startsWith(u8, line, "0x"));
        count += 1;
    }

    try testing.expectEqual(trace.count(), count);

    assert(count == trace.count());
}

test "one captured stack formats identically into two buffers" {
    const trace = capture_here();

    var a = Buffer.init();
    var b = Buffer.init();

    trace.format_to_buffer(&a);
    trace.format_to_buffer(&b);

    try testing.expect(a.equals(&b));
    try testing.expect(a.contains("0x"));

    assert(a.equals(&b));
}
