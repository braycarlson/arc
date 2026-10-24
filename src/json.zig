const std = @import("std");

const json = @import("json");

const base64 = @import("base64.zig");
const buffer_module = @import("buffer.zig");
const datetime = @import("datetime.zig");
const encoding_module = @import("encoding.zig");
const field_module = @import("field.zig");
const record_module = @import("record.zig");

const assert = std.debug.assert;

const Buffer = buffer_module.Buffer;
const Encoding = encoding_module.Encoding;
const Field = field_module.Field;
const Record = record_module.Record;

pub const Fields = struct {
    call: []const Field,
    context: []const Field,
    fragment: ?Fragment,
};

pub const Fragment = struct {
    bytes: []const u8,
    state: State,
};

pub const State = struct {
    count: u32,
    namespace_depth: u32,

    pub const empty: State = .{ .count = 0, .namespace_depth = 0 };
};

const Child = struct {
    fields: []const Field,
    key: []const u8,
};

const Frame = struct {
    count: u32,
    fields: []const Field,
    index: u32,
    namespace_depth: u32,
};

const Scalar = union(enum) {
    float: f64,
    integer: i64,
    string: []const u8,
    unsigned: u64,
};

const Walk = struct {
    depth: u32,
    frames: [frame_count_max]Frame,
    level_base: u32,
};

pub const namespace_depth_max: u32 = 8;
pub const object_level_max: u32 = 8;
pub const truncation_key = "arc_truncated";
pub const truncation_message = "log entry exceeded buffer capacity and was dropped";

const entry_bytes_max = buffer_module.entry_bytes_max;
const float_bytes_max = buffer_module.float_bytes_max;
const field_count_max = field_module.field_count_max;
const frame_count_max: u32 = object_level_max + 1;
const list_count_max = field_module.list_count_max;
const object_bytes_min: u32 = 5;
const object_count_max: u32 = @divFloor(entry_bytes_max, object_bytes_min) + 1;
const visit_count_max: u32 = 64 * 1024;

const writer_options: json.Writer.Options = .{
    .indent = 2,
    .layout = .compact,
    .non_finite = .refused,
    .notation = .decimal,
    .utf8 = .bmp,
};

comptime {
    assert(namespace_depth_max > 0);
    assert(frame_count_max == object_level_max + 1);
    assert(visit_count_max >= object_count_max * (field_count_max + 1));
    assert(field_module.text_bytes_max <= json.limits.input_bytes_max);
}

pub fn record_encode(
    buffer: *Buffer,
    encoding: *const Encoding,
    record: *const Record,
    fields: *const Fields,
) void {
    assert(fields.call.len <= field_count_max);
    assert(encoding.format == .json);

    var state: State = .empty;

    buffer.append_byte('{');
    envelope_encode(buffer, encoding, record, &state);

    if (fields.fragment) |*fragment| {
        fragment_splice(buffer, &state, fragment);
    } else {
        fields_encode(buffer, encoding, &state, fields.context);
    }

    fields_encode(buffer, encoding, &state, fields.call);
    namespaces_close(buffer, state.namespace_depth);
    buffer.append_byte('}');

    if (encoding.line_ending == .newline) buffer.append_byte('\n');
}

pub fn truncation_encode(buffer: *Buffer, encoding: *const Encoding, record: *const Record) void {
    assert(encoding.format == .json);
    assert(encoding.valid());

    var state: State = .empty;

    buffer.reset();
    buffer.append_byte('{');

    if (encoding.key_level.len > 0) {
        member_open(buffer, &state.count, encoding.key_level);
        string_write(buffer, record.level.text(encoding.level));
    }

    if (encoding.key_message.len > 0) {
        member_open(buffer, &state.count, encoding.key_message);
        string_write(buffer, truncation_message);
    }

    member_open(buffer, &state.count, truncation_key);
    buffer.append_slice("true");
    buffer.append_byte('}');

    if (encoding.line_ending == .newline) buffer.append_byte('\n');

    assert(!buffer.truncated);
}

pub fn fields_encode(
    buffer: *Buffer,
    encoding: *const Encoding,
    state: *State,
    fields: []const Field,
) void {
    assert(fields.len <= field_count_max);
    assert(state.namespace_depth <= namespace_depth_max);

    var walk: Walk = undefined;

    walk.depth = 0;
    walk.level_base = 0;

    walk.frames[0] = .{
        .count = state.count,
        .fields = fields,
        .index = 0,
        .namespace_depth = state.namespace_depth,
    };

    walk_run(buffer, encoding, &walk);

    state.count = walk.frames[0].count;
    state.namespace_depth = walk.frames[0].namespace_depth;

    assert(state.namespace_depth <= namespace_depth_max);
}

