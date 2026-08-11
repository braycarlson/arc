const std = @import("std");
const buffer_mod = @import("../io/buffer.zig");
const json_mod = @import("../encoding/json.zig");

const assert = std.debug.assert;

pub const ObjectEncoder = json_mod.ObjectEncoder;
pub const ArrayEncoder = json_mod.ArrayEncoder;

pub const MarshalObjectFn = *const fn (value: *const anyopaque, encoder: *ObjectEncoder) void;
pub const MarshalArrayFn = *const fn (value: *const anyopaque, encoder: *ArrayEncoder) void;

pub const MarshalReflectFn = json_mod.MarshalReflectFn;
pub const MarshalReflectValueFn = json_mod.MarshalReflectValueFn;

pub const Field = struct {
    key: []const u8,
    field_type: FieldType,
    value: FieldValue,
};

pub const FieldType = enum(u8) {
    string,
    byte_string,
    bool,
    int8,
    int16,
    int32,
    int64,
    uint8,
    uint16,
    uint32,
    uint64,
    float32,
    float64,
    duration_ns,
    time_s,
    time_ns,
    binary,
    err,
    string_list,
    int_list,
    uint_list,
    float_list,
    bool_list,
    duration_list,
    time_list,
    namespace,
    object,
    inline_object,
    array,
    dict,
    reflect,
    skip,
};

pub const FieldValue = union(enum) {
    none: void,
    text: []const u8,
    signed: i64,
    unsigned: u64,
    float: f64,
    boolean: bool,
    bytes: []const u8,
    text_list: []const []const u8,
    signed_list: []const i64,
    unsigned_list: []const u64,
    float_list: []const f64,
    bool_list: []const bool,
    field_list: []const Field,
    marshal: Marshal,
};

pub const Marshal = struct {
    value: *const anyopaque,
    encode: Encode,

    pub const Encode = union(enum) {
        object: MarshalObjectFn,
        array: MarshalArrayFn,
        reflect: Reflect,
    };

    pub const Reflect = struct {
        field_fn: MarshalReflectFn,
        value_fn: MarshalReflectValueFn,
    };

    pub fn object_fn(self: Marshal) ?MarshalObjectFn {
        return switch (self.encode) {
            .object => |function| function,
            .array, .reflect => null,
        };
    }

    pub fn array_fn(self: Marshal) ?MarshalArrayFn {
        return switch (self.encode) {
            .array => |function| function,
            .object, .reflect => null,
        };
    }

    pub fn reflect_fn(self: Marshal) ?MarshalReflectFn {
        return switch (self.encode) {
            .reflect => |reflect_pair| reflect_pair.field_fn,
            .object, .array => null,
        };
    }

    pub fn reflect_value_fn(self: Marshal) ?MarshalReflectValueFn {
        return switch (self.encode) {
            .reflect => |reflect_pair| reflect_pair.value_fn,
            .object, .array => null,
        };
    }
};

pub const EntryFields = struct {
    context: []const Field,
    message: []const Field,

    pub fn is_valid(self: EntryFields) bool {
        if (self.context.len > fields_max) return false;
        if (self.message.len > fields_max) return false;

        return true;
    }
};

pub const fields_max: u32 = 32;
pub const key_bytes_max: u32 = 128;
pub const array_values_max: u32 = 64;

comptime {
    assert(fields_max > 0);
    assert(key_bytes_max > 0);
    assert(array_values_max > 0);
    assert(key_bytes_max <= buffer_mod.buffer_bytes_max);
}

pub fn string(key: []const u8, value: []const u8) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{ .key = key, .field_type = .string, .value = .{ .text = value } };
}

pub fn byte_string(key: []const u8, value: []const u8) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{ .key = key, .field_type = .byte_string, .value = .{ .text = value } };
}

pub fn boolean(key: []const u8, value: bool) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{ .key = key, .field_type = .bool, .value = .{ .boolean = value } };
}

pub fn int8(key: []const u8, value: i8) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{ .key = key, .field_type = .int8, .value = .{ .signed = @intCast(value) } };
}

pub fn int16(key: []const u8, value: i16) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{ .key = key, .field_type = .int16, .value = .{ .signed = @intCast(value) } };
}

pub fn int32(key: []const u8, value: i32) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{ .key = key, .field_type = .int32, .value = .{ .signed = @intCast(value) } };
}

