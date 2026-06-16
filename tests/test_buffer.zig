const std = @import("std");
const arc = @import("arc");

const Buffer = arc.buffer_mod.Buffer;
const buffer_max = arc.buffer_mod.buffer_max;

test "buffer init is empty" {
    const buf = Buffer.init();

    try std.testing.expectEqual(@as(u32, 0), buf.len());
    try std.testing.expect(buf.is_empty());
    try std.testing.expect(!buf.is_full());

    std.debug.assert(buf.len() == 0);
    std.debug.assert(buf.is_empty());
}

test "buffer append_byte increases length" {
    var buf = Buffer.init();

    buf.append_byte('A');

    try std.testing.expectEqual(@as(u32, 1), buf.len());
    try std.testing.expect(!buf.is_empty());
    try std.testing.expectEqual(@as(?u8, 'A'), buf.last_byte());

    std.debug.assert(buf.len() == 1);
    std.debug.assert(!buf.is_empty());
}

test "buffer append_slice stores data" {
    var buf = Buffer.init();

    buf.append_slice("hello world");

    try std.testing.expectEqual(@as(u32, 11), buf.len());
    try std.testing.expectEqualStrings("hello world", buf.contents());

    std.debug.assert(buf.len() == 11);
    std.debug.assert(!buf.is_empty());
}

test "buffer reset clears contents" {
    var buf = Buffer.init();

    buf.append_slice("data");

    std.debug.assert(buf.len() > 0);

    buf.reset();

    try std.testing.expectEqual(@as(u32, 0), buf.len());
    try std.testing.expect(buf.is_empty());

    std.debug.assert(buf.len() == 0);
    std.debug.assert(buf.is_empty());
}

test "buffer contains finds substring" {
    var buf = Buffer.init();

    buf.append_slice("hello world");

    try std.testing.expect(buf.contains("hello"));
    try std.testing.expect(buf.contains("world"));
    try std.testing.expect(buf.contains("lo wo"));
    try std.testing.expect(!buf.contains("goodbye"));

    std.debug.assert(buf.contains("hello"));
    std.debug.assert(!buf.contains("goodbye"));
}

test "buffer last_byte returns none when empty" {
    const buf = Buffer.init();

    try std.testing.expectEqual(@as(?u8, null), buf.last_byte());

    std.debug.assert(buf.last_byte() == null);
    std.debug.assert(buf.is_empty());
}

test "buffer truncate reduces length" {
    var buf = Buffer.init();

    buf.append_slice("hello world");

    std.debug.assert(buf.len() == 11);

    buf.truncate(5);

    try std.testing.expectEqual(@as(u32, 5), buf.len());
    try std.testing.expectEqualStrings("hello", buf.contents());

    std.debug.assert(buf.len() == 5);
    std.debug.assert(!buf.is_empty());
}

test "buffer copy_to duplicates contents" {
    var source = Buffer.init();
    var dest = Buffer.init();

    source.append_slice("original");
    source.copy_to(&dest);

    try std.testing.expectEqualStrings("original", dest.contents());
    try std.testing.expect(source.equals(&dest));

    std.debug.assert(dest.len() == source.len());
    std.debug.assert(source.equals(&dest));
}

test "buffer equals compares contents" {
    var a = Buffer.init();
    var b = Buffer.init();

    a.append_slice("same");
    b.append_slice("same");

    try std.testing.expect(a.equals(&b));

    b.reset();
    b.append_slice("different");

    try std.testing.expect(!a.equals(&b));

    std.debug.assert(!a.equals(&b));
    std.debug.assert(a.len() != b.len());
}

test "buffer multiple appends accumulate" {
    var buf = Buffer.init();

    buf.append_slice("hello");
    buf.append_byte(' ');
    buf.append_slice("world");

    try std.testing.expectEqual(@as(u32, 11), buf.len());
    try std.testing.expectEqualStrings("hello world", buf.contents());

    std.debug.assert(buf.len() == 11);
    std.debug.assert(buf.contains("hello"));
}

test "format_integer handles zero" {
    var scratch: [21]u8 = undefined;
    const result = arc.buffer_mod.format_integer(&scratch, 0);

    try std.testing.expectEqualStrings("0", result);

    std.debug.assert(result.len == 1);
    std.debug.assert(result[0] == '0');
}

test "format_integer handles positive" {
    var scratch: [21]u8 = undefined;
    const result = arc.buffer_mod.format_integer(&scratch, 12345);

    try std.testing.expectEqualStrings("12345", result);

    std.debug.assert(result.len == 5);
    std.debug.assert(result.len > 0);
}

test "format_integer handles negative" {
    var scratch: [21]u8 = undefined;
    const result = arc.buffer_mod.format_integer(&scratch, -42);

    try std.testing.expectEqualStrings("-42", result);

    std.debug.assert(result.len == 3);
    std.debug.assert(result[0] == '-');
}

test "format_unsigned handles zero" {
    var scratch: [20]u8 = undefined;
    const result = arc.buffer_mod.format_unsigned(&scratch, 0);

    try std.testing.expectEqualStrings("0", result);

    std.debug.assert(result.len == 1);
    std.debug.assert(result[0] == '0');
}

test "format_unsigned handles large value" {
    var scratch: [20]u8 = undefined;
    const result = arc.buffer_mod.format_unsigned(&scratch, 9_999_999);

    try std.testing.expectEqualStrings("9999999", result);

    std.debug.assert(result.len == 7);
    std.debug.assert(result.len > 0);
}
