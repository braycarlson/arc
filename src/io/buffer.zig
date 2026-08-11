const std = @import("std");

const assert = std.debug.assert;

pub const Buffer = struct {
    data: [buffer_bytes_max]u8,
    position: u32,
    truncated: bool,

    pub fn init() Buffer {
        var buffer: Buffer = undefined;
        buffer.position = 0;
        buffer.truncated = false;

        return buffer;
    }

    pub fn reset(self: *Buffer) void {
        self.position = 0;
        self.truncated = false;
    }

    pub fn append_byte(self: *Buffer, byte: u8) void {
        if (self.position >= buffer_bytes_max) {
            self.truncated = true;
            return;
        }

        self.data[self.position] = byte;
        self.position += 1;

        assert(self.position <= buffer_bytes_max);
    }

    pub fn append_slice(self: *Buffer, slice: []const u8) void {
        if (slice.len == 0) {
            return;
        }

        assert(self.position <= buffer_bytes_max);

        const available_space: u32 = buffer_bytes_max - self.position;
        const copy_length: u32 = @intCast(@min(slice.len, available_space));

        if (copy_length < slice.len) {
            self.truncated = true;
        }

        @memcpy(self.data[self.position..][0..copy_length], slice[0..copy_length]);
        self.position += copy_length;

        assert(self.position <= buffer_bytes_max);
    }

    pub fn append_integer(self: *Buffer, value: i64) void {
        var scratch: [21]u8 = undefined;
        const formatted = format_integer(&scratch, value);

        assert(formatted.len > 0);
        self.append_slice(formatted);
    }

    pub fn append_unsigned(self: *Buffer, value: u64) void {
        var scratch: [20]u8 = undefined;
        const formatted = format_unsigned(&scratch, value);

        assert(formatted.len > 0);
        self.append_slice(formatted);
    }

    pub fn append_float(self: *Buffer, value: f64) void {
        if (std.math.isNan(value) or std.math.isInf(value)) {
            self.append_slice("null");
            return;
        }

        // Whole-number floats within the exact-integer range format identically to
        // their integer value ("{d}" of 3.0 is "3") but far cheaper than the general
        // float formatter. Exclude zero so signed zero still renders as "-0"/"0".
        const integer_limit: f64 = 9_007_199_254_740_992.0;

        if (is_exact_integer(value, integer_limit)) {
            self.append_integer(@intFromFloat(value));

            return;
        }

        var scratch: [32]u8 = undefined;

        const formatted = std.fmt.bufPrint(&scratch, "{d}", .{value}) catch {
            self.append_slice("null");
            return;
        };

        assert(formatted.len > 0);
        self.append_slice(formatted);
    }

    pub fn append_bool(self: *Buffer, value: bool) void {
        self.append_slice(if (value) "true" else "false");
    }

    pub fn append_padded_u32(self: *Buffer, value: u32, width: u32) void {
        assert(width > 0);
        assert(width <= 10);

        var scratch: [10]u8 = undefined;
        var remaining_value = value;
        var position: u32 = width;

        while (position > 0) {
            position -= 1;
            scratch[position] = @intCast('0' + remaining_value % 10);
            remaining_value /= 10;
        }

        self.append_slice(scratch[0..width]);
    }

    pub fn append_hex_byte(self: *Buffer, value: u8) void {
        const hex = "0123456789abcdef";

        self.append_byte(hex[value >> 4]);
        self.append_byte(hex[value & 0x0f]);
    }

    pub fn append_hex_u32(self: *Buffer, value: u32) void {
        const hex = "0123456789abcdef";
        var remaining_value = value;
        var scratch: [8]u8 = undefined;
        var position: u32 = 8;

        if (remaining_value == 0) {
            self.append_byte('0');
            return;
        }

        var iterations: u32 = 0;

        while (remaining_value > 0 and iterations < 8) {
            position -= 1;
            scratch[position] = hex[remaining_value & 0x0f];
            remaining_value >>= 4;
            iterations += 1;
        }

        assert(remaining_value == 0);
        assert(position < 8);
        self.append_slice(scratch[position..8]);
    }

    pub fn append_repeated(self: *Buffer, byte: u8, count: u32) void {
        assert(self.position <= buffer_bytes_max);

        const available_space: u32 = buffer_bytes_max - self.position;
        const fill_count = @min(count, available_space);

        if (fill_count < count) {
            self.truncated = true;
        }

        @memset(self.data[self.position..][0..fill_count], byte);
        self.position += fill_count;

        assert(self.position <= buffer_bytes_max);
    }

    pub fn remaining(self: *const Buffer) u32 {
        assert(self.position <= buffer_bytes_max);

        return buffer_bytes_max - self.position;
    }

    pub fn contents(self: *const Buffer) []const u8 {
        assert(self.position <= buffer_bytes_max);

        return self.data[0..self.position];
    }

    pub fn length(self: *const Buffer) u32 {
        return self.position;
    }

    pub fn is_empty(self: *const Buffer) bool {
        return self.position == 0;
    }

    pub fn is_full(self: *const Buffer) bool {
        return self.position >= buffer_bytes_max;
    }

    pub fn is_valid(self: *const Buffer) bool {
        return self.position <= buffer_bytes_max;
    }

    pub fn was_truncated(self: *const Buffer) bool {
        return self.truncated;
    }

    pub fn last_byte(self: *const Buffer) ?u8 {
        assert(self.position <= buffer_bytes_max);

        if (self.position == 0) {
            return null;
        }

        return self.data[self.position - 1];
    }

    pub fn truncate(self: *Buffer, new_length: u32) void {
        assert(new_length <= self.position);
        assert(new_length <= buffer_bytes_max);

        self.position = new_length;
    }

    pub fn copy_to(self: *const Buffer, target: *Buffer) void {
        assert(self.position <= buffer_bytes_max);

        target.reset();

        if (self.position > 0) {
            @memcpy(target.data[0..self.position], self.data[0..self.position]);
            target.position = self.position;
        }

        assert(target.position == self.position);
    }

    pub fn equals(self: *const Buffer, other: *const Buffer) bool {
        if (self.position != other.position) {
            return false;
        }

        return std.mem.eql(u8, self.contents(), other.contents());
    }

    pub fn contains(self: *const Buffer, needle: []const u8) bool {
        assert(needle.len > 0);

        if (needle.len > self.position) {
            return false;
        }

        return std.mem.indexOf(u8, self.contents(), needle) != null;
    }
};

