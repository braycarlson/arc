const std = @import("std");
const buffer_mod = @import("../io/buffer.zig");
const encoder_config_mod = @import("config.zig");
const entry_mod = @import("../core/entry.zig");
const field_mod = @import("../core/field.zig");
const json_encoder_mod = @import("json.zig");
const datetime = @import("datetime.zig");
const clock_mod = @import("../core/clock.zig");
const config_mod = @import("../config.zig");
const logger_mod = @import("../logger.zig");

const assert = std.debug.assert;

const Buffer = buffer_mod.Buffer;
const EncoderConfig = encoder_config_mod.EncoderConfig;
const EncodeState = json_encoder_mod.EncodeState;
const Entry = entry_mod.Entry;
const Field = field_mod.Field;
const EntryFields = field_mod.EntryFields;

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
        fields: EntryFields,
    ) void {
        assert(fields.is_valid());

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

        self.encode_context_json(state, buffer, fields, has_content);

        if (entry.has_stack() and !self.config.should_omit_stacktrace()) {
            buffer.append_byte('\n');
            buffer.append_slice(entry.stack());
        }

        if (self.config.line_ending == .newline) {
            buffer.append_byte('\n');
        }
    }

    fn encode_timestamp(self: *const ConsoleEncoder, buffer: *Buffer, timestamp_ns: i64) void {
        assert(!self.config.should_omit_time());

        switch (self.config.encode_time) {
            .epoch_s => datetime.write_epoch_scaled(buffer, timestamp_ns, epoch_seconds_scale),
            .epoch_ms => datetime.write_epoch_scaled(buffer, timestamp_ns, epoch_millis_scale),
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
        fields: EntryFields,
        has_content: bool,
    ) void {
        assert(fields.is_valid());

        const total = fields.context.len + fields.message.len;

        if (total == 0) {
            return;
        }

        if (self.config.console_fields == .key_value) {
            self.write_logfmt(buffer, fields, has_content);

            return;
        }

        if (has_content) buffer.append_byte(self.config.console_separator);
        buffer.append_byte('{');

        state.field_count = 0;
        state.namespace_depth = 0;

        json_encoder_mod.encode_fields(state, buffer, &self.config, fields.context);
        json_encoder_mod.encode_fields(state, buffer, &self.config, fields.message);

        assert(state.namespace_depth <= json_encoder_mod.namespace_depth_max);

        while (state.namespace_depth > 0) {
            buffer.append_byte('}');
            state.namespace_depth -= 1;
        }

        buffer.append_byte('}');
    }

    fn write_logfmt(
        self: *const ConsoleEncoder,
        buffer: *Buffer,
        fields: EntryFields,
        has_content: bool,
    ) void {
        var state = LogfmtState.init();

        self.write_logfmt_slice(buffer, &state, fields.context, has_content);
        self.write_logfmt_slice(buffer, &state, fields.message, has_content);
    }

    fn write_logfmt_slice(
        self: *const ConsoleEncoder,
        buffer: *Buffer,
        state: *LogfmtState,
        fields: []const Field,
        has_content: bool,
    ) void {
        assert(buffer.is_valid());
        assert(state.is_valid());

        for (fields) |field| {
            if (field.field_type == .skip) {
                continue;
            }

            if (field.field_type == .namespace) {
                state.push_prefix(field.key);

                continue;
            }

            const separator = self.config.console_separator;

            write_logfmt_separator(buffer, state.written, has_content, separator);

            if (field.field_type != .inline_object) {
                buffer.append_slice(state.prefix_slice());
                buffer.append_slice(field.key);
                buffer.append_byte('=');
            }

            json_encoder_mod.write_field_value(buffer, &self.config, &field, 0);
            state.written += 1;
        }

        assert(state.is_valid());
    }

    pub fn encode_truncation_notice(
        self: *const ConsoleEncoder,
        buffer: *Buffer,
        entry: *const Entry,
    ) void {
        buffer.reset();

        if (!self.config.should_omit_level()) {
            buffer.append_slice(self.config.level_string(entry.level));
            buffer.append_byte(self.config.console_separator);
        }

        buffer.append_slice(json_encoder_mod.truncation_message);

        if (self.config.line_ending == .newline) {
            buffer.append_byte('\n');
        }

        assert(!buffer.was_truncated());
    }
};

