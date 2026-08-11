const std = @import("std");
const buffer_mod = @import("../io/buffer.zig");
const encoder_config_mod = @import("config.zig");
const entry_mod = @import("../core/entry.zig");
const field_mod = @import("../core/field.zig");
const json_encoder_mod = @import("json.zig");
const console_encoder_mod = @import("console.zig");

const assert = std.debug.assert;

const Buffer = buffer_mod.Buffer;
const EncoderConfig = encoder_config_mod.EncoderConfig;
const EncodeState = json_encoder_mod.EncodeState;
const Entry = entry_mod.Entry;
const EntryFields = field_mod.EntryFields;
const JsonEncoder = json_encoder_mod.JsonEncoder;
const ConsoleEncoder = console_encoder_mod.ConsoleEncoder;

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
        fields: EntryFields,
    ) void {
        assert(fields.is_valid());

        switch (self.*) {
            .json => |*json| json.encode_entry(state, buffer, entry, fields),
            .console => |*console| console.encode_entry(state, buffer, entry, fields),
        }
    }

    pub fn encode_truncation_notice(
        self: *const Encoder,
        buffer: *Buffer,
        entry: *const Entry,
    ) void {
        switch (self.*) {
            .json => |*json| json.encode_truncation_notice(buffer, entry),
            .console => |*console| console.encode_truncation_notice(buffer, entry),
        }
    }
};

pub const Encoding = enum(u8) {
    json,
    console,
};
