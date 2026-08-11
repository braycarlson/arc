const std = @import("std");
const buffer_mod = @import("../io/buffer.zig");

const assert = std.debug.assert;

const Buffer = buffer_mod.Buffer;

const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn encode_base64(buffer: *Buffer, data: []const u8) void {
    assert(buffer.is_valid());

    var cursor: usize = 0;

    while (cursor + 2 < data.len and !buffer.is_full()) {
        encode_base64_triplet(buffer, data[cursor], data[cursor + 1], data[cursor + 2]);
        cursor += 3;
    }

    const remaining = data.len - cursor;

    assert(cursor <= data.len);

    if (buffer.is_full()) {
        return;
    }

    if (remaining == 2) {
        encode_base64_pair(buffer, data[cursor], data[cursor + 1]);
    } else if (remaining == 1) {
        encode_base64_single(buffer, data[cursor]);
    }

    assert(buffer.is_valid());
}

fn encode_base64_triplet(buffer: *Buffer, byte_0: u8, byte_1: u8, byte_2: u8) void {
    buffer.append_byte(base64_alphabet[byte_0 >> 2]);
    buffer.append_byte(base64_alphabet[((byte_0 & 0x03) << 4) | (byte_1 >> 4)]);
    buffer.append_byte(base64_alphabet[((byte_1 & 0x0f) << 2) | (byte_2 >> 6)]);
    buffer.append_byte(base64_alphabet[byte_2 & 0x3f]);
}

fn encode_base64_pair(buffer: *Buffer, byte_0: u8, byte_1: u8) void {
    buffer.append_byte(base64_alphabet[byte_0 >> 2]);
    buffer.append_byte(base64_alphabet[((byte_0 & 0x03) << 4) | (byte_1 >> 4)]);
    buffer.append_byte(base64_alphabet[(byte_1 & 0x0f) << 2]);
    buffer.append_byte('=');
}

fn encode_base64_single(buffer: *Buffer, byte_0: u8) void {
    buffer.append_byte(base64_alphabet[byte_0 >> 2]);
    buffer.append_byte(base64_alphabet[(byte_0 & 0x03) << 4]);
    buffer.append_byte('=');
    buffer.append_byte('=');
}

const testing = std.testing;

fn expect_matches_standard(data: []const u8) !void {
    var buffer = Buffer.init();

    encode_base64(&buffer, data);

    const encoder = std.base64.standard.Encoder;
    var expected: [256]u8 = undefined;
    const written = encoder.encode(expected[0..encoder.calcSize(data.len)], data);

    try testing.expectEqualStrings(written, buffer.contents());
}

test "an empty payload encodes to nothing" {
    var buffer = Buffer.init();

    encode_base64(&buffer, "");

    try testing.expect(buffer.is_empty());

    assert(buffer.length() == 0);
}

test "a payload whose length is a multiple of three encodes without padding" {
    try expect_matches_standard("abc");
    try expect_matches_standard("abcdef");
    try expect_matches_standard("any carnal pleasur");
}

test "a payload with one trailing byte encodes with two padding characters" {
    var buffer = Buffer.init();

    encode_base64(&buffer, "a");

    try testing.expectEqualStrings("YQ==", buffer.contents());

    assert(buffer.length() == 4);
}

test "a payload with two trailing bytes encodes with one padding character" {
    var buffer = Buffer.init();

    encode_base64(&buffer, "ab");

    try testing.expectEqualStrings("YWI=", buffer.contents());

    assert(buffer.length() == 4);
}

test "every payload length up to a full block matches the standard alphabet" {
    const source = "0123456789abcdefghij";

    var length: usize = 0;

    while (length <= source.len) : (length += 1) {
        try expect_matches_standard(source[0..length]);
    }
}

test "high bytes encode through the whole alphabet" {
    var payload: [192]u8 = undefined;

    for (&payload, 0..) |*byte, index| {
        byte.* = @intCast(index % 256);
    }

    try expect_matches_standard(&payload);
}