pub const buffer_bytes_max: u32 = 8192;

comptime {
    assert(buffer_bytes_max > 0);
}

fn is_exact_integer(value: f64, integer_limit: f64) bool {
    if (value == 0) return false;
    if (@abs(value) >= integer_limit) return false;
    if (value != @trunc(value)) return false;

    return true;
}

pub fn format_integer(scratch: *[21]u8, value: i64) []const u8 {
    if (value == 0) {
        scratch[20] = '0';
        return scratch[20..21];
    }

    const negative = value < 0;

    var absolute: u64 = if (negative) blk: {
        if (value == std.math.minInt(i64)) {
            break :blk @as(u64, @intCast(std.math.maxInt(i64))) + 1;
        }

        break :blk @intCast(-value);
    } else @intCast(value);

    var position: u32 = 21;
    var iterations: u32 = 0;

    while (absolute > 0 and iterations < 20) {
        position -= 1;
        scratch[position] = @intCast('0' + @as(u8, @intCast(absolute % 10)));
        absolute /= 10;
        iterations += 1;
    }

    assert(absolute == 0);

    if (negative) {
        position -= 1;
        scratch[position] = '-';
    }

    assert(position < 21);

    return scratch[position..21];
}

pub fn format_unsigned(scratch: *[20]u8, value: u64) []const u8 {
    if (value == 0) {
        scratch[19] = '0';
        return scratch[19..20];
    }

    var remaining_value = value;
    var position: u32 = 20;
    var iterations: u32 = 0;

    while (remaining_value > 0 and iterations < 20) {
        position -= 1;
        scratch[position] = @intCast('0' + @as(u8, @intCast(remaining_value % 10)));
        remaining_value /= 10;
        iterations += 1;
    }

    assert(remaining_value == 0);
    assert(position < 20);

    return scratch[position..20];
}

pub fn format_hex(scratch: *[16]u8, value: u64) []const u8 {
    const hex = "0123456789abcdef";

    if (value == 0) {
        scratch[15] = '0';
        return scratch[15..16];
    }

    var remaining = value;
    var position: u32 = 16;
    var iterations: u32 = 0;

    while (remaining > 0 and iterations < 16) {
        position -= 1;
        scratch[position] = hex[remaining & 0x0f];
        remaining >>= 4;
        iterations += 1;
    }

    assert(remaining == 0);
    assert(position < 16);

    return scratch[position..16];
}

const testing = std.testing;

test "a new buffer holds nothing" {
    const buf = Buffer.init();

    try testing.expectEqual(@as(u32, 0), buf.length());
    try testing.expect(buf.is_empty());
    try testing.expect(!buf.is_full());

    assert(buf.length() == 0);
    assert(buf.is_empty());
}

