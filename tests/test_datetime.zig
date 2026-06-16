const std = @import("std");
const arc = @import("arc");

const datetime = arc.datetime_mod;
const Buffer = arc.buffer_mod.Buffer;

const nanos_per_second: i64 = 1_000_000_000;

test "write_iso8601 trims trailing zeros in the fraction" {
    var buffer = Buffer.init();

    datetime.write_iso8601(&buffer, nanos_per_second + 500_000_000, 0);

    try std.testing.expectEqualSlices(u8, "1970-01-01T00:00:01.5Z", buffer.contents());
}

test "write_iso8601 omits the fraction on a whole second" {
    var buffer = Buffer.init();

    datetime.write_iso8601(&buffer, 2 * nanos_per_second, 0);

    try std.testing.expectEqualSlices(u8, "1970-01-01T00:00:02Z", buffer.contents());
}

test "write_iso8601_nano pads the fraction to nine digits" {
    var buffer = Buffer.init();

    datetime.write_iso8601_nano(&buffer, nanos_per_second + 500_000_000, 0);

    try std.testing.expectEqualSlices(u8, "1970-01-01T00:00:01.500000000Z", buffer.contents());
}

test "write_iso8601_nano always emits the fraction on a whole second" {
    var buffer = Buffer.init();

    datetime.write_iso8601_nano(&buffer, 2 * nanos_per_second, 0);

    try std.testing.expectEqualSlices(u8, "1970-01-01T00:00:02.000000000Z", buffer.contents());
}

test "write_iso8601_nano keeps a constant width across fractions" {
    var first = Buffer.init();
    var second = Buffer.init();

    datetime.write_iso8601_nano(&first, nanos_per_second + 30, 0);
    datetime.write_iso8601_nano(&second, nanos_per_second + 999_999_999, 0);

    try std.testing.expectEqual(first.len(), second.len());
}