const LogfmtState = struct {
    prefix: [logfmt_prefix_bytes_max]u8,
    prefix_length: u32,
    written: u32,

    fn init() LogfmtState {
        var state: LogfmtState = undefined;
        state.prefix_length = 0;
        state.written = 0;

        return state;
    }

    fn is_valid(self: *const LogfmtState) bool {
        return self.prefix_length <= logfmt_prefix_bytes_max;
    }

    fn prefix_slice(self: *const LogfmtState) []const u8 {
        assert(self.is_valid());

        return self.prefix[0..self.prefix_length];
    }

    fn push_prefix(self: *LogfmtState, key: []const u8) void {
        assert(self.is_valid());

        if (key.len == 0) {
            return;
        }

        const needed: u32 = @intCast(key.len + 1);

        if (self.prefix_length + needed > logfmt_prefix_bytes_max) {
            return;
        }

        @memcpy(self.prefix[self.prefix_length..][0..key.len], key);

        self.prefix_length += @intCast(key.len);
        self.prefix[self.prefix_length] = '.';
        self.prefix_length += 1;

        assert(self.is_valid());
    }
};

const epoch_seconds_scale: datetime.EpochScale = .{
    .divisor = nanoseconds_per_second,
    .fraction_digits = 9,
};

const epoch_millis_scale: datetime.EpochScale = .{
    .divisor = nanoseconds_per_millisecond,
    .fraction_digits = 6,
};

const nanoseconds_per_second: i64 = 1_000_000_000;
const nanoseconds_per_millisecond: i64 = 1_000_000;
const logfmt_prefix_bytes_max: u32 = 1024;

comptime {
    assert(logfmt_prefix_bytes_max > 0);
}

fn encode_caller(
    buffer: *Buffer,
    caller: *const entry_mod.Caller,
    encoding: encoder_config_mod.CallerEncoding,
) void {
    assert(caller.defined);
    assert(caller.file.len > 0);

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

const testing = std.testing;

const Clock = clock_mod.Clock;
const Config = config_mod.Config;
const Logger = logger_mod.Logger;

const Point = struct {
    x: i64,
    y: i64,

    pub fn marshal_log_object(self: *const Point, encoder: *json_encoder_mod.ObjectEncoder) void {
        encoder.add_int("x", self.x);
        encoder.add_int("y", self.y);
    }
};

const Pair = struct {
    a: i64,
    b: i64,
};

fn logfmt_logger(output: *Buffer) Logger {
    var logger = Logger.init_with_config(
        testing.io,
        Config.production()
            .with_level(.debug)
            .with_encoding(.console)
            .with_encoder_config(EncoderConfig.production().with_console_fields(.key_value))
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = output })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    return logger;
}

fn contains(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}

test "a logfmt console renders scalar fields as key and value pairs" {
    var output = Buffer.init();
    var logger = logfmt_logger(&output);

    logger.info("hello", &.{
        field_mod.string("user", "alice"),
        field_mod.int("count", 5),
        field_mod.boolean("ok", true),
    }, @src());

    const text = output.contents();

    try testing.expect(contains(text, "user=\"alice\""));
    try testing.expect(contains(text, "count=5"));
    try testing.expect(contains(text, "ok=true"));
    try testing.expect(!contains(text, "{\"user\""));

    assert(contains(text, "count=5"));
}

test "a logfmt console flattens a namespace into dotted keys" {
    var output = Buffer.init();
    var logger = logfmt_logger(&output);

    logger.info("m", &.{
        field_mod.namespace("req"),
        field_mod.string("id", "x"),
        field_mod.int("code", 200),
    }, @src());

    const text = output.contents();

    try testing.expect(contains(text, "req.id=\"x\""));
    try testing.expect(contains(text, "req.code=200"));

    assert(contains(text, "req.code=200"));
}

test "a logfmt console renders a list as a json array" {
    var output = Buffer.init();
    var logger = logfmt_logger(&output);

    logger.info("m", &.{field_mod.int_list("nums", &.{ 1, 2, 3 })}, @src());

    const text = output.contents();

    try testing.expect(contains(text, "nums=[1,2,3]"));

    assert(contains(text, "nums=[1,2,3]"));
}

test "a logfmt console renders dict, object, and reflect values as json" {
    var output = Buffer.init();
    var logger = logfmt_logger(&output);

    const point = Point{ .x = 1, .y = 2 };
    const pair = Pair{ .a = 3, .b = 4 };

    logger.info("m", &.{
        field_mod.dict("d", &.{field_mod.int("a", 1)}),
        field_mod.object("p", &point),
        field_mod.reflect("r", &pair),
    }, @src());

    const text = output.contents();

    try testing.expect(contains(text, "d={\"a\":1}"));
    try testing.expect(contains(text, "p={\"x\":1,\"y\":2}"));
    try testing.expect(contains(text, "r={\"a\":3,\"b\":4}"));

    assert(contains(text, "p={\"x\":1,\"y\":2}"));
}

test "a console encoder defaults to the json field block" {
    var output = Buffer.init();

    var logger = Logger.init_with_config(
        testing.io,
        Config.production()
            .with_level(.debug)
            .with_encoding(.console)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    logger.info("m", &.{field_mod.string("k", "v")}, @src());

    const text = output.contents();

    try testing.expect(contains(text, "{\"k\":\"v\"}"));

    assert(contains(text, "{\"k\":\"v\"}"));
}
