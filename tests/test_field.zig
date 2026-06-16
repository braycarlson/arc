const std = @import("std");
const arc = @import("arc");

const Field = arc.Field;
const FieldType = arc.field_mod.FieldType;

test "string field has correct type and values" {
    const field = arc.string("host", "localhost");

    try std.testing.expectEqualStrings("host", field.key);
    try std.testing.expectEqual(FieldType.string, field.field_type);
    try std.testing.expectEqualStrings("localhost", field.value.text);

    std.debug.assert(field.key.len > 0);
    std.debug.assert(field.value.text.len > 0);
}

test "boolean field has correct type and values" {
    const field_true = arc.boolean("enabled", true);
    const field_false = arc.boolean("enabled", false);

    try std.testing.expectEqual(FieldType.bool, field_true.field_type);
    try std.testing.expect(field_true.value.boolean);
    try std.testing.expect(!field_false.value.boolean);

    std.debug.assert(field_true.key.len > 0);
    std.debug.assert(field_true.value.boolean != field_false.value.boolean);
}

test "signed integer fields preserve values" {
    const field_i8 = arc.int8("tiny", -42);
    const field_i16 = arc.int16("small", -1000);
    const field_i32 = arc.int32("medium", -100_000);
    const field_i64 = arc.int64("large", -9_000_000_000);

    try std.testing.expectEqual(FieldType.int8, field_i8.field_type);
    try std.testing.expectEqual(@as(i64, -42), field_i8.value.signed);
    try std.testing.expectEqual(FieldType.int16, field_i16.field_type);
    try std.testing.expectEqual(@as(i64, -1000), field_i16.value.signed);
    try std.testing.expectEqual(FieldType.int32, field_i32.field_type);
    try std.testing.expectEqual(@as(i64, -100_000), field_i32.value.signed);
    try std.testing.expectEqual(FieldType.int64, field_i64.field_type);
    try std.testing.expectEqual(@as(i64, -9_000_000_000), field_i64.value.signed);

    std.debug.assert(field_i8.value.signed < 0);
    std.debug.assert(field_i64.value.signed < 0);
}

test "unsigned integer fields preserve values" {
    const field_u8 = arc.uint8("tiny", 255);
    const field_u16 = arc.uint16("small", 65535);
    const field_u32 = arc.uint32("medium", 100_000);
    const field_u64 = arc.uint64("large", 9_000_000_000);

    try std.testing.expectEqual(FieldType.uint8, field_u8.field_type);
    try std.testing.expectEqual(@as(u64, 255), field_u8.value.unsigned);
    try std.testing.expectEqual(FieldType.uint16, field_u16.field_type);
    try std.testing.expectEqual(@as(u64, 65535), field_u16.value.unsigned);
    try std.testing.expectEqual(FieldType.uint32, field_u32.field_type);
    try std.testing.expectEqual(@as(u64, 100_000), field_u32.value.unsigned);
    try std.testing.expectEqual(FieldType.uint64, field_u64.field_type);
    try std.testing.expectEqual(@as(u64, 9_000_000_000), field_u64.value.unsigned);

    std.debug.assert(field_u8.value.unsigned == 255);
    std.debug.assert(field_u64.value.unsigned > 0);
}

test "float fields preserve values" {
    const field_f32 = arc.float32("ratio", 3.14);
    const field_f64 = arc.float64("precise", 2.718281828459045);

    try std.testing.expectEqual(FieldType.float32, field_f32.field_type);
    try std.testing.expectEqual(FieldType.float64, field_f64.field_type);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), field_f32.value.float, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 2.718281828459045), field_f64.value.float, 1e-12);

    std.debug.assert(field_f32.value.float > 0.0);
    std.debug.assert(field_f64.value.float > 0.0);
}

test "duration_ns field stores nanoseconds" {
    const field = arc.duration_ns("latency", 5_000_000_000);

    try std.testing.expectEqual(FieldType.duration_ns, field.field_type);
    try std.testing.expectEqual(@as(i64, 5_000_000_000), field.value.signed);

    std.debug.assert(field.value.signed > 0);
    std.debug.assert(field.key.len > 0);
}

test "time_s field stores epoch seconds" {
    const field = arc.time_s("created_at", 1_700_000_000);

    try std.testing.expectEqual(FieldType.time_s, field.field_type);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), field.value.signed);

    std.debug.assert(field.value.signed > 0);
    std.debug.assert(field.key.len > 0);
}