pub fn int64(key: []const u8, value: i64) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{ .key = key, .field_type = .int64, .value = .{ .signed = value } };
}

pub fn uint8(key: []const u8, value: u8) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{ .key = key, .field_type = .uint8, .value = .{ .unsigned = @intCast(value) } };
}

pub fn uint16(key: []const u8, value: u16) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{ .key = key, .field_type = .uint16, .value = .{ .unsigned = @intCast(value) } };
}

pub fn uint32(key: []const u8, value: u32) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{ .key = key, .field_type = .uint32, .value = .{ .unsigned = @intCast(value) } };
}

pub fn uint64(key: []const u8, value: u64) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{ .key = key, .field_type = .uint64, .value = .{ .unsigned = value } };
}

pub fn float32(key: []const u8, value: f32) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{ .key = key, .field_type = .float32, .value = .{ .float = @floatCast(value) } };
}

pub fn float64(key: []const u8, value: f64) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{ .key = key, .field_type = .float64, .value = .{ .float = value } };
}

pub fn duration_ns(key: []const u8, value: i64) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{ .key = key, .field_type = .duration_ns, .value = .{ .signed = value } };
}

pub fn time_s(key: []const u8, value: i64) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{ .key = key, .field_type = .time_s, .value = .{ .signed = value } };
}

pub fn time_ns(key: []const u8, value: i64) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{ .key = key, .field_type = .time_ns, .value = .{ .signed = value } };
}

pub fn uintptr(key: []const u8, value: usize) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return uint64(key, @intCast(value));
}

pub fn binary(key: []const u8, value: []const u8) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{ .key = key, .field_type = .binary, .value = .{ .bytes = value } };
}

pub fn err(value: []const u8) Field {
    assert(value.len > 0);
    assert(value.len <= key_bytes_max);

    return .{ .key = "error", .field_type = .err, .value = .{ .text = value } };
}

pub fn named_err(key: []const u8, value: []const u8) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);
    assert(value.len > 0);

    return .{ .key = key, .field_type = .err, .value = .{ .text = value } };
}

pub fn err_from(value: anyerror) Field {
    return err(@errorName(value));
}

pub fn named_err_from(key: []const u8, value: anyerror) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return named_err(key, @errorName(value));
}

pub fn string_list(key: []const u8, value: []const []const u8) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);
    assert(value.len <= array_values_max);

    return .{ .key = key, .field_type = .string_list, .value = .{ .text_list = value } };
}

pub fn int_list(key: []const u8, value: []const i64) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);
    assert(value.len <= array_values_max);

    return .{ .key = key, .field_type = .int_list, .value = .{ .signed_list = value } };
}

pub fn uints(key: []const u8, value: []const u64) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);
    assert(value.len <= array_values_max);

    return .{ .key = key, .field_type = .uint_list, .value = .{ .unsigned_list = value } };
}

pub fn float_list(key: []const u8, value: []const f64) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);
    assert(value.len <= array_values_max);

    return .{ .key = key, .field_type = .float_list, .value = .{ .float_list = value } };
}

pub fn bool_list(key: []const u8, value: []const bool) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);
    assert(value.len <= array_values_max);

    return .{ .key = key, .field_type = .bool_list, .value = .{ .bool_list = value } };
}

pub fn durations(key: []const u8, value: []const i64) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);
    assert(value.len <= array_values_max);

    return .{ .key = key, .field_type = .duration_list, .value = .{ .signed_list = value } };
}

pub fn times(key: []const u8, value: []const i64) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);
    assert(value.len <= array_values_max);

    return .{ .key = key, .field_type = .time_list, .value = .{ .signed_list = value } };
}

pub fn namespace(key: []const u8) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{ .key = key, .field_type = .namespace, .value = .{ .none = {} } };
}

pub fn dict(key: []const u8, fields: []const Field) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);
    assert(fields.len <= fields_max);

    return .{ .key = key, .field_type = .dict, .value = .{ .field_list = fields } };
}

pub fn skip() Field {
    return .{ .key = "", .field_type = .skip, .value = .{ .none = {} } };
}

pub fn int(key: []const u8, value: i64) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return int64(key, value);
}

pub fn uint(key: []const u8, value: u64) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return uint64(key, value);
}

pub fn float(key: []const u8, value: f64) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return float64(key, value);
}

pub fn strings(key: []const u8, value: []const []const u8) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return string_list(key, value);
}

