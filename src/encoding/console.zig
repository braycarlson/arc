const std = @import("std");
const buffer_mod = @import("../io/buffer.zig");
const encoder_config_mod = @import("config.zig");
const entry_mod = @import("../core/entry.zig");
const field_mod = @import("../core/field.zig");
const json_encoder_mod = @import("json.zig");
const datetime = @import("datetime.zig");

const Buffer = buffer_mod.Buffer;
const EncoderConfig = encoder_config_mod.EncoderConfig;
const EncodeState = json_encoder_mod.EncodeState;
const Entry = entry_mod.Entry;
const Field = field_mod.Field;

const nanos_per_second: i64 = 1_000_000_000;
const nanos_per_milli: i64 = 1_000_000;
const logfmt_prefix_max: u32 = 1024;

pub const ConsoleEncoder = struct {
    config: EncoderConfig,

    pub fn init(config: EncoderConfig) ConsoleEncoder {
        return .{ .config = config };
    }

    pub fn encode_entry(
        self: *const ConsoleEncoder,
        state: *EncodeState,
        buffer: *Buffer,
        entry: *const Entry,
        context_fields: []const Field,
        call_fields: []const Field,
    ) void {
        std.debug.assert(context_fields.len <= field_mod.fields_max);
        std.debug.assert(call_fields.len <= field_mod.fields_max);

        buffer.reset();
        var has_content = false;

        if (!self.config.should_omit_time()) {
            self.encode_timestamp(buffer, entry.timestamp_ns);
            has_content = true;
        }

        if (!self.config.should_omit_level()) {
            if (has_content) buffer.append_byte(self.config.console_separator);
            buffer.append_slice(self.config.level_color_prefix(entry.level));
            buffer.append_slice(self.config.level_string(entry.level));
            buffer.append_slice(self.config.level_color_suffix());
            has_content = true;
        }

        if (entry.logger_name.len > 0 and !self.config.should_omit_name()) {
            if (has_content) buffer.append_byte(self.config.console_separator);
            buffer.append_slice(entry.logger_name);
            has_content = true;
        }

        if (entry.caller.defined and !self.config.should_omit_caller()) {
            if (has_content) buffer.append_byte(self.config.console_separator);
            encode_caller(buffer, &entry.caller, self.config.encode_caller);
            has_content = true;
        }

        if (entry.caller.defined and !self.config.should_omit_function()) {
            if (entry.caller.function.len > 0) {
                if (has_content) buffer.append_byte(self.config.console_separator);
                buffer.append_slice(entry.caller.function);
                has_content = true;
            }
        }

        if (!self.config.should_omit_message()) {
            if (has_content) buffer.append_byte(self.config.console_separator);
            buffer.append_slice(entry.message);
            has_content = true;
        }

        self.encode_context_json(state, buffer, context_fields, call_fields, has_content);

        if (entry.has_stack() and !self.config.should_omit_stacktrace()) {
            buffer.append_byte('\n');
            buffer.append_slice(entry.stack());
        }

        if (self.config.line_ending == .newline) {
            buffer.append_byte('\n');
        }
    }

    fn encode_timestamp(self: *const ConsoleEncoder, buffer: *Buffer, timestamp_ns: i64) void {
        std.debug.assert(!self.config.should_omit_time());

        switch (self.config.encode_time) {
            .epoch_s => datetime.write_epoch_scaled(buffer, timestamp_ns, nanos_per_second, 9),
            .epoch_ms => datetime.write_epoch_scaled(buffer, timestamp_ns, nanos_per_milli, 6),
            .epoch_ns => buffer.append_integer(timestamp_ns),
            .iso8601, .rfc3339 => datetime.write_iso8601(
                buffer,
                timestamp_ns,
                self.config.time_offset_minutes,
            ),
            .rfc3339_nano => datetime.write_iso8601_nano(
                buffer,
                timestamp_ns,
                self.config.time_offset_minutes,
            ),
        }
    }

    fn encode_context_json(
        self: *const ConsoleEncoder,
        state: *EncodeState,
        buffer: *Buffer,
        context_fields: []const Field,
        call_fields: []const Field,
        has_content: bool,
    ) void {
        std.debug.assert(context_fields.len <= field_mod.fields_max);
        std.debug.assert(call_fields.len <= field_mod.fields_max);

        const total = context_fields.len + call_fields.len;

        if (total == 0) {
            return;
        }

        if (self.config.console_fields == .key_value) {
            self.write_logfmt(buffer, context_fields, call_fields, has_content);

            return;
        }

        if (has_content) buffer.append_byte(self.config.console_separator);
        buffer.append_byte('{');

        state.field_count = 0;
        state.namespace_depth = 0;

        json_encoder_mod.encode_fields(state, buffer, &self.config, context_fields);
        json_encoder_mod.encode_fields(state, buffer, &self.config, call_fields);

        while (state.namespace_depth > 0) {
            buffer.append_byte('}');
            state.namespace_depth -= 1;
        }

        buffer.append_byte('}');
    }

    fn write_logfmt(
        self: *const ConsoleEncoder,
        buffer: *Buffer,
        context_fields: []const Field,
        call_fields: []const Field,
        has_content: bool,
    ) void {
        var prefix: [logfmt_prefix_max]u8 = undefined;
        var prefix_length: u32 = 0;
        var written: u32 = 0;

        self.write_logfmt_slice(buffer, context_fields, &prefix, &prefix_length, &written, has_content);
        self.write_logfmt_slice(buffer, call_fields, &prefix, &prefix_length, &written, has_content);
    }

    fn write_logfmt_slice(
        self: *const ConsoleEncoder,
        buffer: *Buffer,
        fields: []const Field,
        prefix: []u8,
        prefix_length: *u32,
        written: *u32,
        has_content: bool,
    ) void {
        for (fields) |field| {
            if (field.field_type == .skip) {
                continue;
            }

            if (field.field_type == .namespace) {
                push_logfmt_prefix(prefix, prefix_length, field.key);

                continue;
            }

            write_logfmt_separator(buffer, written.*, has_content, self.config.console_separator);

            if (field.field_type != .inline_object) {
                buffer.append_slice(prefix[0..prefix_length.*]);
                buffer.append_slice(field.key);
                buffer.append_byte('=');
            }

            json_encoder_mod.write_field_value(buffer, &self.config, &field, 0);
            written.* += 1;
        }
    }

    pub fn encode_truncation_notice(self: *const ConsoleEncoder, buffer: *Buffer, entry: *const Entry) void {
        buffer.reset();

        if (!self.config.should_omit_level()) {
            buffer.append_slice(self.config.level_string(entry.level));
            buffer.append_byte(self.config.console_separator);
        }

        buffer.append_slice(json_encoder_mod.truncation_message);

        if (self.config.line_ending == .newline) {
            buffer.append_byte('\n');
        }

        std.debug.assert(!buffer.was_truncated());
    }
};

