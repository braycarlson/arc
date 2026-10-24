const std = @import("std");

const assert = std.debug.assert;

pub const Buffer = struct {
    bytes: [entry_bytes_max]u8,
    clipped: bool,
    count: u32,
    truncated: bool,

    pub fn reset(buffer: *Buffer) void {
        buffer.clipped = false;
        buffer.count = 0;
        buffer.truncated = false;

        assert(buffer.contents().len == 0);
    }

    pub fn contents(buffer: *const Buffer) []const u8 {
        assert(buffer.count <= entry_bytes_max);

        return buffer.bytes[0..buffer.count];
    }

    pub fn remaining(buffer: *const Buffer) u32 {
        assert(buffer.count <= entry_bytes_max);

        const result = entry_bytes_max - buffer.count;

        assert(result <= entry_bytes_max);

        return result;
    }

    pub fn append_byte(buffer: *Buffer, byte: u8) void {
        assert(byte < 0x80);
        assert(buffer.count <= entry_bytes_max);

        if (buffer.count == entry_bytes_max) {
            buffer.truncated = true;

            return;
        }

        buffer.bytes[buffer.count] = byte;
        buffer.count += 1;
    }

    pub fn append_slice(buffer: *Buffer, slice: []const u8) void {
        assert(slice.len <= text_bytes_max);
        assert(buffer.count <= entry_bytes_max);

        const room = entry_bytes_max - buffer.count;
        const copied: u32 = @intCast(@min(slice.len, room));

        if (copied < slice.len) buffer.truncated = true;

        @memcpy(buffer.bytes[buffer.count..][0..copied], slice[0..copied]);
        buffer.count += copied;

        assert(buffer.count <= entry_bytes_max);
    }

    pub fn append_integer(buffer: *Buffer, value: i64) void {
        assert(buffer.count <= entry_bytes_max);
        assert(std.math.log10_int(@abs(value) | 1) + 2 <= integer_bytes_max);

        var scratch: [integer_bytes_max]u8 = undefined;

        const magnitude = @abs(value);
        const digits = unsigned_format(scratch[1..], magnitude);
        const start = integer_bytes_max - digits.len;

        assert(digits.len < integer_bytes_max - 1);

        if (value < 0) {
            scratch[start - 1] = '-';
            buffer.append_slice(scratch[start - 1 ..]);
        } else {
            buffer.append_slice(scratch[start..]);
        }
    }

    pub fn append_unsigned(buffer: *Buffer, value: u64) void {
        assert(buffer.count <= entry_bytes_max);
        assert(std.math.log10_int(value | 1) + 1 <= unsigned_bytes_max);

        var scratch: [unsigned_bytes_max]u8 = undefined;

        const digits = unsigned_format(&scratch, value);

        assert(digits.len > 0);

        buffer.append_slice(digits);
    }

    pub fn append_float(buffer: *Buffer, value: f64) void {
        assert(std.math.isFinite(value));
        assert(buffer.count <= entry_bytes_max);

        if (float_is_whole(value)) {
            buffer.append_integer(@intFromFloat(value));

            return;
        }

        var scratch: [float_bytes_max]u8 = undefined;

        const text = std.mem.print(&scratch, "{d}", .{value}) catch |err| switch (err) {
            error.NoSpaceLeft => unreachable,
        };

        buffer.append_slice(text);
    }
};

pub const entry_bytes_max: u32 = 8192;
pub const float_bytes_max: u32 = 352;
pub const integer_bytes_max: u32 = 21;
pub const text_bytes_max: u32 = 1 << 31;
pub const unsigned_bytes_max: u32 = 20;
const float_whole_limit: f64 = 9_007_199_254_740_992.0;

comptime {
    assert(entry_bytes_max >= 1024);
    assert(integer_bytes_max == unsigned_bytes_max + 1);
    assert(float_bytes_max > 330);
    assert(float_whole_limit == 1 << 53);
}