test "appending a byte grows the buffer by one" {
    var buf = Buffer.init();

    buf.append_byte('A');

    try testing.expectEqual(@as(u32, 1), buf.length());
    try testing.expect(!buf.is_empty());
    try testing.expectEqual(@as(?u8, 'A'), buf.last_byte());

    assert(buf.length() == 1);
    assert(!buf.is_empty());
}

test "appending a slice stores every byte of it" {
    var buf = Buffer.init();

    buf.append_slice("hello world");

    try testing.expectEqual(@as(u32, 11), buf.length());
    try testing.expectEqualStrings("hello world", buf.contents());

    assert(buf.length() == 11);
    assert(!buf.is_empty());
}

test "resetting a buffer discards its contents" {
    var buf = Buffer.init();

    buf.append_slice("data");

    assert(buf.length() > 0);

    buf.reset();

    try testing.expectEqual(@as(u32, 0), buf.length());
    try testing.expect(buf.is_empty());

    assert(buf.length() == 0);
    assert(buf.is_empty());
}

test "a buffer finds a substring it holds and rejects one it does not" {
    var buf = Buffer.init();

    buf.append_slice("hello world");

    try testing.expect(buf.contains("hello"));
    try testing.expect(buf.contains("world"));
    try testing.expect(buf.contains("lo wo"));
    try testing.expect(!buf.contains("goodbye"));

    assert(buf.contains("hello"));
    assert(!buf.contains("goodbye"));
}

test "an empty buffer has no last byte" {
    const buf = Buffer.init();

    try testing.expectEqual(@as(?u8, null), buf.last_byte());

    assert(buf.last_byte() == null);
    assert(buf.is_empty());
}

test "truncating a buffer keeps only the leading bytes" {
    var buf = Buffer.init();

    buf.append_slice("hello world");

    assert(buf.length() == 11);

    buf.truncate(5);

    try testing.expectEqual(@as(u32, 5), buf.length());
    try testing.expectEqualStrings("hello", buf.contents());

    assert(buf.length() == 5);
    assert(!buf.is_empty());
}

test "copying a buffer duplicates its contents into the target" {
    var source = Buffer.init();
    var target = Buffer.init();

    source.append_slice("original");
    source.copy_to(&target);

    try testing.expectEqualStrings("original", target.contents());
    try testing.expect(source.equals(&target));

    assert(target.length() == source.length());
    assert(source.equals(&target));
}

test "two buffers are equal only while their contents match" {
    var a = Buffer.init();
    var b = Buffer.init();

    a.append_slice("same");
    b.append_slice("same");

    try testing.expect(a.equals(&b));

    b.reset();
    b.append_slice("different");

    try testing.expect(!a.equals(&b));

    assert(!a.equals(&b));
    assert(a.length() != b.length());
}

test "successive appends accumulate in order" {
    var buf = Buffer.init();

    buf.append_slice("hello");
    buf.append_byte(' ');
    buf.append_slice("world");

    try testing.expectEqual(@as(u32, 11), buf.length());
    try testing.expectEqualStrings("hello world", buf.contents());

    assert(buf.length() == 11);
    assert(buf.contains("hello"));
}

test "formatting a signed zero yields a single digit" {
    var scratch: [21]u8 = undefined;
    const result = format_integer(&scratch, 0);

    try testing.expectEqualStrings("0", result);

    assert(result.len == 1);
    assert(result[0] == '0');
}

test "formatting a positive integer yields its digits" {
    var scratch: [21]u8 = undefined;
    const result = format_integer(&scratch, 12345);

    try testing.expectEqualStrings("12345", result);

    assert(result.len == 5);
    assert(result.len > 0);
}

test "formatting a negative integer keeps the leading sign" {
    var scratch: [21]u8 = undefined;
    const result = format_integer(&scratch, -42);

    try testing.expectEqualStrings("-42", result);

    assert(result.len == 3);
    assert(result[0] == '-');
}

test "formatting an unsigned zero yields a single digit" {
    var scratch: [20]u8 = undefined;
    const result = format_unsigned(&scratch, 0);

    try testing.expectEqualStrings("0", result);

    assert(result.len == 1);
    assert(result[0] == '0');
}

test "formatting a large unsigned value yields every digit" {
    var scratch: [20]u8 = undefined;
    const result = format_unsigned(&scratch, 9_999_999);

    try testing.expectEqualStrings("9999999", result);

    assert(result.len == 7);
    assert(result.len > 0);
}
