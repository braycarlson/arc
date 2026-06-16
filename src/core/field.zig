const std = @import("std");
const buffer_mod = @import("../io/buffer.zig");
const json_mod = @import("../encoding/json.zig");

pub const ObjectEncoder = json_mod.ObjectEncoder;
pub const ArrayEncoder = json_mod.ArrayEncoder;

pub const fields_max: u32 = 32;
pub const key_max: u32 = 128;
pub const array_max: u32 = 64;

pub const MarshalObjectFn = *const fn (value: *const anyopaque, encoder: *ObjectEncoder) void;
pub const MarshalArrayFn = *const fn (value: *const anyopaque, encoder: *ArrayEncoder) void;
pub const MarshalReflectFn = json_mod.MarshalReflectFn;
pub const MarshalReflectValueFn = json_mod.MarshalReflectValueFn;

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

pub const Marshal = struct {
    value: *const anyopaque,
    object_fn: ?MarshalObjectFn = null,
    array_fn: ?MarshalArrayFn = null,
    reflect_fn: ?MarshalReflectFn = null,
    reflect_value_fn: ?MarshalReflectValueFn = null,
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

pub const Field = struct {
    key: []const u8,
    field_type: FieldType,
    value: FieldValue,
};

pub fn string(key: []const u8, value: []const u8) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{ .key = key, .field_type = .string, .value = .{ .text = value } };
}

pub fn byte_string(key: []const u8, value: []const u8) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{ .key = key, .field_type = .byte_string, .value = .{ .text = value } };
}

pub fn boolean(key: []const u8, value: bool) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{ .key = key, .field_type = .bool, .value = .{ .boolean = value } };
}

pub fn int8(key: []const u8, value: i8) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{ .key = key, .field_type = .int8, .value = .{ .signed = @intCast(value) } };
}

pub fn int16(key: []const u8, value: i16) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{ .key = key, .field_type = .int16, .value = .{ .signed = @intCast(value) } };
}

pub fn int32(key: []const u8, value: i32) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{ .key = key, .field_type = .int32, .value = .{ .signed = @intCast(value) } };
}

pub fn int64(key: []const u8, value: i64) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{ .key = key, .field_type = .int64, .value = .{ .signed = value } };
}

pub fn uint8(key: []const u8, value: u8) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{ .key = key, .field_type = .uint8, .value = .{ .unsigned = @intCast(value) } };
}

pub fn uint16(key: []const u8, value: u16) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{ .key = key, .field_type = .uint16, .value = .{ .unsigned = @intCast(value) } };
}

pub fn uint32(key: []const u8, value: u32) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{ .key = key, .field_type = .uint32, .value = .{ .unsigned = @intCast(value) } };
}

pub fn uint64(key: []const u8, value: u64) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{ .key = key, .field_type = .uint64, .value = .{ .unsigned = value } };
}

pub fn float32(key: []const u8, value: f32) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{ .key = key, .field_type = .float32, .value = .{ .float = @floatCast(value) } };
}

pub fn float64(key: []const u8, value: f64) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{ .key = key, .field_type = .float64, .value = .{ .float = value } };
}

pub fn duration_ns(key: []const u8, value: i64) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{ .key = key, .field_type = .duration_ns, .value = .{ .signed = value } };
}

pub fn time_s(key: []const u8, value: i64) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{ .key = key, .field_type = .time_s, .value = .{ .signed = value } };
}

pub fn time_ns(key: []const u8, value: i64) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{ .key = key, .field_type = .time_ns, .value = .{ .signed = value } };
}

pub fn uintptr(key: []const u8, value: usize) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return uint64(key, @intCast(value));
}

pub fn binary(key: []const u8, value: []const u8) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{ .key = key, .field_type = .binary, .value = .{ .bytes = value } };
}

pub fn err(value: []const u8) Field {
    std.debug.assert(value.len > 0);
    std.debug.assert(value.len <= key_max);

    return .{ .key = "error", .field_type = .err, .value = .{ .text = value } };
}

pub fn named_err(key: []const u8, value: []const u8) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);
    std.debug.assert(value.len > 0);

    return .{ .key = key, .field_type = .err, .value = .{ .text = value } };
}

pub fn err_from(value: anyerror) Field {
    return err(@errorName(value));
}

pub fn named_err_from(key: []const u8, value: anyerror) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return named_err(key, @errorName(value));
}

pub fn string_list(key: []const u8, value: []const []const u8) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);
    std.debug.assert(value.len <= array_max);

    return .{ .key = key, .field_type = .string_list, .value = .{ .text_list = value } };
}

