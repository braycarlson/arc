const std = @import("std");
const buffer_mod = @import("../io/buffer.zig");
const encoder_config_mod = @import("config.zig");
const entry_mod = @import("../core/entry.zig");
const field_mod = @import("../core/field.zig");
const datetime = @import("datetime.zig");
const base64 = @import("base64.zig");

const Buffer = buffer_mod.Buffer;
const EncoderConfig = encoder_config_mod.EncoderConfig;
const Entry = entry_mod.Entry;
const Field = field_mod.Field;

pub const namespace_depth_max: u32 = 8;
pub const marshal_depth_max: u32 = 8;
pub const reflect_array_max: u32 = 256;

const nanos_per_second: i64 = 1_000_000_000;
const nanos_per_milli: i64 = 1_000_000;

const hex_digits = "0123456789abcdef";

const escape_lane_count = 16;

pub const truncation_message = "log entry exceeded buffer capacity and was dropped";
const truncation_key = "arc_truncated";

pub const EncodeState = struct {
    field_count: u32,
    namespace_depth: u32,

    pub fn init() EncodeState {
        return .{
            .field_count = 0,
            .namespace_depth = 0,
        };
    }
};

pub const MarshalReflectFn = *const fn (
    value: *const anyopaque,
    state: *EncodeState,
    buffer: *Buffer,
    key: []const u8,
) void;

pub const MarshalReflectValueFn = *const fn (value: *const anyopaque, buffer: *Buffer) void;

pub const ObjectEncoder = struct {
    state: *EncodeState,
    buffer: *Buffer,
    config: *const EncoderConfig,
    depth: u32,

    pub fn add_string(self: *ObjectEncoder, key: []const u8, value: []const u8) void {
        write_string_value(self.state, self.buffer, key, value);
    }

    pub fn add_int(self: *ObjectEncoder, key: []const u8, value: i64) void {
        write_int_value(self.state, self.buffer, key, value);
    }

    pub fn add_uint(self: *ObjectEncoder, key: []const u8, value: u64) void {
        write_uint_value(self.state, self.buffer, key, value);
    }

    pub fn add_float(self: *ObjectEncoder, key: []const u8, value: f64) void {
        write_float_value(self.state, self.buffer, key, value);
    }

    pub fn add_bool(self: *ObjectEncoder, key: []const u8, value: bool) void {
        write_bool_value(self.state, self.buffer, key, value);
    }

    pub fn add_binary(self: *ObjectEncoder, key: []const u8, value: []const u8) void {
        write_binary_value(self.state, self.buffer, key, value);
    }

    pub fn add_byte_string(self: *ObjectEncoder, key: []const u8, value: []const u8) void {
        write_string_value(self.state, self.buffer, key, value);
    }

    pub fn add_duration_ns(self: *ObjectEncoder, key: []const u8, value: i64) void {
        encode_duration(self.config, self.state, self.buffer, key, value);
    }

    pub fn add_time_ns(self: *ObjectEncoder, key: []const u8, value: i64) void {
        encode_time_value(self.config, self.state, self.buffer, key, value);
    }

    pub fn open_namespace(self: *ObjectEncoder, key: []const u8) void {
        write_namespace_open(self.state, self.buffer, key);
    }

    pub fn add_object(self: *ObjectEncoder, key: []const u8, value_pointer: anytype) void {
        std.debug.assert(key.len > 0);

        if (self.depth >= marshal_depth_max) {
            return;
        }

        write_separator(self.state, self.buffer);
        write_quoted(self.buffer, key);
        self.buffer.append_byte(':');

        encode_object(self.buffer, self.config, value_pointer, self.depth + 1);
    }

    pub fn add_array(self: *ObjectEncoder, key: []const u8, value_pointer: anytype) void {
        std.debug.assert(key.len > 0);

        if (self.depth >= marshal_depth_max) {
            return;
        }

        write_separator(self.state, self.buffer);
        write_quoted(self.buffer, key);
        self.buffer.append_byte(':');

        encode_array(self.buffer, self.config, value_pointer, self.depth + 1);
    }

    pub fn add_reflect(self: *ObjectEncoder, key: []const u8, value: anytype) void {
        write_reflect_field(self.state, self.buffer, key, value);
    }
};

pub const ArrayEncoder = struct {
    state: *EncodeState,
    buffer: *Buffer,
    config: *const EncoderConfig,
    depth: u32,

    pub fn append_string(self: *ArrayEncoder, value: []const u8) void {
        write_separator(self.state, self.buffer);
        write_quoted(self.buffer, value);
    }

    pub fn append_int(self: *ArrayEncoder, value: i64) void {
        write_separator(self.state, self.buffer);
        self.buffer.append_integer(value);
    }

    pub fn append_uint(self: *ArrayEncoder, value: u64) void {
        write_separator(self.state, self.buffer);
        self.buffer.append_unsigned(value);
    }

    pub fn append_float(self: *ArrayEncoder, value: f64) void {
        write_separator(self.state, self.buffer);
        write_json_float(self.buffer, value);
    }

    pub fn append_bool(self: *ArrayEncoder, value: bool) void {
        write_separator(self.state, self.buffer);
        self.buffer.append_slice(if (value) "true" else "false");
    }

    pub fn append_object(self: *ArrayEncoder, value_pointer: anytype) void {
        if (self.depth >= marshal_depth_max) {
            return;
        }

        write_separator(self.state, self.buffer);
        encode_object(self.buffer, self.config, value_pointer, self.depth + 1);
    }

    pub fn append_array(self: *ArrayEncoder, value_pointer: anytype) void {
        if (self.depth >= marshal_depth_max) {
            return;
        }

        write_separator(self.state, self.buffer);
        encode_array(self.buffer, self.config, value_pointer, self.depth + 1);
    }

    pub fn append_reflect(self: *ArrayEncoder, value: anytype) void {
        write_separator(self.state, self.buffer);
        write_reflect(self.buffer, value);
    }
};