pub fn object(key: []const u8, value_pointer: anytype) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{
        .key = key,
        .field_type = .object,
        .value = .{ .marshal = .{
            .value = @ptrCast(value_pointer),
            .encode = .{ .object = marshal_object_thunk(@TypeOf(value_pointer)) },
        } },
    };
}

pub fn inline_object(value_pointer: anytype) Field {
    return .{
        .key = "",
        .field_type = .inline_object,
        .value = .{ .marshal = .{
            .value = @ptrCast(value_pointer),
            .encode = .{ .object = marshal_object_thunk(@TypeOf(value_pointer)) },
        } },
    };
}

pub fn array(key: []const u8, value_pointer: anytype) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{
        .key = key,
        .field_type = .array,
        .value = .{ .marshal = .{
            .value = @ptrCast(value_pointer),
            .encode = .{ .array = marshal_array_thunk(@TypeOf(value_pointer)) },
        } },
    };
}

pub fn reflect(key: []const u8, value_pointer: anytype) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return .{
        .key = key,
        .field_type = .reflect,
        .value = .{ .marshal = .{
            .value = @ptrCast(value_pointer),
            .encode = .{ .reflect = .{
                .field_fn = marshal_reflect_thunk(@TypeOf(value_pointer)),
                .value_fn = marshal_reflect_value_thunk(@TypeOf(value_pointer)),
            } },
        } },
    };
}

pub fn stringer(key: []const u8, value_pointer: anytype) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return string(key, value_pointer.to_string());
}

pub fn any(key: []const u8, value: anytype) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    return switch (@typeInfo(@TypeOf(value))) {
        .optional => any_optional(key, value),
        else => any_scalar(key, value),
    };
}

fn any_optional(key: []const u8, value: anytype) Field {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);

    if (value) |unwrapped| {
        return any_scalar(key, unwrapped);
    }

    return string(key, "null");
}

fn any_scalar(key: []const u8, value: anytype) Field {
    const T = @TypeOf(value);

    return switch (@typeInfo(T)) {
        .bool => boolean(key, value),
        .int => |info| any_int(key, value, info),
        .float => |info| any_float(key, value, info),
        .pointer => |info| any_pointer(key, value, info),
        .@"enum" => string(key, @tagName(value)),
        else => string(key, @typeName(T)),
    };
}

fn any_int(key: []const u8, value: anytype, comptime info: std.builtin.Type.Int) Field {
    if (info.signedness == .signed) {
        return switch (info.bits) {
            0...8 => int8(key, @intCast(value)),
            9...16 => int16(key, @intCast(value)),
            17...32 => int32(key, @intCast(value)),
            33...64 => int64(key, @intCast(value)),
            else => @compileError("signed integers wider than 64 bits are not supported"),
        };
    } else {
        return switch (info.bits) {
            0...8 => uint8(key, @intCast(value)),
            9...16 => uint16(key, @intCast(value)),
            17...32 => uint32(key, @intCast(value)),
            33...64 => uint64(key, @intCast(value)),
            else => @compileError("unsigned integers wider than 64 bits are not supported"),
        };
    }
}

fn any_float(key: []const u8, value: anytype, comptime info: std.builtin.Type.Float) Field {
    return switch (info.bits) {
        0...32 => float32(key, @floatCast(value)),
        else => float64(key, @floatCast(value)),
    };
}

fn any_pointer(key: []const u8, value: anytype, comptime info: std.builtin.Type.Pointer) Field {
    if (info.size == .slice and info.child == u8) {
        return string(key, value);
    }

    if (info.size == .slice and info.child == []const u8) {
        return string_list(key, value);
    }

    return string(key, @typeName(@TypeOf(value)));
}

fn marshal_object_thunk(comptime Pointer: type) MarshalObjectFn {
    const Child = @typeInfo(Pointer).pointer.child;

    return struct {
        fn call(value: *const anyopaque, encoder: *ObjectEncoder) void {
            const typed: *const Child = @ptrCast(@alignCast(value));
            typed.marshal_log_object(encoder);
        }
    }.call;
}

fn marshal_array_thunk(comptime Pointer: type) MarshalArrayFn {
    const Child = @typeInfo(Pointer).pointer.child;

    return struct {
        fn call(value: *const anyopaque, encoder: *ArrayEncoder) void {
            const typed: *const Child = @ptrCast(@alignCast(value));
            typed.marshal_log_array(encoder);
        }
    }.call;
}

