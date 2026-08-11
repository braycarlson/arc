const std = @import("std");
const buffer_mod = @import("buffer.zig");
const fuzz = @import("../testing/fuzz.zig");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Buffer = buffer_mod.Buffer;
const buffer_bytes_max = buffer_mod.buffer_bytes_max;

const Operation = enum {
    append_byte,
    append_slice,
    append_integer,
    append_unsigned,
    append_repeated,
    truncate,
    reset,
};

const slice_bytes_max: u32 = 64;

comptime {
    assert(slice_bytes_max > 0);
    assert(slice_bytes_max < buffer_bytes_max);
}

const Model = struct {
    bytes: [buffer_bytes_max]u8,
    length: u32,
    truncated: bool,

    fn init() Model {
        return .{ .bytes = @splat(0), .length = 0, .truncated = false };
    }

    fn append(self: *Model, data: []const u8) void {
        assert(self.length <= buffer_bytes_max);

        const room = buffer_bytes_max - self.length;
        const copied: u32 = @intCast(@min(data.len, room));

        if (copied < data.len) {
            self.truncated = true;
        }

        @memcpy(self.bytes[self.length..][0..copied], data[0..copied]);

        self.length += copied;

        assert(self.length <= buffer_bytes_max);
    }

    fn contents(self: *const Model) []const u8 {
        assert(self.length <= buffer_bytes_max);

        return self.bytes[0..self.length];
    }
};

pub fn main(gpa: Allocator, args: fuzz.FuzzArgs) !void {
    assert(args.events_max >= 1);

    _ = gpa;

    var prng = std.Random.DefaultPrng.init(args.seed);
    const random = prng.random();

    var buffer = Buffer.init();
    var model = Model.init();
    var event: u32 = 0;

    while (event < args.events_max) : (event += 1) {
        try apply(random, &buffer, &model);
        try verify(&buffer, &model);
    }

    assert(event == args.events_max);

    try verify_format_integer();
}

fn apply(random: std.Random, buffer: *Buffer, model: *Model) !void {
    var scratch: [slice_bytes_max]u8 = undefined;

    switch (fuzz.random_enum_uniform(random, Operation)) {
        .append_byte => {
            const byte = random.int(u8);

            buffer.append_byte(byte);
            model.append(&[_]u8{byte});
        },
        .append_slice => {
            const length = random.uintAtMost(usize, slice_bytes_max);
            const data = fuzz.random_bytes(random, scratch[0..length]);

            buffer.append_slice(data);
            model.append(data);
        },
        .append_integer => {
            const value = random.int(i64);
            var digits: [21]u8 = undefined;
            const text = buffer_mod.format_integer(&digits, value);

            buffer.append_integer(value);
            model.append(text);
        },
        .append_unsigned => {
            const value = random.int(u64);
            var digits: [20]u8 = undefined;
            const text = buffer_mod.format_unsigned(&digits, value);

            buffer.append_unsigned(value);
            model.append(text);
        },
        .append_repeated => {
            const byte = random.int(u8);
            const count = random.uintAtMost(u32, slice_bytes_max);

            @memset(scratch[0..count], byte);

            buffer.append_repeated(byte, count);
            model.append(scratch[0..count]);
        },
        .truncate => {
            const length = random.uintAtMost(u32, model.length);

            buffer.truncate(length);
            model.length = length;
        },
        .reset => {
            buffer.reset();

            model.length = 0;
            model.truncated = false;
        },
    }
}

fn verify(buffer: *const Buffer, model: *const Model) !void {
    assert(buffer.is_valid());

    if (buffer.length() != model.length) {
        return error.LengthDiverged;
    }

    if (!std.mem.eql(u8, buffer.contents(), model.contents())) {
        return error.ContentsDiverged;
    }

    if (buffer.was_truncated() != model.truncated) {
        return error.TruncationDiverged;
    }

    if (buffer.is_empty() != (model.length == 0)) {
        return error.EmptinessDiverged;
    }
}

fn verify_format_integer() !void {
    var digits: [21]u8 = undefined;

    const smallest = buffer_mod.format_integer(&digits, std.math.minInt(i64));

    if (!std.mem.eql(u8, smallest, "-9223372036854775808")) {
        return error.MinimumIntegerDiverged;
    }

    const largest = buffer_mod.format_integer(&digits, std.math.maxInt(i64));

    if (!std.mem.eql(u8, largest, "9223372036854775807")) {
        return error.MaximumIntegerDiverged;
    }

    const zero = buffer_mod.format_integer(&digits, 0);

    if (!std.mem.eql(u8, zero, "0")) {
        return error.ZeroIntegerDiverged;
    }
}

const testing = std.testing;

test "fuzz: a buffer tracks the reference model" {
    try main(testing.allocator, .{ .seed = 7, .events_max = fuzz.events_max_smoke });
}