pub const JsonEncoder = struct {
    config: EncoderConfig,

    pub fn init(config: EncoderConfig) JsonEncoder {
        return .{ .config = config };
    }

    pub fn encode_entry(
        self: *const JsonEncoder,
        state: *EncodeState,
        buffer: *Buffer,
        entry: *const Entry,
        context_fields: []const Field,
        call_fields: []const Field,
    ) void {
        std.debug.assert(context_fields.len <= field_mod.fields_max);
        std.debug.assert(call_fields.len <= field_mod.fields_max);

        state.field_count = 0;
        state.namespace_depth = 0;
        buffer.reset();

        buffer.append_byte('{');
        self.encode_entry_metadata(state, buffer, entry);

        if (entry.context_cache) |cache| {
            splice_context_cache(state, buffer, cache);
        } else {
            encode_fields(state, buffer, &self.config, context_fields);
        }

        encode_fields(state, buffer, &self.config, call_fields);
        close_namespaces(state, buffer);

        if (entry.has_stack() and !self.config.should_omit_stacktrace()) {
            write_string_value(state, buffer, self.config.key_stacktrace, entry.stack());
        }

        buffer.append_byte('}');

        if (self.config.line_ending == .newline) {
            buffer.append_byte('\n');
        }

        std.debug.assert(buffer.len() >= 2);
    }

    fn encode_entry_metadata(
        self: *const JsonEncoder,
        state: *EncodeState,
        buffer: *Buffer,
        entry: *const Entry,
    ) void {
        if (!self.config.should_omit_level()) {
            write_string_value(
                state,
                buffer,
                self.config.key_level,
                self.config.level_string(entry.level),
            );
        }

        if (!self.config.should_omit_time()) {
            encode_time_value(
                &self.config,
                state,
                buffer,
                self.config.key_time,
                entry.timestamp_ns,
            );
        }

        if (entry.logger_name.len > 0 and !self.config.should_omit_name()) {
            write_string_value(state, buffer, self.config.key_name, entry.logger_name);
        }

        if (entry.caller.defined and !self.config.should_omit_caller()) {
            self.encode_caller(state, buffer, &entry.caller);
        }

        if (entry.caller.defined and !self.config.should_omit_function()) {
            if (entry.caller.function.len > 0) {
                write_string_value(state, buffer, self.config.key_function, entry.caller.function);
            }
        }

        if (!self.config.should_omit_message()) {
            write_string_value(state, buffer, self.config.key_message, entry.message);
        }
    }

    fn encode_caller(
        self: *const JsonEncoder,
        state: *EncodeState,
        buffer: *Buffer,
        caller: *const entry_mod.Caller,
    ) void {
        std.debug.assert(caller.defined);
        std.debug.assert(caller.file.len > 0);

        write_separator(state, buffer);
        write_quoted(buffer, self.config.key_caller);
        buffer.append_byte(':');
        buffer.append_byte('"');

        switch (self.config.encode_caller) {
            .full_path => write_escaped(buffer, caller.file),
            .short_path => write_short_caller(buffer, caller.file),
        }

        buffer.append_byte(':');
        buffer.append_unsigned(@intCast(caller.line));
        buffer.append_byte('"');
    }

    pub fn encode_truncation_notice(self: *const JsonEncoder, buffer: *Buffer, entry: *const Entry) void {
        buffer.reset();

        var state = EncodeState.init();

        buffer.append_byte('{');

        if (!self.config.should_omit_level()) {
            write_string_value(
                &state,
                buffer,
                self.config.key_level,
                self.config.level_string(entry.level),
            );
        }

        if (!self.config.should_omit_message()) {
            write_string_value(&state, buffer, self.config.key_message, truncation_message);
        }

        write_bool_value(&state, buffer, truncation_key, true);

        buffer.append_byte('}');

        if (self.config.line_ending == .newline) {
            buffer.append_byte('\n');
        }

        std.debug.assert(!buffer.was_truncated());
    }
};

pub fn encode_fields(
    state: *EncodeState,
    buffer: *Buffer,
    config: *const EncoderConfig,
    fields: []const Field,
) void {
    std.debug.assert(fields.len <= field_mod.fields_max);

    for (fields) |field| {
        encode_field(state, buffer, config, &field, 0);
    }
}

pub const ContextFragment = struct {
    field_count: u32,
    namespace_depth: u32,
};

pub fn encode_context_fragment(
    buffer: *Buffer,
    config: *const EncoderConfig,
    fields: []const Field,
) ContextFragment {
    std.debug.assert(fields.len > 0);
    std.debug.assert(fields.len <= field_mod.fields_max);

    var state = EncodeState.init();

    encode_fields(&state, buffer, config, fields);

    return .{ .field_count = state.field_count, .namespace_depth = state.namespace_depth };
}

