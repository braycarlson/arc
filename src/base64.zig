const std = @import("std");

const buffer_module = @import("buffer.zig");

const assert = std.debug.assert;

const Buffer = buffer_module.Buffer;

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const entry_bytes_max = buffer_module.entry_bytes_max;
const text_bytes_max = buffer_module.text_bytes_max;

comptime {
    assert(alphabet.len == 64);
    assert(entry_bytes_max % 4 == 0);
}

pub fn base64_write(buffer: *Buffer, bytes: []const u8) void {
    assert(bytes.len <= text_bytes_max);
    assert(buffer.count <= entry_bytes_max);

    const start = buffer.count;
    const group_count_room = @divFloor(buffer.remaining(), 4);
    const group_count_full = @divFloor(bytes.len, 3);

    if (group_count_full > group_count_room) {
        buffer.truncated = true;

        return;
    }

    for (0..group_count_full) |group| {
        const chunk = bytes[group * 3 ..][0..3];

        const text = [4]u8{
            alphabet[chunk[0] >> 2],
            alphabet[((chunk[0] & 0x03) << 4) | (chunk[1] >> 4)],
            alphabet[((chunk[1] & 0x0f) << 2) | (chunk[2] >> 6)],
            alphabet[chunk[2] & 0x3f],
        };

        buffer.append_slice(&text);
    }

    const tail = bytes[group_count_full * 3 ..];

    assert(tail.len < 3);

    switch (tail.len) {
        0 => {},
        1 => buffer.append_slice(&[4]u8{
            alphabet[tail[0] >> 2],
            alphabet[(tail[0] & 0x03) << 4],
            '=',
            '=',
        }),
        2 => buffer.append_slice(&[4]u8{
            alphabet[tail[0] >> 2],
            alphabet[((tail[0] & 0x03) << 4) | (tail[1] >> 4)],
            alphabet[(tail[1] & 0x0f) << 2],
            '=',
        }),
        else => unreachable,
    }

    if (!buffer.truncated) assert(buffer.count - start == @divCeil(bytes.len, 3) * 4);
}

const testing = std.testing;

fn test_matches_standard(bytes: []const u8) !void {
    assert(bytes.len <= 1024);
    assert(std.base64.standard.Encoder.calcSize(bytes.len) <= 2048);

    var buffer: Buffer = undefined;
    var expected: [2048]u8 = undefined;

    buffer.reset();
    base64_write(&buffer, bytes);

    const encoder = std.base64.standard.Encoder;
    const text = encoder.encode(expected[0..encoder.calcSize(bytes.len)], bytes);

    try testing.expectEqualStrings(text, buffer.contents());
    try testing.expect(!buffer.truncated);
}

test "every length up to two blocks matches the standard encoder" {
    const source = "0123456789abcdefghijklmnopqrstuvwxyz";

    for (0..source.len + 1) |length| {
        try test_matches_standard(source[0..length]);
    }
}

test "every byte value encodes through the whole alphabet" {
    var bytes: [256]u8 = undefined;

    for (&bytes, 0..) |*byte, index| {
        byte.* = @intCast(index);
    }

    try test_matches_standard(&bytes);
    try test_matches_standard(bytes[1..]);
    try test_matches_standard(bytes[2..]);
}

test "a payload larger than the room left marks the buffer truncated" {
    var buffer: Buffer = undefined;
    const payload: [entry_bytes_max]u8 = @splat(0xab);

    buffer.reset();
    base64_write(&buffer, &payload);

    try testing.expect(buffer.truncated);
}