fn marshal_reflect_thunk(comptime Pointer: type) MarshalReflectFn {
    const Child = @typeInfo(Pointer).pointer.child;

    return struct {
        fn call(
            value: *const anyopaque,
            state: *json_mod.EncodeState,
            buffer: *buffer_mod.Buffer,
            key: []const u8,
        ) void {
            const typed: *const Child = @ptrCast(@alignCast(value));
            json_mod.write_reflect_field(state, buffer, key, typed.*);
        }
    }.call;
}

fn marshal_reflect_value_thunk(comptime Pointer: type) MarshalReflectValueFn {
    const Child = @typeInfo(Pointer).pointer.child;

    return struct {
        fn call(value: *const anyopaque, buffer: *buffer_mod.Buffer) void {
            const typed: *const Child = @ptrCast(@alignCast(value));
            json_mod.write_reflect(buffer, typed.*, 0);
        }
    }.call;
}

const testing = std.testing;

test "string field has correct type and values" {
    const field = string("host", "localhost");

    try testing.expectEqualStrings("host", field.key);
    try testing.expectEqual(FieldType.string, field.field_type);
    try testing.expectEqualStrings("localhost", field.value.text);

    assert(field.key.len > 0);
    assert(field.value.text.len > 0);
}

test "boolean field has correct type and values" {
    const field_true = boolean("enabled", true);
    const field_false = boolean("enabled", false);

    try testing.expectEqual(FieldType.bool, field_true.field_type);
    try testing.expect(field_true.value.boolean);
    try testing.expect(!field_false.value.boolean);

    assert(field_true.key.len > 0);
    assert(field_true.value.boolean != field_false.value.boolean);
}

test "signed integer fields preserve values" {
    const field_i8 = int8("tiny", -42);
    const field_i16 = int16("small", -1000);
    const field_i32 = int32("medium", -100_000);
    const field_i64 = int64("large", -9_000_000_000);

    try testing.expectEqual(FieldType.int8, field_i8.field_type);
    try testing.expectEqual(@as(i64, -42), field_i8.value.signed);
    try testing.expectEqual(FieldType.int16, field_i16.field_type);
    try testing.expectEqual(@as(i64, -1000), field_i16.value.signed);
    try testing.expectEqual(FieldType.int32, field_i32.field_type);
    try testing.expectEqual(@as(i64, -100_000), field_i32.value.signed);
    try testing.expectEqual(FieldType.int64, field_i64.field_type);
    try testing.expectEqual(@as(i64, -9_000_000_000), field_i64.value.signed);

    assert(field_i8.value.signed < 0);
    assert(field_i64.value.signed < 0);
}

test "unsigned integer fields preserve values" {
    const field_u8 = uint8("tiny", 255);
    const field_u16 = uint16("small", 65535);
    const field_u32 = uint32("medium", 100_000);
    const field_u64 = uint64("large", 9_000_000_000);

    try testing.expectEqual(FieldType.uint8, field_u8.field_type);
    try testing.expectEqual(@as(u64, 255), field_u8.value.unsigned);
    try testing.expectEqual(FieldType.uint16, field_u16.field_type);
    try testing.expectEqual(@as(u64, 65535), field_u16.value.unsigned);
    try testing.expectEqual(FieldType.uint32, field_u32.field_type);
    try testing.expectEqual(@as(u64, 100_000), field_u32.value.unsigned);
    try testing.expectEqual(FieldType.uint64, field_u64.field_type);
    try testing.expectEqual(@as(u64, 9_000_000_000), field_u64.value.unsigned);

    assert(field_u8.value.unsigned == 255);
    assert(field_u64.value.unsigned > 0);
}

test "float fields preserve values" {
    const field_f32 = float32("ratio", 3.14);
    const field_f64 = float64("precise", 2.718281828459045);

    try testing.expectEqual(FieldType.float32, field_f32.field_type);
    try testing.expectEqual(FieldType.float64, field_f64.field_type);
    try testing.expectApproxEqAbs(@as(f64, 3.14), field_f32.value.float, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 2.718281828459045), field_f64.value.float, 1e-12);

    assert(field_f32.value.float > 0.0);
    assert(field_f64.value.float > 0.0);
}