fn splice_context_cache(state: *EncodeState, buffer: *Buffer, cache: entry_mod.ContextCache) void {
    std.debug.assert(cache.bytes.len > 0);
    std.debug.assert(cache.namespace_depth <= namespace_depth_max);

    if (state.field_count > 0) {
        buffer.append_byte(',');
    }

    buffer.append_slice(cache.bytes);
    state.field_count = cache.field_count;
    state.namespace_depth = cache.namespace_depth;
}

pub fn encode_field(
    state: *EncodeState,
    buffer: *Buffer,
    config: *const EncoderConfig,
    field: *const Field,
    depth: u32,
) void {
    if (depth > marshal_depth_max) {
        return;
    }

    switch (field.field_type) {
        .skip => {},
        .string => write_string_value(state, buffer, field.key, field.value.text),
        .byte_string => write_string_value(state, buffer, field.key, field.value.text),
        .bool => write_bool_value(state, buffer, field.key, field.value.boolean),
        .int8, .int16, .int32, .int64 => write_int_value(
            state,
            buffer,
            field.key,
            field.value.signed,
        ),
        .uint8, .uint16, .uint32, .uint64 => write_uint_value(
            state,
            buffer,
            field.key,
            field.value.unsigned,
        ),
        .float32, .float64 => write_float_value(state, buffer, field.key, field.value.float),
        .duration_ns => encode_duration(config, state, buffer, field.key, field.value.signed),
        .time_s => encode_time_value(
            config,
            state,
            buffer,
            field.key,
            field.value.signed *| nanos_per_second,
        ),
        .time_ns => encode_time_value(config, state, buffer, field.key, field.value.signed),
        .binary => write_binary_value(state, buffer, field.key, field.value.bytes),
        .err => write_string_value(state, buffer, field.key, field.value.text),
        .string_list => write_string_list(state, buffer, field.key, field.value.text_list),
        .int_list => write_int_list(state, buffer, field.key, field.value.signed_list),
        .uint_list => write_uint_list(state, buffer, field.key, field.value.unsigned_list),
        .float_list => write_float_list(state, buffer, field.key, field.value.float_list),
        .bool_list => write_bool_list(state, buffer, field.key, field.value.bool_list),
        .duration_list => write_duration_list(
            config,
            state,
            buffer,
            field.key,
            field.value.signed_list,
        ),
        .time_list => write_time_list(config, state, buffer, field.key, field.value.signed_list),
        .namespace => write_namespace_open(state, buffer, field.key),
        .object => encode_object_field(state, buffer, config, field, depth),
        .inline_object => encode_inline_field(state, buffer, config, field, depth),
        .array => encode_array_field(state, buffer, config, field, depth),
        .dict => encode_dict_field(state, buffer, config, field, depth),
        .reflect => encode_reflect_field(state, buffer, field),
    }
}

fn encode_object_field(
    state: *EncodeState,
    buffer: *Buffer,
    config: *const EncoderConfig,
    field: *const Field,
    depth: u32,
) void {
    std.debug.assert(field.key.len > 0);
    std.debug.assert(depth <= marshal_depth_max);
    std.debug.assert(field.value.marshal.object_fn != null);

    write_separator(state, buffer);
    write_quoted(buffer, field.key);
    buffer.append_byte(':');

    write_object_value(buffer, config, field, depth);
}

pub fn write_object_value(
    buffer: *Buffer,
    config: *const EncoderConfig,
    field: *const Field,
    depth: u32,
) void {
    std.debug.assert(depth <= marshal_depth_max);
    std.debug.assert(field.value.marshal.object_fn != null);

    var sub_state = EncodeState.init();

    buffer.append_byte('{');
    var encoder = ObjectEncoder{
        .state = &sub_state,
        .buffer = buffer,
        .config = config,
        .depth = depth + 1,
    };
    field.value.marshal.object_fn.?(field.value.marshal.value, &encoder);
    close_namespaces(&sub_state, buffer);
    buffer.append_byte('}');
}

fn encode_inline_field(
    state: *EncodeState,
    buffer: *Buffer,
    config: *const EncoderConfig,
    field: *const Field,
    depth: u32,
) void {
    std.debug.assert(depth <= marshal_depth_max);
    std.debug.assert(field.value.marshal.object_fn != null);

    var encoder = ObjectEncoder{
        .state = state,
        .buffer = buffer,
        .config = config,
        .depth = depth + 1,
    };
    field.value.marshal.object_fn.?(field.value.marshal.value, &encoder);
}

fn encode_array_field(
    state: *EncodeState,
    buffer: *Buffer,
    config: *const EncoderConfig,
    field: *const Field,
    depth: u32,
) void {
    std.debug.assert(field.key.len > 0);
    std.debug.assert(depth <= marshal_depth_max);
    std.debug.assert(field.value.marshal.array_fn != null);

    write_separator(state, buffer);
    write_quoted(buffer, field.key);
    buffer.append_byte(':');

    write_array_value(buffer, config, field, depth);
}