fn encode_caller(
    buffer: *Buffer,
    caller: *const entry_mod.Caller,
    encoding: encoder_config_mod.CallerEncoding,
) void {
    std.debug.assert(caller.defined);
    std.debug.assert(caller.file.len > 0);

    switch (encoding) {
        .full_path => buffer.append_slice(caller.file),
        .short_path => buffer.append_slice(entry_mod.caller_short_path(caller.file)),
    }

    buffer.append_byte(':');
    buffer.append_unsigned(@intCast(caller.line));
}

fn write_logfmt_separator(buffer: *Buffer, written: u32, has_content: bool, separator: u8) void {
    if (written == 0) {
        if (has_content) {
            buffer.append_byte(separator);
        }

        return;
    }

    buffer.append_byte(' ');
}

fn push_logfmt_prefix(prefix: []u8, prefix_length: *u32, key: []const u8) void {
    std.debug.assert(key.len > 0);
    std.debug.assert(prefix_length.* <= prefix.len);

    const needed = key.len + 1;

    if (prefix_length.* + needed > prefix.len) {
        return;
    }

    @memcpy(prefix[prefix_length.*..][0..key.len], key);
    prefix_length.* += @intCast(key.len);
    prefix[prefix_length.*] = '.';
    prefix_length.* += 1;
}