test "binary field stores raw bytes" {
    const data = &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const field = arc.binary("payload", data);

    try std.testing.expectEqual(FieldType.binary, field.field_type);
    try std.testing.expectEqualSlices(u8, data, field.value.bytes);

    std.debug.assert(field.value.bytes.len == 4);
    std.debug.assert(field.key.len > 0);
}

test "err field uses error key" {
    const field = arc.err("connection refused");

    try std.testing.expectEqualStrings("error", field.key);
    try std.testing.expectEqual(FieldType.err, field.field_type);
    try std.testing.expectEqualStrings("connection refused", field.value.text);

    std.debug.assert(field.key.len > 0);
    std.debug.assert(field.value.text.len > 0);
}

test "named_err field uses custom key" {
    const field = arc.named_err("db_error", "timeout");

    try std.testing.expectEqualStrings("db_error", field.key);
    try std.testing.expectEqual(FieldType.err, field.field_type);
    try std.testing.expectEqualStrings("timeout", field.value.text);

    std.debug.assert(field.key.len > 0);
    std.debug.assert(field.value.text.len > 0);
}

test "string_list field stores slice" {
    const hosts = &[_][]const u8{ "host-a", "host-b", "host-c" };
    const field = arc.string_list("hosts", hosts);

    try std.testing.expectEqual(FieldType.string_list, field.field_type);
    try std.testing.expectEqual(@as(usize, 3), field.value.text_list.len);
    try std.testing.expectEqualStrings("host-a", field.value.text_list[0]);
    try std.testing.expectEqualStrings("host-c", field.value.text_list[2]);

    std.debug.assert(field.value.text_list.len <= arc.field_mod.array_max);
    std.debug.assert(field.key.len > 0);
}

test "namespace field has correct type" {
    const field = arc.namespace("request");

    try std.testing.expectEqualStrings("request", field.key);
    try std.testing.expectEqual(FieldType.namespace, field.field_type);

    std.debug.assert(field.key.len > 0);
    std.debug.assert(field.field_type == .namespace);
}

test "skip field has empty key" {
    const field = arc.skip();

    try std.testing.expectEqualStrings("", field.key);
    try std.testing.expectEqual(FieldType.skip, field.field_type);

    std.debug.assert(field.field_type == .skip);
    std.debug.assert(field.key.len == 0);
}

test "int alias delegates to int64" {
    const field = arc.int("count", 42);

    try std.testing.expectEqual(FieldType.int64, field.field_type);
    try std.testing.expectEqual(@as(i64, 42), field.value.signed);

    std.debug.assert(field.value.signed == 42);
    std.debug.assert(field.key.len > 0);
}

test "uint alias delegates to uint64" {
    const field = arc.uint("count", 42);

    try std.testing.expectEqual(FieldType.uint64, field.field_type);
    try std.testing.expectEqual(@as(u64, 42), field.value.unsigned);

    std.debug.assert(field.value.unsigned == 42);
    std.debug.assert(field.key.len > 0);
}

test "float alias delegates to float64" {
    const field = arc.float("ratio", 0.75);

    try std.testing.expectEqual(FieldType.float64, field.field_type);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), field.value.float, 1e-12);

    std.debug.assert(field.value.float > 0.0);
    std.debug.assert(field.key.len > 0);
}

test "any dispatches bool correctly" {
    const field = arc.any("flag", true);

    try std.testing.expectEqual(FieldType.bool, field.field_type);
    try std.testing.expect(field.value.boolean);

    std.debug.assert(field.key.len > 0);
    std.debug.assert(field.field_type == .bool);
}

test "any dispatches signed int correctly" {
    const field = arc.any("val", @as(i32, -99));

    try std.testing.expectEqual(FieldType.int32, field.field_type);
    try std.testing.expectEqual(@as(i64, -99), field.value.signed);

    std.debug.assert(field.value.signed < 0);
    std.debug.assert(field.key.len > 0);
}

test "any dispatches string slice correctly" {
    const field = arc.any("name", @as([]const u8, "test"));

    try std.testing.expectEqual(FieldType.string, field.field_type);
    try std.testing.expectEqualStrings("test", field.value.text);

    std.debug.assert(field.value.text.len > 0);
    std.debug.assert(field.key.len > 0);
}
