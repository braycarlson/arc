const std = @import("std");

const bounded = @import("bounded");
const buffer_module = @import("buffer.zig");
const datetime = @import("datetime.zig");
const encoding_module = @import("encoding.zig");
const field_module = @import("field.zig");
const json = @import("json.zig");
const record_module = @import("record.zig");

const assert = std.debug.assert;

const Buffer = buffer_module.Buffer;
const Encoding = encoding_module.Encoding;
const Field = field_module.Field;
const Record = record_module.Record;

const Line = struct {
    buffer: *Buffer,
    content: bool,
    encoding: *const Encoding,

    fn segment_open(line: *Line) void {
        assert(line.encoding.valid());
        assert(line.buffer.count <= buffer_module.entry_bytes_max);

        if (line.content) line.buffer.append_byte(line.encoding.console_separator);

        line.content = true;
    }
};

const Pair = struct {
    field: *const Field,
    prefix: []const u8,
    written: u32,
};

const Prefix = bounded.ArrayType(u8, prefix_bytes_max);
pub const prefix_bytes_max: u32 = 1024;

comptime {
    assert(prefix_bytes_max > field_module.key_bytes_max);
    assert(prefix_bytes_max + field_module.key_bytes_max < buffer_module.entry_bytes_max);
}

pub fn record_encode(
    buffer: *Buffer,
    encoding: *const Encoding,
    record: *const Record,
    fields: *const json.Fields,
) void {
    assert(encoding.format == .console);
    assert(fields.call.len <= field_module.field_count_max);

    var line: Line = .{ .buffer = buffer, .content = false, .encoding = encoding };

    if (encoding.key_time.len > 0) {
        line.segment_open();
        time_write(buffer, encoding, record.time_ns);
    }

    if (encoding.key_level.len > 0) {
        const color = record.level.color(encoding.level);

        line.segment_open();
        buffer.append_slice(color.prefix);
        buffer.append_slice(record.level.text(encoding.level));
        buffer.append_slice(color.suffix);
    }

    if (record.name.len > 0) {
        if (encoding.key_name.len > 0) {
            line.segment_open();
            buffer.append_slice(record.name);
        }
    }

    if (record.caller) |*caller| caller_write(&line, caller);

    if (encoding.key_message.len > 0) {
        line.segment_open();
        buffer.append_slice(record.message);
    }

    fields_write(&line, fields);

    if (encoding.line_ending == .newline) buffer.append_byte('\n');
}

pub fn truncation_encode(buffer: *Buffer, encoding: *const Encoding, record: *const Record) void {
    assert(encoding.format == .console);
    assert(encoding.valid());

    buffer.reset();

    if (encoding.key_level.len > 0) {
        buffer.append_slice(record.level.text(encoding.level));
        buffer.append_byte(encoding.console_separator);
    }

    buffer.append_slice(json.truncation_message);

    if (encoding.line_ending == .newline) buffer.append_byte('\n');

    assert(!buffer.truncated);
}

fn time_write(buffer: *Buffer, encoding: *const Encoding, time_ns: i64) void {
    assert(encoding.valid());
    assert(buffer.count <= buffer_module.entry_bytes_max);
    assert(@divFloor(time_ns, std.time.ns_per_s) >= datetime.seconds_min);
    assert(@divFloor(time_ns, std.time.ns_per_s) <= datetime.seconds_max);

    switch (encoding.time) {
        .epoch_ms => datetime.epoch_write(buffer, time_ns, .milliseconds),
        .epoch_ns => buffer.append_integer(time_ns),
        .epoch_s => datetime.epoch_write(buffer, time_ns, .seconds),
        .rfc3339 => datetime.rfc3339_write(buffer, time_ns, encoding.time_offset_minutes, .trimmed),
        .rfc3339_nano => datetime.rfc3339_write(
            buffer,
            time_ns,
            encoding.time_offset_minutes,
            .fixed,
        ),
    }
}

fn caller_write(line: *Line, caller: *const Record.Caller) void {
    assert(caller.file.len > 0);
    assert(caller.line > 0);

    const encoding = line.encoding;
    const buffer = line.buffer;

    if (encoding.key_caller.len > 0) {
        line.segment_open();

        switch (encoding.caller) {
            .full_path => buffer.append_slice(caller.file),
            .short_path => buffer.append_slice(caller.file_short()),
        }

        buffer.append_byte(':');
        buffer.append_unsigned(caller.line);
    }

    if (encoding.key_function.len > 0) {
        if (caller.function.len > 0) {
            line.segment_open();
            buffer.append_slice(caller.function);
        }
    }
}

fn fields_write(line: *Line, fields: *const json.Fields) void {
    assert(fields.call.len <= field_module.field_count_max);
    assert(fields.context.len <= field_module.field_count_max);

    if (fields.context.len + fields.call.len == 0) return;

    switch (line.encoding.console_fields) {
        .json => fields_json_write(line, fields),
        .key_value => fields_key_value_write(line, fields),
    }
}

fn fields_json_write(line: *Line, fields: *const json.Fields) void {
    assert(line.encoding.console_fields == .json);
    assert(fields.context.len + fields.call.len > 0);

    const buffer = line.buffer;

    var state: json.State = .empty;

    if (line.content) buffer.append_byte(line.encoding.console_separator);

    buffer.append_byte('{');

    if (fields.fragment) |*fragment| {
        json.fragment_splice(buffer, &state, fragment);
    } else {
        json.fields_encode(buffer, line.encoding, &state, fields.context);
    }

    json.fields_encode(buffer, line.encoding, &state, fields.call);
    json.namespaces_close(buffer, state.namespace_depth);
    buffer.append_byte('}');
}

fn fields_key_value_write(line: *Line, fields: *const json.Fields) void {
    assert(line.encoding.console_fields == .key_value);
    assert(fields.fragment == null);

    var prefix: Prefix = .empty;
    var written: u32 = 0;

    for ([2][]const Field{ fields.context, fields.call }) |slice| {
        for (slice) |*field| {
            assert(field.valid());

            switch (field.value) {
                .skip => {},
                .namespace => prefix_push(line.buffer, &prefix, field.key),
                else => {
                    pair_write(line, &.{
                        .field = field,
                        .prefix = prefix.slice(),
                        .written = written,
                    });

                    written += 1;
                },
            }
        }
    }
}

fn pair_write(line: *Line, pair: *const Pair) void {
    assert(pair.field.valid());
    assert(pair.prefix.len <= prefix_bytes_max);

    const buffer = line.buffer;

    if (pair.written > 0) {
        buffer.append_byte(' ');
    } else if (line.content) {
        buffer.append_byte(line.encoding.console_separator);
    } else {}

    buffer.append_slice(pair.prefix);
    buffer.append_slice(pair.field.key);
    buffer.append_byte('=');

    switch (pair.field.value) {
        .object => |children| json.object_value_encode(buffer, line.encoding, children),
        else => json.value_encode(buffer, line.encoding, &pair.field.value),
    }
}

fn prefix_push(buffer: *Buffer, prefix: *Prefix, key: []const u8) void {
    assert(key.len > 0);
    assert(prefix.count <= prefix_bytes_max);

    if (key.len + 1 > prefix_bytes_max - prefix.count) {
        buffer.clipped = true;

        return;
    }

    prefix.push_slice_assume_capacity(key);
    prefix.push_slice_assume_capacity(".");

    assert(prefix.count <= prefix_bytes_max);
}