pub fn value_encode(buffer: *Buffer, encoding: *const Encoding, value: *const Field.Value) void {
    assert(value.* != .namespace);
    assert(value.* != .object);
    assert(value.* != .skip);

    switch (value.*) {
        .binary => |bytes| {
            buffer.append_byte('"');
            base64.base64_write(buffer, bytes);
            buffer.append_byte('"');
        },
        .boolean => |boolean| buffer.append_slice(if (boolean) "true" else "false"),
        .duration_ns => |nanoseconds| duration_encode(buffer, encoding, nanoseconds),
        .float => |float| float_encode(buffer, float),
        .integer => |integer| scalar_write(buffer, &.{ .integer = integer }),
        .namespace, .object, .skip => unreachable,
        .string => |text| string_write(buffer, text),
        .time_ns => |time_ns| time_encode(buffer, encoding, time_ns),
        .unsigned => |unsigned| scalar_write(buffer, &.{ .unsigned = unsigned }),
        .boolean_list,
        .duration_ns_list,
        .float_list,
        .integer_list,
        .string_list,
        .time_ns_list,
        .unsigned_list,
        => list_encode(buffer, encoding, value),
    }
}

fn envelope_encode(
    buffer: *Buffer,
    encoding: *const Encoding,
    record: *const Record,
    state: *State,
) void {
    assert(state.count == 0);
    assert(record.name.len <= entry_bytes_max);

    if (encoding.key_level.len > 0) {
        member_open(buffer, &state.count, encoding.key_level);
        string_write(buffer, record.level.text(encoding.level));
    }

    if (encoding.key_time.len > 0) {
        member_open(buffer, &state.count, encoding.key_time);
        time_encode(buffer, encoding, record.time_ns);
    }

    if (record.name.len > 0) {
        if (encoding.key_name.len > 0) {
            member_open(buffer, &state.count, encoding.key_name);
            string_write(buffer, record.name);
        }
    }

    if (record.caller) |*caller| caller_encode(buffer, encoding, caller, state);

    if (encoding.key_message.len > 0) {
        member_open(buffer, &state.count, encoding.key_message);
        string_write(buffer, record.message);
    }
}

fn caller_encode(
    buffer: *Buffer,
    encoding: *const Encoding,
    caller: *const Record.Caller,
    state: *State,
) void {
    assert(caller.file.len > 0);
    assert(caller.line > 0);

    if (encoding.key_caller.len > 0) {
        const file = switch (encoding.caller) {
            .full_path => caller.file,
            .short_path => caller.file_short(),
        };

        member_open(buffer, &state.count, encoding.key_caller);
        caller_write(buffer, file, caller.line);
    }

    if (encoding.key_function.len > 0) {
        if (caller.function.len > 0) {
            member_open(buffer, &state.count, encoding.key_function);
            string_write(buffer, caller.function);
        }
    }
}

fn caller_write(buffer: *Buffer, file: []const u8, line: u32) void {
    assert(file.len > 0);
    assert(line > 0);

    var view: std.Io.Writer = .fixed(buffer.bytes[buffer.count..]);
    var writer: json.Writer = .init(&view, writer_options);

    if (caller_parts_write(&writer, file, line)) {
        writer.finish();
    } else |err| switch (err) {
        error.WriteFailed => buffer.truncated = true,
    }

    buffer.count += @intCast(view.end);
}

fn caller_parts_write(
    writer: *json.Writer,
    file: []const u8,
    line: u32,
) std.Io.Writer.Error!void {
    assert(file.len > 0);
    assert(line > 0);

    var digits: [buffer_module.unsigned_bytes_max]u8 = undefined;

    try writer.string_begin();
    try writer.string_part(file);
    try writer.string_part(":");
    try writer.string_part(buffer_module.unsigned_format(&digits, line));
    try writer.string_end();
}

pub fn fragment_splice(buffer: *Buffer, state: *State, fragment: *const Fragment) void {
    assert(fragment.state.namespace_depth <= namespace_depth_max);
    assert(state.namespace_depth == 0);

    if (fragment.bytes.len == 0) return;

    if (state.count > 0) buffer.append_byte(',');

    buffer.append_slice(fragment.bytes);
    state.* = fragment.state;
}