pub fn write_array_value(
    buffer: *Buffer,
    config: *const EncoderConfig,
    field: *const Field,
    depth: u32,
) void {
    std.debug.assert(depth <= marshal_depth_max);
    std.debug.assert(field.value.marshal.array_fn != null);

    var sub_state = EncodeState.init();

    buffer.append_byte('[');
    var encoder = ArrayEncoder{
        .state = &sub_state,
        .buffer = buffer,
        .config = config,
        .depth = depth + 1,
    };
    field.value.marshal.array_fn.?(field.value.marshal.value, &encoder);
    buffer.append_byte(']');
}

fn encode_reflect_field(state: *EncodeState, buffer: *Buffer, field: *const Field) void {
    std.debug.assert(field.key.len > 0);
    std.debug.assert(field.value.marshal.reflect_fn != null);

    field.value.marshal.reflect_fn.?(field.value.marshal.value, state, buffer, field.key);
}

pub fn write_reflect_field(
    state: *EncodeState,
    buffer: *Buffer,
    key: []const u8,
    value: anytype,
) void {
    std.debug.assert(key.len > 0);

    write_separator(state, buffer);
    write_quoted(buffer, key);
    buffer.append_byte(':');
    write_reflect(buffer, value);
}

pub fn write_reflect(buffer: *Buffer, value: anytype) void {
    const T = @TypeOf(value);

    switch (@typeInfo(T)) {
        .bool => buffer.append_slice(if (value) "true" else "false"),
        .int => |info| {
            if (info.signedness == .signed) {
                buffer.append_integer(@intCast(value));
            } else {
                buffer.append_unsigned(@intCast(value));
            }
        },
        .comptime_int => buffer.append_integer(@intCast(value)),
        .float => write_json_float(buffer, @floatCast(value)),
        .comptime_float => write_json_float(buffer, @as(f64, value)),
        .@"enum" => write_quoted(buffer, @tagName(value)),
        .enum_literal => write_quoted(buffer, @tagName(value)),
        .null => buffer.append_slice("null"),
        .optional => {
            if (value) |unwrapped| {
                write_reflect(buffer, unwrapped);
            } else {
                buffer.append_slice("null");
            }
        },
        .@"struct" => |info| {
            buffer.append_byte('{');

            inline for (info.fields, 0..) |struct_field, index| {
                if (index > 0) buffer.append_byte(',');
                write_quoted(buffer, struct_field.name);
                buffer.append_byte(':');
                write_reflect(buffer, @field(value, struct_field.name));
            }

            buffer.append_byte('}');
        },
        .array => {
            buffer.append_byte('[');

            for (value, 0..) |element, index| {
                if (index > 0) buffer.append_byte(',');
                write_reflect(buffer, element);
            }

            buffer.append_byte(']');
        },
        .pointer => |info| write_reflect_pointer(buffer, value, info),
        else => write_quoted(buffer, @typeName(T)),
    }
}

fn write_reflect_pointer(
    buffer: *Buffer,
    value: anytype,
    comptime info: std.builtin.Type.Pointer,
) void {
    if (info.size == .slice) {
        if (info.child == u8) {
            write_quoted(buffer, value);
            return;
        }

        buffer.append_byte('[');

        for (value, 0..) |element, index| {
            if (index >= reflect_array_max) break;
            if (index > 0) buffer.append_byte(',');
            write_reflect(buffer, element);
        }

        buffer.append_byte(']');
        return;
    }

    if (info.size == .one) {
        write_reflect(buffer, value.*);
        return;
    }

    write_quoted(buffer, @typeName(@TypeOf(value)));
}

fn encode_dict_field(
    state: *EncodeState,
    buffer: *Buffer,
    config: *const EncoderConfig,
    field: *const Field,
    depth: u32,
) void {
    std.debug.assert(field.key.len > 0);
    std.debug.assert(depth <= marshal_depth_max);
    std.debug.assert(field.value.field_list.len <= field_mod.fields_max);

    write_separator(state, buffer);
    write_quoted(buffer, field.key);
    buffer.append_byte(':');

    write_dict_value(buffer, config, field, depth);
}

pub fn write_dict_value(
    buffer: *Buffer,
    config: *const EncoderConfig,
    field: *const Field,
    depth: u32,
) void {
    std.debug.assert(depth <= marshal_depth_max);
    std.debug.assert(field.value.field_list.len <= field_mod.fields_max);

    var sub_state = EncodeState.init();

    buffer.append_byte('{');

    for (field.value.field_list) |sub_field| {
        encode_field(&sub_state, buffer, config, &sub_field, depth + 1);
    }

    close_namespaces(&sub_state, buffer);
    buffer.append_byte('}');
}

fn encode_object(
    buffer: *Buffer,
    config: *const EncoderConfig,
    value_pointer: anytype,
    depth: u32,
) void {
    if (depth > marshal_depth_max) {
        buffer.append_slice("{}");
        return;
    }

    var sub_state = EncodeState.init();

    buffer.append_byte('{');
    var encoder = ObjectEncoder{
        .state = &sub_state,
        .buffer = buffer,
        .config = config,
        .depth = depth,
    };
    value_pointer.marshal_log_object(&encoder);
    close_namespaces(&sub_state, buffer);
    buffer.append_byte('}');
}