test "duration_ns field stores nanoseconds" {
    const field = duration_ns("latency", 5_000_000_000);

    try testing.expectEqual(FieldType.duration_ns, field.field_type);
    try testing.expectEqual(@as(i64, 5_000_000_000), field.value.signed);

    assert(field.value.signed > 0);
    assert(field.key.len > 0);
}

test "time_s field stores epoch seconds" {
    const field = time_s("created_at", 1_700_000_000);

    try testing.expectEqual(FieldType.time_s, field.field_type);
    try testing.expectEqual(@as(i64, 1_700_000_000), field.value.signed);

    assert(field.value.signed > 0);
    assert(field.key.len > 0);
}

test "binary field stores raw bytes" {
    const data = &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const field = binary("payload", data);

    try testing.expectEqual(FieldType.binary, field.field_type);
    try testing.expectEqualSlices(u8, data, field.value.bytes);

    assert(field.value.bytes.len == 4);
    assert(field.key.len > 0);
}

test "err field uses error key" {
    const field = err("connection refused");

    try testing.expectEqualStrings("error", field.key);
    try testing.expectEqual(FieldType.err, field.field_type);
    try testing.expectEqualStrings("connection refused", field.value.text);

    assert(field.key.len > 0);
    assert(field.value.text.len > 0);
}

test "named_err field uses custom key" {
    const field = named_err("db_error", "timeout");

    try testing.expectEqualStrings("db_error", field.key);
    try testing.expectEqual(FieldType.err, field.field_type);
    try testing.expectEqualStrings("timeout", field.value.text);

    assert(field.key.len > 0);
    assert(field.value.text.len > 0);
}

test "string_list field stores slice" {
    const hosts = &[_][]const u8{ "host-a", "host-b", "host-c" };
    const field = string_list("hosts", hosts);

    try testing.expectEqual(FieldType.string_list, field.field_type);
    try testing.expectEqual(@as(usize, 3), field.value.text_list.len);
    try testing.expectEqualStrings("host-a", field.value.text_list[0]);
    try testing.expectEqualStrings("host-c", field.value.text_list[2]);

    assert(field.value.text_list.len <= array_values_max);
    assert(field.key.len > 0);
}

test "namespace field has correct type" {
    const field = namespace("request");

    try testing.expectEqualStrings("request", field.key);
    try testing.expectEqual(FieldType.namespace, field.field_type);

    assert(field.key.len > 0);
    assert(field.field_type == .namespace);
}

test "skip field has empty key" {
    const field = skip();

    try testing.expectEqualStrings("", field.key);
    try testing.expectEqual(FieldType.skip, field.field_type);

    assert(field.field_type == .skip);
    assert(field.key.len == 0);
}

test "int alias delegates to int64" {
    const field = int("count", 42);

    try testing.expectEqual(FieldType.int64, field.field_type);
    try testing.expectEqual(@as(i64, 42), field.value.signed);

    assert(field.value.signed == 42);
    assert(field.key.len > 0);
}

test "uint alias delegates to uint64" {
    const field = uint("count", 42);

    try testing.expectEqual(FieldType.uint64, field.field_type);
    try testing.expectEqual(@as(u64, 42), field.value.unsigned);

    assert(field.value.unsigned == 42);
    assert(field.key.len > 0);
}

test "float alias delegates to float64" {
    const field = float("ratio", 0.75);

    try testing.expectEqual(FieldType.float64, field.field_type);
    try testing.expectApproxEqAbs(@as(f64, 0.75), field.value.float, 1e-12);

    assert(field.value.float > 0.0);
    assert(field.key.len > 0);
}

test "any dispatches bool correctly" {
    const field = any("flag", true);

    try testing.expectEqual(FieldType.bool, field.field_type);
    try testing.expect(field.value.boolean);

    assert(field.key.len > 0);
    assert(field.field_type == .bool);
}

test "any dispatches signed int correctly" {
    const field = any("val", @as(i32, -99));

    try testing.expectEqual(FieldType.int32, field.field_type);
    try testing.expectEqual(@as(i64, -99), field.value.signed);

    assert(field.value.signed < 0);
    assert(field.key.len > 0);
}

test "any dispatches string slice correctly" {
    const field = any("name", @as([]const u8, "test"));

    try testing.expectEqual(FieldType.string, field.field_type);
    try testing.expectEqualStrings("test", field.value.text);

    assert(field.value.text.len > 0);
    assert(field.key.len > 0);
}
