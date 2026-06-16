const std = @import("std");

pub const buffer_max: u32 = 8192;

pub const Buffer = struct {
    data: [buffer_max]u8,
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
        if (self.position >= buffer_max) {
            self.truncated = true;
            return;
        }

        self.data[self.position] = byte;
        self.position += 1;

        std.debug.assert(self.position <= buffer_max);
    }

    pub fn append_slice(self: *Buffer, slice: []const u8) void {
        if (slice.len == 0) {
            return;
        }

        std.debug.assert(self.position <= buffer_max);

        const available_space: u32 = buffer_max - self.position;
        const copy_length: u32 = @intCast(@min(slice.len, available_space));

        if (copy_length < slice.len) {
            self.truncated = true;
        }

        @memcpy(self.data[self.position..][0..copy_length], slice[0..copy_length]);
        self.position += copy_length;

        std.debug.assert(self.position <= buffer_max);
    }

    pub fn append_integer(self: *Buffer, value: i64) void {
        var scratch: [21]u8 = undefined;
        const formatted = format_integer(&scratch, value);

        std.debug.assert(formatted.len > 0);
        self.append_slice(formatted);
    }

    pub fn append_unsigned(self: *Buffer, value: u64) void {
        var scratch: [20]u8 = undefined;
        const formatted = format_unsigned(&scratch, value);

        std.debug.assert(formatted.len > 0);
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

        if (value != 0 and @abs(value) < integer_limit and value == @trunc(value)) {
            self.append_integer(@intFromFloat(value));
            return;
        }

        var scratch: [32]u8 = undefined;
        const formatted = std.fmt.bufPrint(&scratch, "{d}", .{value}) catch {
            self.append_slice("null");
            return;
        };

        std.debug.assert(formatted.len > 0);
        self.append_slice(formatted);
    }

    pub fn append_bool(self: *Buffer, value: bool) void {
        self.append_slice(if (value) "true" else "false");
    }

    pub fn append_padded_u32(self: *Buffer, value: u32, width: u32) void {
        std.debug.assert(width > 0);
        std.debug.assert(width <= 10);

        var scratch: [10]u8 = undefined;
        var remaining_val = value;
        var pos: u32 = width;

        while (pos > 0) {
            pos -= 1;
            scratch[pos] = @intCast('0' + remaining_val % 10);
            remaining_val /= 10;
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
        var remaining_val = value;
        var scratch: [8]u8 = undefined;
        var pos: u32 = 8;

        if (remaining_val == 0) {
            self.append_byte('0');
            return;
        }

        var iterations: u32 = 0;

        while (remaining_val > 0 and iterations < 8) {
            pos -= 1;
            scratch[pos] = hex[remaining_val & 0x0f];
            remaining_val >>= 4;
            iterations += 1;
        }

        std.debug.assert(remaining_val == 0);
        std.debug.assert(pos < 8);
        self.append_slice(scratch[pos..8]);
    }

    pub fn append_repeated(self: *Buffer, byte: u8, count: u32) void {
        std.debug.assert(self.position <= buffer_max);

        const available_space: u32 = buffer_max - self.position;
        const fill_count = @min(count, available_space);

        if (fill_count < count) {
            self.truncated = true;
        }

        @memset(self.data[self.position..][0..fill_count], byte);
        self.position += fill_count;

        std.debug.assert(self.position <= buffer_max);
    }

    pub fn remaining(self: *const Buffer) u32 {
        std.debug.assert(self.position <= buffer_max);

        return buffer_max - self.position;
    }

    pub fn contents(self: *const Buffer) []const u8 {
        std.debug.assert(self.position <= buffer_max);

        return self.data[0..self.position];
    }

    pub fn len(self: *const Buffer) u32 {
        return self.position;
    }

    pub fn is_empty(self: *const Buffer) bool {
        return self.position == 0;
    }

    pub fn is_full(self: *const Buffer) bool {
        return self.position >= buffer_max;
    }

    pub fn was_truncated(self: *const Buffer) bool {
        return self.truncated;
    }

    pub fn last_byte(self: *const Buffer) ?u8 {
        std.debug.assert(self.position <= buffer_max);

        if (self.position == 0) {
            return null;
        }

        return self.data[self.position - 1];
    }

    pub fn truncate(self: *Buffer, new_length: u32) void {
        std.debug.assert(new_length <= self.position);
        std.debug.assert(new_length <= buffer_max);

        self.position = new_length;
    }

    pub fn copy_to(self: *const Buffer, dest: *Buffer) void {
        std.debug.assert(self.position <= buffer_max);

        dest.reset();

        if (self.position > 0) {
            @memcpy(dest.data[0..self.position], self.data[0..self.position]);
            dest.position = self.position;
        }

        std.debug.assert(dest.position == self.position);
    }

    pub fn equals(self: *const Buffer, other: *const Buffer) bool {
        if (self.position != other.position) {
            return false;
        }

        return std.mem.eql(u8, self.contents(), other.contents());
    }

    pub fn contains(self: *const Buffer, needle: []const u8) bool {
        std.debug.assert(needle.len > 0);

        if (needle.len > self.position) {
            return false;
        }

        return std.mem.indexOf(u8, self.contents(), needle) != null;
    }
};

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

    var pos: u32 = 21;
    var iterations: u32 = 0;

    while (absolute > 0 and iterations < 20) {
        pos -= 1;
        scratch[pos] = @intCast('0' + @as(u8, @intCast(absolute % 10)));
        absolute /= 10;
        iterations += 1;
    }

    std.debug.assert(absolute == 0);

    if (negative) {
        pos -= 1;
        scratch[pos] = '-';
    }

    std.debug.assert(pos < 21);
    return scratch[pos..21];
}

pub fn format_unsigned(scratch: *[20]u8, value: u64) []const u8 {
    if (value == 0) {
        scratch[19] = '0';
        return scratch[19..20];
    }

    var remaining_val = value;
    var pos: u32 = 20;
    var iterations: u32 = 0;

    while (remaining_val > 0 and iterations < 20) {
        pos -= 1;
        scratch[pos] = @intCast('0' + @as(u8, @intCast(remaining_val % 10)));
        remaining_val /= 10;
        iterations += 1;
    }

    std.debug.assert(remaining_val == 0);
    std.debug.assert(pos < 20);
    return scratch[pos..20];
}

pub fn format_hex(scratch: *[16]u8, value: u64) []const u8 {
    const hex = "0123456789abcdef";

    if (value == 0) {
        scratch[15] = '0';
        return scratch[15..16];
    }

    var remaining = value;
    var pos: u32 = 16;
    var iterations: u32 = 0;

    while (remaining > 0 and iterations < 16) {
        pos -= 1;
        scratch[pos] = hex[remaining & 0x0f];
        remaining >>= 4;
        iterations += 1;
    }

    std.debug.assert(remaining == 0);
    std.debug.assert(pos < 16);
    return scratch[pos..16];
}