fn encode_array(
    buffer: *Buffer,
    config: *const EncoderConfig,
    value_pointer: anytype,
    depth: u32,
) void {
    if (depth > marshal_depth_max) {
        buffer.append_slice("[]");
        return;
    }

    var sub_state = EncodeState.init();

    buffer.append_byte('[');
    var encoder = ArrayEncoder{
        .state = &sub_state,
        .buffer = buffer,
        .config = config,
        .depth = depth,
    };
    value_pointer.marshal_log_array(&encoder);
    buffer.append_byte(']');
}

fn encode_duration(
    config: *const EncoderConfig,
    state: *EncodeState,
    buffer: *Buffer,
    key: []const u8,
    nanoseconds: i64,
) void {
    std.debug.assert(key.len > 0);

    switch (config.encode_duration) {
        .seconds => {
            write_separator(state, buffer);
            write_quoted(buffer, key);
            buffer.append_byte(':');
            const seconds: f64 = @as(f64, @floatFromInt(nanoseconds)) / 1_000_000_000.0;
            buffer.append_float(seconds);
        },
        .millis => write_int_value(state, buffer, key, @divTrunc(nanoseconds, 1_000_000)),
        .nanos => write_int_value(state, buffer, key, nanoseconds),
        .string => {
            write_separator(state, buffer);
            write_quoted(buffer, key);
            buffer.append_byte(':');
            buffer.append_byte('"');
            datetime.write_duration_string(buffer, nanoseconds);
            buffer.append_byte('"');
        },
    }
}

fn encode_time_value(
    config: *const EncoderConfig,
    state: *EncodeState,
    buffer: *Buffer,
    key: []const u8,
    timestamp_ns: i64,
) void {
    std.debug.assert(key.len > 0);

    switch (config.encode_time) {
        .epoch_s => {
            write_separator(state, buffer);
            write_quoted(buffer, key);
            buffer.append_byte(':');
            datetime.write_epoch_scaled(buffer, timestamp_ns, nanos_per_second, 9);
        },
        .epoch_ms => {
            write_separator(state, buffer);
            write_quoted(buffer, key);
            buffer.append_byte(':');
            datetime.write_epoch_scaled(buffer, timestamp_ns, nanos_per_milli, 6);
        },
        .epoch_ns => write_int_value(state, buffer, key, timestamp_ns),
        .iso8601, .rfc3339 => {
            write_separator(state, buffer);
            write_quoted(buffer, key);
            buffer.append_byte(':');
            buffer.append_byte('"');
            datetime.write_iso8601(buffer, timestamp_ns, config.time_offset_minutes);
            buffer.append_byte('"');
        },
        .rfc3339_nano => {
            write_separator(state, buffer);
            write_quoted(buffer, key);
            buffer.append_byte(':');
            buffer.append_byte('"');
            datetime.write_iso8601_nano(buffer, timestamp_ns, config.time_offset_minutes);
            buffer.append_byte('"');
        },
    }
}

fn write_string_value(
    state: *EncodeState,
    buffer: *Buffer,
    key: []const u8,
    value: []const u8,
) void {
    std.debug.assert(key.len > 0);

    write_separator(state, buffer);
    write_quoted(buffer, key);
    buffer.append_byte(':');
    write_quoted(buffer, value);
}

fn write_int_value(state: *EncodeState, buffer: *Buffer, key: []const u8, value: i64) void {
    std.debug.assert(key.len > 0);

    write_separator(state, buffer);
    write_quoted(buffer, key);
    buffer.append_byte(':');
    buffer.append_integer(value);
}

fn write_uint_value(state: *EncodeState, buffer: *Buffer, key: []const u8, value: u64) void {
    std.debug.assert(key.len > 0);

    write_separator(state, buffer);
    write_quoted(buffer, key);
    buffer.append_byte(':');
    buffer.append_unsigned(value);
}

fn write_float_value(state: *EncodeState, buffer: *Buffer, key: []const u8, value: f64) void {
    std.debug.assert(key.len > 0);

    write_separator(state, buffer);
    write_quoted(buffer, key);
    buffer.append_byte(':');
    write_json_float(buffer, value);
}

fn write_bool_value(state: *EncodeState, buffer: *Buffer, key: []const u8, value: bool) void {
    std.debug.assert(key.len > 0);

    write_separator(state, buffer);
    write_quoted(buffer, key);
    buffer.append_byte(':');
    buffer.append_slice(if (value) "true" else "false");
}

fn write_binary_value(
    state: *EncodeState,
    buffer: *Buffer,
    key: []const u8,
    data: []const u8,
) void {
    std.debug.assert(key.len > 0);

    write_separator(state, buffer);
    write_quoted(buffer, key);
    buffer.append_byte(':');
    buffer.append_byte('"');
    base64.encode_base64(buffer, data);
    buffer.append_byte('"');
}

pub fn write_json_float(buffer: *Buffer, value: f64) void {
    if (std.math.isNan(value)) {
        buffer.append_slice("\"NaN\"");
        return;
    }

    if (std.math.isPositiveInf(value)) {
        buffer.append_slice("\"+Inf\"");
        return;
    }

    if (std.math.isNegativeInf(value)) {
        buffer.append_slice("\"-Inf\"");
        return;
    }

    buffer.append_float(value);
}

