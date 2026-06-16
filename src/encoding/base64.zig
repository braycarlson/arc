const std = @import("std");
const buffer_mod = @import("../io/buffer.zig");

const Buffer = buffer_mod.Buffer;

const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn encode_base64(buffer: *Buffer, data: []const u8) void {
    var cursor: usize = 0;

    while (cursor + 2 < data.len) {
        encode_base64_triplet(buffer, data[cursor], data[cursor + 1], data[cursor + 2]);
        cursor += 3;
    }

    const remaining = data.len - cursor;

    if (remaining == 2) {
        encode_base64_pair(buffer, data[cursor], data[cursor + 1]);
    } else if (remaining == 1) {
        encode_base64_single(buffer, data[cursor]);
    }

    std.debug.assert(cursor + remaining == data.len);
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