fn walk_run(buffer: *Buffer, encoding: *const Encoding, walk: *Walk) void {
    assert(walk.depth == 0);
    assert(walk.level_base <= object_level_max);

    for (0..visit_count_max) |_| {
        const frame = &walk.frames[walk.depth];

        if (frame.index == frame.fields.len) {
            if (walk.depth == 0) return;

            namespaces_close(buffer, frame.namespace_depth);
            buffer.append_byte('}');
            walk.depth -= 1;

            continue;
        }

        const field = &frame.fields[frame.index];

        frame.index += 1;

        assert(field.valid());

        switch (field.value) {
            .skip => {},
            .namespace => namespace_open(buffer, frame, field.key),
            .object => |children| {
                object_open(buffer, walk, &.{ .fields = children, .key = field.key });
            },
            else => {
                member_open(buffer, &frame.count, field.key);
                value_encode(buffer, encoding, &field.value);
            },
        }

        if (buffer.truncated) return;
    }

    buffer.truncated = true;
}

fn object_open(buffer: *Buffer, walk: *Walk, child: *const Child) void {
    assert(child.fields.len <= field_count_max);
    assert(walk.depth < frame_count_max);

    const frame = &walk.frames[walk.depth];
    const level = walk.level_base + walk.depth;

    member_open(buffer, &frame.count, child.key);
    buffer.append_byte('{');

    if (level >= object_level_max) {
        if (child.fields.len > 0) buffer.clipped = true;

        buffer.append_byte('}');

        return;
    }

    walk.depth += 1;

    walk.frames[walk.depth] = .{
        .count = 0,
        .fields = child.fields,
        .index = 0,
        .namespace_depth = 0,
    };

    assert(walk.level_base + walk.depth <= object_level_max);
}

pub fn object_value_encode(buffer: *Buffer, encoding: *const Encoding, fields: []const Field) void {
    assert(fields.len <= field_count_max);
    assert(buffer.count <= entry_bytes_max);

    var walk: Walk = undefined;

    walk.depth = 0;
    walk.level_base = 1;
    walk.frames[0] = .{ .count = 0, .fields = fields, .index = 0, .namespace_depth = 0 };

    buffer.append_byte('{');
    walk_run(buffer, encoding, &walk);
    namespaces_close(buffer, walk.frames[0].namespace_depth);
    buffer.append_byte('}');
}

fn namespace_open(buffer: *Buffer, frame: *Frame, key: []const u8) void {
    assert(key.len > 0);
    assert(frame.namespace_depth <= namespace_depth_max);

    if (frame.namespace_depth == namespace_depth_max) {
        buffer.clipped = true;

        return;
    }

    member_open(buffer, &frame.count, key);
    buffer.append_byte('{');
    frame.namespace_depth += 1;
    frame.count = 0;
}

pub fn namespaces_close(buffer: *Buffer, namespace_depth: u32) void {
    assert(namespace_depth <= namespace_depth_max);
    assert(buffer.count <= entry_bytes_max);

    for (0..namespace_depth) |_| buffer.append_byte('}');
}

fn member_open(buffer: *Buffer, count: *u32, key: []const u8) void {
    assert(key.len > 0);
    assert(key.len <= field_module.key_bytes_max);

    if (count.* > 0) buffer.append_byte(',');

    count.* += 1;

    string_write(buffer, key);
    buffer.append_byte(':');
}

fn list_encode(buffer: *Buffer, encoding: *const Encoding, value: *const Field.Value) void {
    assert(buffer.count <= entry_bytes_max);
    assert(value.* != .object);

    buffer.append_byte('[');

    switch (value.*) {
        .boolean_list => |list| for (list, 0..) |boolean, index| {
            if (index > 0) buffer.append_byte(',');

            buffer.append_slice(if (boolean) "true" else "false");
        },
        .duration_ns_list => |list| for (list, 0..) |nanoseconds, index| {
            if (index > 0) buffer.append_byte(',');

            duration_encode(buffer, encoding, nanoseconds);
        },
        .float_list => |list| for (list, 0..) |float, index| {
            if (index > 0) buffer.append_byte(',');

            float_encode(buffer, float);
        },
        .integer_list => |list| for (list, 0..) |integer, index| {
            if (index > 0) buffer.append_byte(',');

            scalar_write(buffer, &.{ .integer = integer });
        },
        .string_list => |list| for (list, 0..) |text, index| {
            if (index > 0) buffer.append_byte(',');

            string_write(buffer, text);
        },
        .time_ns_list => |list| for (list, 0..) |time_ns, index| {
            if (index > 0) buffer.append_byte(',');

            time_encode(buffer, encoding, time_ns);
        },
        .unsigned_list => |list| for (list, 0..) |unsigned, index| {
            if (index > 0) buffer.append_byte(',');

            scalar_write(buffer, &.{ .unsigned = unsigned });
        },
        .binary,
        .boolean,
        .duration_ns,
        .float,
        .integer,
        .namespace,
        .object,
        .skip,
        .string,
        .time_ns,
        .unsigned,
        => unreachable,
    }

    buffer.append_byte(']');
}