fn write_string_list(
    state: *EncodeState,
    buffer: *Buffer,
    key: []const u8,
    values: []const []const u8,
) void {
    std.debug.assert(key.len > 0);
    std.debug.assert(values.len <= field_mod.array_max);

    write_separator(state, buffer);
    write_quoted(buffer, key);
    buffer.append_byte(':');
    buffer.append_byte('[');

    for (values, 0..) |value, index| {
        if (index > 0) buffer.append_byte(',');
        write_quoted(buffer, value);
    }

    buffer.append_byte(']');
}

fn write_int_list(state: *EncodeState, buffer: *Buffer, key: []const u8, values: []const i64) void {
    std.debug.assert(key.len > 0);
    std.debug.assert(values.len <= field_mod.array_max);

    write_separator(state, buffer);
    write_quoted(buffer, key);
    buffer.append_byte(':');
    buffer.append_byte('[');

    for (values, 0..) |value, index| {
        if (index > 0) buffer.append_byte(',');
        buffer.append_integer(value);
    }

    buffer.append_byte(']');
}

fn write_uint_list(
    state: *EncodeState,
    buffer: *Buffer,
    key: []const u8,
    values: []const u64,
) void {
    std.debug.assert(key.len > 0);
    std.debug.assert(values.len <= field_mod.array_max);

    write_separator(state, buffer);
    write_quoted(buffer, key);
    buffer.append_byte(':');
    buffer.append_byte('[');

    for (values, 0..) |value, index| {
        if (index > 0) buffer.append_byte(',');
        buffer.append_unsigned(value);
    }

    buffer.append_byte(']');
}

fn write_float_list(
    state: *EncodeState,
    buffer: *Buffer,
    key: []const u8,
    values: []const f64,
) void {
    std.debug.assert(key.len > 0);
    std.debug.assert(values.len <= field_mod.array_max);

    write_separator(state, buffer);
    write_quoted(buffer, key);
    buffer.append_byte(':');
    buffer.append_byte('[');

    for (values, 0..) |value, index| {
        if (index > 0) buffer.append_byte(',');
        write_json_float(buffer, value);
    }

    buffer.append_byte(']');
}

fn write_bool_list(
    state: *EncodeState,
    buffer: *Buffer,
    key: []const u8,
    values: []const bool,
) void {
    std.debug.assert(key.len > 0);
    std.debug.assert(values.len <= field_mod.array_max);

    write_separator(state, buffer);
    write_quoted(buffer, key);
    buffer.append_byte(':');
    buffer.append_byte('[');

    for (values, 0..) |value, index| {
        if (index > 0) buffer.append_byte(',');
        buffer.append_slice(if (value) "true" else "false");
    }

    buffer.append_byte(']');
}

fn write_duration_list(
    config: *const EncoderConfig,
    state: *EncodeState,
    buffer: *Buffer,
    key: []const u8,
    values: []const i64,
) void {
    std.debug.assert(key.len > 0);
    std.debug.assert(values.len <= field_mod.array_max);

    write_separator(state, buffer);
    write_quoted(buffer, key);
    buffer.append_byte(':');
    buffer.append_byte('[');

    for (values, 0..) |nanoseconds, index| {
        if (index > 0) buffer.append_byte(',');
        write_duration_element(config, buffer, nanoseconds);
    }

    buffer.append_byte(']');
}

fn write_duration_element(config: *const EncoderConfig, buffer: *Buffer, nanoseconds: i64) void {
    switch (config.encode_duration) {
        .seconds => {
            const seconds: f64 = @as(f64, @floatFromInt(nanoseconds)) / 1_000_000_000.0;
            buffer.append_float(seconds);
        },
        .millis => buffer.append_integer(@divTrunc(nanoseconds, 1_000_000)),
        .nanos => buffer.append_integer(nanoseconds),
        .string => {
            buffer.append_byte('"');
            datetime.write_duration_string(buffer, nanoseconds);
            buffer.append_byte('"');
        },
    }
}

fn write_time_list(
    config: *const EncoderConfig,
    state: *EncodeState,
    buffer: *Buffer,
    key: []const u8,
    values: []const i64,
) void {
    std.debug.assert(key.len > 0);
    std.debug.assert(values.len <= field_mod.array_max);

    write_separator(state, buffer);
    write_quoted(buffer, key);
    buffer.append_byte(':');
    buffer.append_byte('[');

    for (values, 0..) |timestamp_ns, index| {
        if (index > 0) buffer.append_byte(',');
        write_time_element(config, buffer, timestamp_ns);
    }

    buffer.append_byte(']');
}

fn write_time_element(config: *const EncoderConfig, buffer: *Buffer, timestamp_ns: i64) void {
    switch (config.encode_time) {
        .epoch_s => datetime.write_epoch_scaled(buffer, timestamp_ns, nanos_per_second, 9),
        .epoch_ms => datetime.write_epoch_scaled(buffer, timestamp_ns, nanos_per_milli, 6),
        .epoch_ns => buffer.append_integer(timestamp_ns),
        .iso8601, .rfc3339 => {
            buffer.append_byte('"');
            datetime.write_iso8601(buffer, timestamp_ns, config.time_offset_minutes);
            buffer.append_byte('"');
        },
        .rfc3339_nano => {
            buffer.append_byte('"');
            datetime.write_iso8601_nano(buffer, timestamp_ns, config.time_offset_minutes);
            buffer.append_byte('"');
        },
    }
}

