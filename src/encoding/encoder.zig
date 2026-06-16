const std = @import("std");
const buffer_mod = @import("../io/buffer.zig");
const encoder_config_mod = @import("config.zig");
const entry_mod = @import("../core/entry.zig");
const field_mod = @import("../core/field.zig");
const json_encoder_mod = @import("json.zig");
const console_encoder_mod = @import("console.zig");

const Buffer = buffer_mod.Buffer;
const EncoderConfig = encoder_config_mod.EncoderConfig;
const EncodeState = json_encoder_mod.EncodeState;
const Entry = entry_mod.Entry;
const Field = field_mod.Field;
const JsonEncoder = json_encoder_mod.JsonEncoder;
const ConsoleEncoder = console_encoder_mod.ConsoleEncoder;

pub const Encoding = enum(u8) {
    json,
    console,
};

pub const Encoder = union(Encoding) {
    json: JsonEncoder,
    console: ConsoleEncoder,

    pub fn init(encoding: Encoding, config: EncoderConfig) Encoder {
        return switch (encoding) {
            .json => Encoder{ .json = JsonEncoder.init(config) },
            .console => Encoder{ .console = ConsoleEncoder.init(config) },
        };
    }

    pub fn encode_entry(
        self: *const Encoder,
        state: *EncodeState,
        buffer: *Buffer,
        entry: *const Entry,
        context_fields: []const Field,
        call_fields: []const Field,
    ) void {
        std.debug.assert(context_fields.len <= field_mod.fields_max);
        std.debug.assert(call_fields.len <= field_mod.fields_max);

        switch (self.*) {
            .json => |*json| json.encode_entry(state, buffer, entry, context_fields, call_fields),
            .console => |*console| console.encode_entry(
                state,
                buffer,
                entry,
                context_fields,
                call_fields,
            ),
        }
    }

    pub fn encode_truncation_notice(self: *const Encoder, buffer: *Buffer, entry: *const Entry) void {
        switch (self.*) {
            .json => |*json| json.encode_truncation_notice(buffer, entry),
            .console => |*console| console.encode_truncation_notice(buffer, entry),
        }
    }
};