fn duration_encode(buffer: *Buffer, encoding: *const Encoding, nanoseconds: i64) void {
    assert(@divTrunc(@abs(nanoseconds), std.time.ns_per_s) <= datetime.seconds_max);
    assert(encoding.valid());
    assert(buffer.count <= entry_bytes_max);

    switch (encoding.duration) {
        .milliseconds => {
            scalar_write(buffer, &.{ .integer = @divTrunc(nanoseconds, std.time.ns_per_ms) });
        },
        .nanoseconds => scalar_write(buffer, &.{ .integer = nanoseconds }),
        .seconds => {
            const nanoseconds_float: f64 = @floatFromInt(nanoseconds);

            float_write(buffer, nanoseconds_float / std.time.ns_per_s);
        },
        .string => {
            buffer.append_byte('"');
            datetime.duration_write(buffer, nanoseconds);
            buffer.append_byte('"');
        },
    }
}

fn time_encode(buffer: *Buffer, encoding: *const Encoding, time_ns: i64) void {
    assert(@divFloor(time_ns, std.time.ns_per_s) >= datetime.seconds_min);
    assert(@divFloor(time_ns, std.time.ns_per_s) <= datetime.seconds_max);
    assert(encoding.valid());
    assert(buffer.count <= entry_bytes_max);

    switch (encoding.time) {
        .epoch_ms => datetime.epoch_write(buffer, time_ns, .milliseconds),
        .epoch_ns => scalar_write(buffer, &.{ .integer = time_ns }),
        .epoch_s => datetime.epoch_write(buffer, time_ns, .seconds),
        .rfc3339 => {
            buffer.append_byte('"');
            datetime.rfc3339_write(buffer, time_ns, encoding.time_offset_minutes, .trimmed);
            buffer.append_byte('"');
        },
        .rfc3339_nano => {
            buffer.append_byte('"');
            datetime.rfc3339_write(buffer, time_ns, encoding.time_offset_minutes, .fixed);
            buffer.append_byte('"');
        },
    }
}

fn float_encode(buffer: *Buffer, float: f64) void {
    assert(@intFromBool(std.math.signbit(float)) + float_bytes_max < entry_bytes_max);
    assert(buffer.count <= entry_bytes_max);

    if (std.math.isNan(float)) {
        buffer.append_slice("\"NaN\"");
    } else if (std.math.isPositiveInf(float)) {
        buffer.append_slice("\"+Inf\"");
    } else if (std.math.isNegativeInf(float)) {
        buffer.append_slice("\"-Inf\"");
    } else {
        float_write(buffer, float);
    }
}

fn float_write(buffer: *Buffer, float: f64) void {
    assert(std.math.isFinite(float));
    assert(buffer.count <= entry_bytes_max);

    const start = buffer.count;

    scalar_write(buffer, &.{ .float = float });

    if (std.mem.findScalar(u8, buffer.bytes[start..buffer.count], 'e') == null) return;

    buffer.count = start;

    buffer.append_float(float);
}

pub fn string_write(buffer: *Buffer, text: []const u8) void {
    assert(text.len <= field_module.text_bytes_max);
    assert(buffer.count <= entry_bytes_max);

    if (text.len > buffer.remaining()) {
        buffer.truncated = true;

        return;
    }

    scalar_write(buffer, &.{ .string = text });
}

fn scalar_write(buffer: *Buffer, scalar: *const Scalar) void {
    assert(buffer.count <= entry_bytes_max);

    if (scalar.* == .float) assert(std.math.isFinite(scalar.float));

    var view: std.Io.Writer = .fixed(buffer.bytes[buffer.count..]);
    var writer: json.Writer = .init(&view, writer_options);

    const written = switch (scalar.*) {
        .float => |float| writer.float(float),
        .integer => |integer| writer.integer(integer),
        .string => |text| writer.string(text),
        .unsigned => |unsigned| writer.unsigned(unsigned),
    };

    if (written) {
        writer.finish();
    } else |err| switch (err) {
        error.FloatNonFinite => unreachable,
        error.WriteFailed => buffer.truncated = true,
    }

    buffer.count += @intCast(view.end);

    assert(buffer.count <= entry_bytes_max);
}