fn write_namespace_open(state: *EncodeState, buffer: *Buffer, key: []const u8) void {
    std.debug.assert(key.len > 0);

    if (state.namespace_depth >= namespace_depth_max) {
        return;
    }

    write_separator(state, buffer);
    write_quoted(buffer, key);
    buffer.append_byte(':');
    buffer.append_byte('{');
    state.namespace_depth += 1;
    state.field_count = 0;
}

fn close_namespaces(state: *EncodeState, buffer: *Buffer) void {
    std.debug.assert(state.namespace_depth <= namespace_depth_max);

    while (state.namespace_depth > 0) {
        buffer.append_byte('}');
        state.namespace_depth -= 1;
    }

    std.debug.assert(state.namespace_depth == 0);
}

fn write_separator(state: *EncodeState, buffer: *Buffer) void {
    if (state.field_count > 0) {
        buffer.append_byte(',');
    }
    state.field_count += 1;
}

pub fn write_quoted(buffer: *Buffer, value: []const u8) void {
    buffer.append_byte('"');
    write_escaped(buffer, value);
    buffer.append_byte('"');
}

fn chunk_is_clean(chunk: @Vector(escape_lane_count, u8)) bool {
    const Vec = @Vector(escape_lane_count, u8);

    const has_low = @reduce(.Or, chunk < @as(Vec, @splat(0x20)));
    const has_quote = @reduce(.Or, chunk == @as(Vec, @splat('"')));
    const has_backslash = @reduce(.Or, chunk == @as(Vec, @splat('\\')));
    const has_high = @reduce(.Or, chunk >= @as(Vec, @splat(0x80)));

    return !(has_low or has_quote or has_backslash or has_high);
}

fn write_escaped(buffer: *Buffer, value: []const u8) void {
    const Vec = @Vector(escape_lane_count, u8);

    var offset: usize = 0;

    while (value.len - offset >= escape_lane_count) {
        const chunk: Vec = value[offset..][0..escape_lane_count].*;

        if (!chunk_is_clean(chunk)) {
            break;
        }

        offset += escape_lane_count;
    }

    if (offset > 0) {
        buffer.append_slice(value[0..offset]);
    }

    write_escaped_scalar(buffer, value[offset..]);
}

fn write_escaped_scalar(buffer: *Buffer, value: []const u8) void {
    var start: usize = 0;
    var cursor: usize = 0;

    while (cursor < value.len) {
        const byte = value[cursor];

        if (byte >= 0x20 and byte < 0x80 and byte != '"' and byte != '\\') {
            cursor += 1;
            continue;
        }

        if (byte >= 0x80) {
            const sequence_length = utf8_sequence_length(byte);
            const remaining = value.len - cursor;

            if (sequence_length >= 2 and
                sequence_length <= remaining and
                validate_utf8_sequence(value[cursor .. cursor + sequence_length]))
            {
                const codepoint = decode_utf8(value[cursor .. cursor + sequence_length]);

                if (utf8_well_formed(sequence_length, codepoint)) {
                    if (codepoint <= 0xFFFF) {
                        cursor += sequence_length;
                        continue;
                    }

                    buffer.append_slice(value[start..cursor]);
                    write_utf16_surrogate_pair(buffer, codepoint);
                    cursor += sequence_length;
                    start = cursor;
                    continue;
                }
            }

            buffer.append_slice(value[start..cursor]);
            write_unicode_escape_byte(buffer, byte);
            cursor += 1;
            start = cursor;
            continue;
        }

        buffer.append_slice(value[start..cursor]);
        start = cursor + 1;

        switch (byte) {
            '"' => buffer.append_slice("\\\""),
            '\\' => buffer.append_slice("\\\\"),
            '\n' => buffer.append_slice("\\n"),
            '\r' => buffer.append_slice("\\r"),
            '\t' => buffer.append_slice("\\t"),
            0x08 => buffer.append_slice("\\b"),
            0x0c => buffer.append_slice("\\f"),
            else => write_unicode_escape_byte(buffer, byte),
        }

        cursor += 1;
    }

    std.debug.assert(cursor == value.len);

    if (start < value.len) {
        buffer.append_slice(value[start..]);
    }
}

fn utf8_sequence_length(first_byte: u8) usize {
    if (first_byte < 0x80) return 1;
    if (first_byte < 0xC0) return 0;
    if (first_byte < 0xE0) return 2;
    if (first_byte < 0xF0) return 3;
    if (first_byte < 0xF8) return 4;
    return 0;
}

fn validate_utf8_sequence(bytes: []const u8) bool {
    std.debug.assert(bytes.len >= 2);
    std.debug.assert(bytes.len <= 4);

    for (bytes[1..]) |byte| {
        if (byte & 0xC0 != 0x80) return false;
    }

    return true;
}

fn utf8_well_formed(sequence_length: usize, codepoint: u32) bool {
    std.debug.assert(sequence_length >= 2);
    std.debug.assert(sequence_length <= 4);

    if (codepoint >= 0xD800 and codepoint <= 0xDFFF) {
        return false;
    }

    if (codepoint > 0x10FFFF) {
        return false;
    }

    return switch (sequence_length) {
        2 => codepoint >= 0x80,
        3 => codepoint >= 0x800,
        4 => codepoint >= 0x10000,
        else => false,
    };
}