pub fn unsigned_format(scratch: *[unsigned_bytes_max]u8, value: u64) []const u8 {
    assert(scratch.len == unsigned_bytes_max);
    assert(std.math.log10_int(value | 1) + 1 <= scratch.len);

    var remaining_value = value;
    var start: u32 = unsigned_bytes_max;

    for (0..unsigned_bytes_max) |_| {
        start -= 1;
        scratch[start] = '0' + @as(u8, @intCast(@rem(remaining_value, 10)));
        remaining_value = @divTrunc(remaining_value, 10);

        if (remaining_value == 0) break;
    }

    assert(remaining_value == 0);
    assert(start < unsigned_bytes_max);

    return scratch[start..];
}

fn float_is_whole(value: f64) bool {
    assert(std.math.isFinite(value));

    if (value == 0) return false;
    if (@abs(value) >= float_whole_limit) return false;
    return value == @trunc(value);
}

const testing = std.testing;

test Buffer {
    var buffer: Buffer = undefined;

    buffer.reset();

    buffer.append_byte('{');
    buffer.append_slice("\"n\":");
    buffer.append_integer(-42);
    buffer.append_byte(',');
    buffer.append_float(2.5);
    buffer.append_byte('}');

    try testing.expectEqualStrings("{\"n\":-42,2.5}", buffer.contents());
    try testing.expect(!buffer.truncated);
}

test "integers render exactly as std.fmt renders them" {
    const values = [_]i64{
        std.math.minInt(i64),
        std.math.minInt(i64) + 1,
        -1_000_000_007,
        -10,
        -9,
        -1,
        0,
        1,
        9,
        10,
        99,
        100,
        1_234_567_890,
        std.math.maxInt(i64) - 1,
        std.math.maxInt(i64),
    };

    for (values) |value| {
        var buffer: Buffer = undefined;
        var expected: [integer_bytes_max]u8 = undefined;

        buffer.reset();
        buffer.append_integer(value);

        try testing.expectEqualStrings(
            try std.mem.print(&expected, "{d}", .{value}),
            buffer.contents(),
        );
    }
}

test "unsigned integers render exactly as std.fmt renders them" {
    const values = [_]u64{ 0, 1, 9, 10, 1 << 63, std.math.maxInt(u64) - 1, std.math.maxInt(u64) };

    for (values) |value| {
        var buffer: Buffer = undefined;
        var expected: [unsigned_bytes_max]u8 = undefined;

        buffer.reset();
        buffer.append_unsigned(value);

        try testing.expectEqualStrings(
            try std.mem.print(&expected, "{d}", .{value}),
            buffer.contents(),
        );
    }
}

test "a float renders as std.fmt decimal, whole values through the integer path" {
    const values = [_]f64{
        -0.0,
        0.0,
        0.5,
        -273.15,
        3.0,
        -3.0,
        1e15,
        6.022e23,
        0.00001,
        std.math.floatMax(f64),
        -std.math.floatMax(f64),
        std.math.floatMin(f64),
        std.math.floatTrueMin(f64),
        float_whole_limit - 1,
        float_whole_limit,
    };

    for (values) |value| {
        var buffer: Buffer = undefined;
        var expected: [float_bytes_max]u8 = undefined;

        buffer.reset();
        buffer.append_float(value);

        try testing.expectEqualStrings(
            try std.mem.print(&expected, "{d}", .{value}),
            buffer.contents(),
        );
    }
}

test "appending past the end keeps what fits and marks the buffer truncated" {
    var buffer: Buffer = undefined;

    buffer.reset();
    const filler: [entry_bytes_max - 2]u8 = @splat('x');

    buffer.append_slice(&filler);

    try testing.expect(!buffer.truncated);
    try testing.expectEqual(@as(u32, 2), buffer.remaining());

    buffer.append_slice("abc");

    try testing.expect(buffer.truncated);
    try testing.expectEqual(@as(u32, 0), buffer.remaining());
    try testing.expectEqualStrings("ab", buffer.contents()[filler.len..]);

    buffer.append_byte('d');

    try testing.expectEqual(entry_bytes_max, buffer.count);

    buffer.reset();

    try testing.expect(!buffer.truncated);
    try testing.expectEqual(entry_bytes_max, buffer.remaining());
}