pub fn int_list(key: []const u8, value: []const i64) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);
    std.debug.assert(value.len <= array_max);

    return .{ .key = key, .field_type = .int_list, .value = .{ .signed_list = value } };
}

pub fn uints(key: []const u8, value: []const u64) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);
    std.debug.assert(value.len <= array_max);

    return .{ .key = key, .field_type = .uint_list, .value = .{ .unsigned_list = value } };
}

pub fn float_list(key: []const u8, value: []const f64) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);
    std.debug.assert(value.len <= array_max);

    return .{ .key = key, .field_type = .float_list, .value = .{ .float_list = value } };
}

pub fn bool_list(key: []const u8, value: []const bool) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);
    std.debug.assert(value.len <= array_max);

    return .{ .key = key, .field_type = .bool_list, .value = .{ .bool_list = value } };
}

pub fn durations(key: []const u8, value: []const i64) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);
    std.debug.assert(value.len <= array_max);

    return .{ .key = key, .field_type = .duration_list, .value = .{ .signed_list = value } };
}

pub fn times(key: []const u8, value: []const i64) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);
    std.debug.assert(value.len <= array_max);

    return .{ .key = key, .field_type = .time_list, .value = .{ .signed_list = value } };
}

pub fn namespace(key: []const u8) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{ .key = key, .field_type = .namespace, .value = .{ .none = {} } };
}

pub fn dict(key: []const u8, fields: []const Field) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);
    std.debug.assert(fields.len <= fields_max);

    return .{ .key = key, .field_type = .dict, .value = .{ .field_list = fields } };
}

pub fn skip() Field {
    return .{ .key = "", .field_type = .skip, .value = .{ .none = {} } };
}

pub fn int(key: []const u8, value: i64) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return int64(key, value);
}

pub fn uint(key: []const u8, value: u64) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return uint64(key, value);
}

pub fn float(key: []const u8, value: f64) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return float64(key, value);
}

pub fn strings(key: []const u8, value: []const []const u8) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return string_list(key, value);
}

pub fn object(key: []const u8, value_pointer: anytype) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{
        .key = key,
        .field_type = .object,
        .value = .{ .marshal = .{
            .value = @ptrCast(value_pointer),
            .object_fn = marshal_object_thunk(@TypeOf(value_pointer)),
        } },
    };
}

pub fn inline_object(value_pointer: anytype) Field {
    return .{
        .key = "",
        .field_type = .inline_object,
        .value = .{ .marshal = .{
            .value = @ptrCast(value_pointer),
            .object_fn = marshal_object_thunk(@TypeOf(value_pointer)),
        } },
    };
}

pub fn array(key: []const u8, value_pointer: anytype) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{
        .key = key,
        .field_type = .array,
        .value = .{ .marshal = .{
            .value = @ptrCast(value_pointer),
            .array_fn = marshal_array_thunk(@TypeOf(value_pointer)),
        } },
    };
}

pub fn reflect(key: []const u8, value_pointer: anytype) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return .{
        .key = key,
        .field_type = .reflect,
        .value = .{ .marshal = .{
            .value = @ptrCast(value_pointer),
            .reflect_fn = marshal_reflect_thunk(@TypeOf(value_pointer)),
            .reflect_value_fn = marshal_reflect_value_thunk(@TypeOf(value_pointer)),
        } },
    };
}

pub fn stringer(key: []const u8, value_pointer: anytype) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return string(key, value_pointer.to_string());
}

pub fn any(key: []const u8, value: anytype) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

    return switch (@typeInfo(@TypeOf(value))) {
        .optional => any_optional(key, value),
        else => any_scalar(key, value),
    };
}

fn any_optional(key: []const u8, value: anytype) Field {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_max);

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

fn any_int(key: []const u8, value: anytype, info: std.builtin.Type.Int) Field {
    if (info.signedness == .signed) {
        return switch (info.bits) {
            0...8 => int8(key, @intCast(value)),
            9...16 => int16(key, @intCast(value)),
            17...32 => int32(key, @intCast(value)),
            else => int64(key, @intCast(value)),
        };
    } else {
        return switch (info.bits) {
            0...8 => uint8(key, @intCast(value)),
            9...16 => uint16(key, @intCast(value)),
            17...32 => uint32(key, @intCast(value)),
            else => uint64(key, @intCast(value)),
        };
    }
}

fn any_float(key: []const u8, value: anytype, info: std.builtin.Type.Float) Field {
    return switch (info.bits) {
        0...32 => float32(key, @floatCast(value)),
        else => float64(key, @floatCast(value)),
    };
}

fn any_pointer(key: []const u8, value: anytype, info: std.builtin.Type.Pointer) Field {
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
            json_mod.write_reflect(buffer, typed.*);
        }
    }.call;
}