fn decode_utf8(bytes: []const u8) u32 {
    std.debug.assert(bytes.len >= 2);
    std.debug.assert(bytes.len <= 4);

    return switch (bytes.len) {
        2 => (@as(u32, bytes[0] & 0x1F) << 6) | @as(u32, bytes[1] & 0x3F),
        3 => (@as(u32, bytes[0] & 0x0F) << 12) |
            (@as(u32, bytes[1] & 0x3F) << 6) |
            @as(u32, bytes[2] & 0x3F),
        4 => (@as(u32, bytes[0] & 0x07) << 18) |
            (@as(u32, bytes[1] & 0x3F) << 12) |
            (@as(u32, bytes[2] & 0x3F) << 6) |
            @as(u32, bytes[3] & 0x3F),
        else => 0xFFFD,
    };
}

fn write_unicode_escape_byte(buffer: *Buffer, byte: u8) void {
    buffer.append_slice("\\u00");
    buffer.append_byte(hex_digits[byte >> 4]);
    buffer.append_byte(hex_digits[byte & 0x0f]);
}

fn write_unicode_escape_u16(buffer: *Buffer, value: u16) void {
    buffer.append_slice("\\u");
    buffer.append_byte(hex_digits[(value >> 12) & 0x0f]);
    buffer.append_byte(hex_digits[(value >> 8) & 0x0f]);
    buffer.append_byte(hex_digits[(value >> 4) & 0x0f]);
    buffer.append_byte(hex_digits[value & 0x0f]);
}

fn write_utf16_surrogate_pair(buffer: *Buffer, codepoint: u32) void {
    std.debug.assert(codepoint > 0xFFFF);
    std.debug.assert(codepoint <= 0x10FFFF);

    const adjusted = codepoint - 0x10000;
    const high: u16 = @intCast(0xD800 + (adjusted >> 10));
    const low: u16 = @intCast(0xDC00 + (adjusted & 0x3FF));

    write_unicode_escape_u16(buffer, high);
    write_unicode_escape_u16(buffer, low);
}

fn write_list_value(buffer: *Buffer, config: *const EncoderConfig, field: *const Field) void {
    buffer.append_byte('[');

    switch (field.field_type) {
        .string_list => for (field.value.text_list, 0..) |value, index| {
            if (index > 0) buffer.append_byte(',');
            write_quoted(buffer, value);
        },
        .int_list => for (field.value.signed_list, 0..) |value, index| {
            if (index > 0) buffer.append_byte(',');
            buffer.append_integer(value);
        },
        .uint_list => for (field.value.unsigned_list, 0..) |value, index| {
            if (index > 0) buffer.append_byte(',');
            buffer.append_unsigned(value);
        },
        .float_list => for (field.value.float_list, 0..) |value, index| {
            if (index > 0) buffer.append_byte(',');
            write_json_float(buffer, value);
        },
        .bool_list => for (field.value.bool_list, 0..) |value, index| {
            if (index > 0) buffer.append_byte(',');
            buffer.append_slice(if (value) "true" else "false");
        },
        .duration_list => for (field.value.signed_list, 0..) |value, index| {
            if (index > 0) buffer.append_byte(',');
            write_duration_element(config, buffer, value);
        },
        .time_list => for (field.value.signed_list, 0..) |value, index| {
            if (index > 0) buffer.append_byte(',');
            write_time_element(config, buffer, value);
        },
        else => unreachable,
    }

    buffer.append_byte(']');
}

pub fn write_field_value(
    buffer: *Buffer,
    config: *const EncoderConfig,
    field: *const Field,
    depth: u32,
) void {
    switch (field.field_type) {
        .skip, .namespace => {},
        .string, .byte_string, .err => write_quoted(buffer, field.value.text),
        .bool => buffer.append_slice(if (field.value.boolean) "true" else "false"),
        .int8, .int16, .int32, .int64 => buffer.append_integer(field.value.signed),
        .uint8, .uint16, .uint32, .uint64 => buffer.append_unsigned(field.value.unsigned),
        .float32, .float64 => write_json_float(buffer, field.value.float),
        .duration_ns => write_duration_element(config, buffer, field.value.signed),
        .time_s => write_time_element(config, buffer, field.value.signed *| nanos_per_second),
        .time_ns => write_time_element(config, buffer, field.value.signed),
        .binary => {
            buffer.append_byte('"');
            base64.encode_base64(buffer, field.value.bytes);
            buffer.append_byte('"');
        },
        .string_list,
        .int_list,
        .uint_list,
        .float_list,
        .bool_list,
        .duration_list,
        .time_list,
        => write_list_value(buffer, config, field),
        .object, .inline_object => write_object_value(buffer, config, field, depth),
        .array => write_array_value(buffer, config, field, depth),
        .dict => write_dict_value(buffer, config, field, depth),
        .reflect => {
            std.debug.assert(field.value.marshal.reflect_value_fn != null);
            field.value.marshal.reflect_value_fn.?(field.value.marshal.value, buffer);
        },
    }
}

pub fn write_short_caller(buffer: *Buffer, file: []const u8) void {
    std.debug.assert(file.len > 0);

    write_escaped(buffer, entry_mod.caller_short_path(file));
}
