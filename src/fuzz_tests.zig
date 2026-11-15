const std = @import("std");

const arc = @import("arc.zig");
const buffer_module = @import("buffer.zig");
const datetime = @import("datetime.zig");
const json = @import("json.zig");
const sampler_module = @import("sampler.zig");

const assert = std.debug.assert;

const Buffer = buffer_module.Buffer;
const Core = arc.Core;
const Encoding = arc.Encoding;
const Field = arc.Field;
const Level = arc.Level;
const Logger = arc.Logger;
const Prng = std.Random.DefaultPrng;
const Sampler = sampler_module.Sampler;

const Fuzzer = enum {
    datetime,
    encoder,
    escape,
    sampler,
    smoke,
};

const Options = struct {
    events_max: u32,
    seed: u64,
};

const Arguments = struct {
    events_text: []const u8,
    fuzzer: Fuzzer,
    seed_text: []const u8,
};

const FieldKind = enum {
    binary,
    boolean,
    duration_ns,
    float,
    integer,
    integer_list,
    namespace,
    object,
    skip,
    string,
    string_list,
    time_ns,
    unsigned,
};

const Model = struct {
    counts: [Level.count][sampler_module.bucket_count]u64,
    resets: [Level.count][sampler_module.bucket_count]i64,
};

const State = struct {
    buffer: Buffer,
    core: Core,
    core_plain: Core,
    integers: [pool_count_max][list_count_fuzz]i64,
    model: Model,
    parse_bytes: [parse_bytes_max]u8,
    pool: [pool_count_max]Field,
    prng: Prng,
    sampler: Sampler,
    stream: std.Io.Writer,
    stream_bytes: [stream_bytes_max]u8,
    stream_plain: std.Io.Writer,
    stream_plain_bytes: [stream_bytes_max]u8,
    strings: [pool_count_max][2][]const u8,
    texts: [text_bytes_total]u8,
    texts_used: u32,
    time_ns: i64,
    witness: Witness,
};

const Witness = struct {
    clipped_count: u64,
    dropped_count: u64,
    fragment_count: u64,
    truncated_count: u64,
};

const arguments_bytes_max: u32 = 64;
const chain_count: u32 = arc.limits.object_level_max + 2;
const events_max_default: u32 = 20_000;
const events_max_smoke: u32 = 256;
const key_bytes_fuzz: u32 = 6;
const list_count_fuzz: u32 = 4;
const message_bytes_fuzz: u32 = 96;
const parse_bytes_max: u32 = 1024 * 1024;
const pool_count_max: u32 = 128;
const sampler_reset_interval: u32 = 1024;
const seed_smoke: u64 = 0x5eed;
const stream_bytes_max: u32 = 64 * 1024;
const text_bytes_fuzz: u32 = 64;
const text_bytes_total: u32 = pool_count_max * (text_bytes_fuzz + key_bytes_fuzz) + 4096;
const options_smoke: Options = .{ .events_max = events_max_smoke, .seed = seed_smoke };
const usage_text = "usage: fuzz <datetime|encoder|escape|sampler|smoke> [seed|random] [events]\n";
const witness_events_min: u32 = events_max_default;

comptime {
    assert(events_max_smoke < events_max_default);
    assert(pool_count_max > arc.limits.field_count_max);
    assert(chain_count > arc.limits.namespace_depth_max + 1);
    assert(chain_count < pool_count_max);
    assert(stream_bytes_max > 2 * arc.limits.entry_bytes_max);
}

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len > 0);
    assert(init.minimal.args.vector.len < std.math.maxInt(u32));

    const vector = try init.minimal.args.toSlice(init.arena.allocator());
    const arguments = try arguments_parse(vector);
    const state = try init.gpa.create(State);
    defer init.gpa.destroy(state);

    state_reset(state);

    if (arguments.fuzzer == .smoke) {
        if (arguments.seed_text.len > 0) return usage();

        for (std.enums.values(Fuzzer)) |fuzzer| {
            if (fuzzer == .smoke) continue;

            try run(init.io, state, fuzzer, &options_smoke);
        }

        return;
    }

    const options = try options_of(init.io, &arguments);

    try run(init.io, state, arguments.fuzzer, &options);
}

fn state_reset(state: *State) void {
    assert(state.texts.len == text_bytes_total);
    assert(state.pool.len == pool_count_max);

    state.buffer.reset();
    state.texts_used = 0;
    state.time_ns = std.time.ns_per_s;
}

fn arguments_parse(vector: []const [:0]const u8) error{ArgumentsInvalid}!Arguments {
    assert(vector.len > 0);
    assert(vector.len < std.math.maxInt(u32));

    if (vector.len < 2) return usage();
    if (vector.len > 4) return usage();

    const fuzzer = std.meta.stringToEnum(Fuzzer, vector[1]) orelse return usage();

    return .{
        .events_text = if (vector.len == 4) vector[3] else "",
        .fuzzer = fuzzer,
        .seed_text = if (vector.len >= 3) vector[2] else "",
    };
}

fn options_of(io: std.Io, arguments: *const Arguments) error{ArgumentsInvalid}!Options {
    assert(arguments.fuzzer != .smoke);
    assert(arguments.seed_text.len <= std.math.maxInt(u32));

    const seed_text = arguments.seed_text;
    const events_text = arguments.events_text;

    var seed: u64 = 0;

    if (seed_text.len == 0) {
        io.random(std.mem.asBytes(&seed));
    } else if (std.mem.eql(u8, seed_text, "random")) {
        io.random(std.mem.asBytes(&seed));
    } else {
        seed = try number_parse(u64, seed_text);
    }

    const events_max = if (events_text.len == 0)
        events_max_default
    else
        try number_parse(u32, events_text);

    if (events_max == 0) return usage();
    return .{ .events_max = events_max, .seed = seed };
}

fn number_parse(comptime T: type, text: []const u8) error{ArgumentsInvalid}!T {
    assert(text.len > 0);
    assert(@typeInfo(T) == .int);

    if (text.len > arguments_bytes_max) return usage();
    return std.fmt.parseInt(T, text, 10) catch usage();
}

fn usage() error{ArgumentsInvalid} {
    assert(usage_text.len > 0);
    assert(usage_text[usage_text.len - 1] == '\n');

    std.debug.print("{s}", .{usage_text});

    return error.ArgumentsInvalid;
}

fn run(io: std.Io, state: *State, fuzzer: Fuzzer, options: *const Options) !void {
    assert(fuzzer != .smoke);
    assert(options.events_max > 0);

    std.debug.print("fuzz {t}: seed={d} events_max={d}\n", .{
        fuzzer,
        options.seed,
        options.events_max,
    });

    state.prng = .init(options.seed);

    state.witness = .{
        .clipped_count = 0,
        .dropped_count = 0,
        .fragment_count = 0,
        .truncated_count = 0,
    };

    if (fuzzer == .sampler) sampler_reset(state);

    for (0..options.events_max) |_| {
        switch (fuzzer) {
            .datetime => try datetime_event(state),
            .encoder => try encoder_event(io, state),
            .escape => try escape_event(state),
            .sampler => try sampler_event(state),
            .smoke => unreachable,
        }
    }

    if (options.events_max >= witness_events_min) try witness_check(state, fuzzer);

    std.debug.print("fuzz {t}: passed\n", .{fuzzer});
}

fn datetime_event(state: *State) !void {
    assert(state.buffer.count <= arc.limits.entry_bytes_max);
    assert(state.texts.len == text_bytes_total);

    const random = state.prng.random();
    const time_ns = random.int(i64);
    const offset_minutes = random.intRangeAtMost(i32, -1439, 1439);

    try rfc3339_check(state, time_ns, offset_minutes);
    try epoch_check(state, time_ns);
    try duration_check(state, time_ns);
}

fn rfc3339_check(state: *State, time_ns: i64, offset_minutes: i32) !void {
    assert(offset_minutes > -1440);
    assert(offset_minutes < 1440);
    assert(@divFloor(time_ns, std.time.ns_per_s) >= datetime.seconds_min);
    assert(@divFloor(time_ns, std.time.ns_per_s) <= datetime.seconds_max);

    const local_ns = time_ns +| @as(i64, offset_minutes) * std.time.ns_per_min;
    const seconds = @divFloor(local_ns, std.time.ns_per_s);

    state.buffer.reset();
    datetime.rfc3339_write(&state.buffer, time_ns, offset_minutes, .fixed);

    const text = state.buffer.contents();

    if (seconds >= 0) {
        const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
        const year_day = epoch.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch.getDaySeconds();
        const nanoseconds: u64 = @intCast(@mod(local_ns, std.time.ns_per_s));

        var expected: [30]u8 = undefined;

        const prefix = try std.mem.print(&expected, calendar_format, .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            nanoseconds,
        });

        if (!std.mem.startsWith(u8, text, prefix)) return error.Rfc3339Diverged;
    }

    if (text[10] != 'T') return error.Rfc3339Malformed;

    if (text.len != 30) {
        if (text.len != 35) return error.Rfc3339Malformed;
    }
}

const calendar_format = "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}";

fn epoch_check(state: *State, time_ns: i64) !void {
    assert(state.buffer.count <= arc.limits.entry_bytes_max);
    assert(std.time.ns_per_s == 1_000_000_000);
    assert(@divTrunc(@abs(time_ns), std.time.ns_per_s) <= datetime.seconds_max);

    state.buffer.reset();
    datetime.epoch_write(&state.buffer, time_ns, .seconds);

    const text = state.buffer.contents();
    const negative = text[0] == '-';
    const digits = if (negative) text[1..] else text;
    const dot = std.mem.findScalar(u8, digits, '.');
    const whole_text = if (dot) |index| digits[0..index] else digits;
    const fraction_text = if (dot) |index| digits[index + 1 ..] else "";
    if (fraction_text.len > 9) return error.EpochFractionTooLong;

    var fraction_padded: [9]u8 = @splat('0');

    @memcpy(fraction_padded[0..fraction_text.len], fraction_text);

    const whole = std.fmt.parseInt(i128, whole_text, 10) catch return error.EpochMalformed;
    const fraction = std.fmt.parseInt(i128, &fraction_padded, 10) catch return error.EpochMalformed;
    const magnitude = whole * std.time.ns_per_s + fraction;
    const parsed = if (negative) -magnitude else magnitude;
    if (parsed != time_ns) return error.EpochDiverged;
}

fn duration_check(state: *State, nanoseconds: i64) !void {
    assert(state.buffer.count <= arc.limits.entry_bytes_max);
    assert(std.time.ns_per_hour == 3_600_000_000_000);
    assert(@divTrunc(@abs(nanoseconds), std.time.ns_per_s) <= datetime.seconds_max);

    state.buffer.reset();
    datetime.duration_write(&state.buffer, nanoseconds);

    const parsed = try duration_parse(state.buffer.contents());
    if (parsed != nanoseconds) return error.DurationDiverged;
}

fn duration_parse(text: []const u8) !i128 {
    assert(text.len > 0);
    assert(text.len <= arc.limits.entry_bytes_max);

    const negative = text[0] == '-';

    var cursor: u32 = if (negative) 1 else 0;
    var total: i128 = 0;

    for (0..4) |_| {
        if (cursor == text.len) break;

        const number_end = std.mem.findNonePos(u8, text, cursor, "0123456789.") orelse {
            return error.DurationMalformed;
        };

        const unit_end = std.mem.findAnyPos(u8, text, number_end, "0123456789") orelse text.len;
        const scale: i128 = try unit_scale(text[number_end..unit_end]);

        total += try decimal_scaled(text[cursor..number_end], scale);
        cursor = @intCast(unit_end);
    }

    if (cursor != text.len) return error.DurationMalformed;

    assert(total >= 0);

    const result = if (negative) -total else total;

    assert(@abs(result) == total);

    return result;
}

fn unit_scale(unit: []const u8) !i128 {
    assert(unit.len <= arc.limits.entry_bytes_max);
    assert(std.time.ns_per_us == 1_000);

    const units = [_]struct { text: []const u8, scale: i128 }{
        .{ .text = "h", .scale = std.time.ns_per_hour },
        .{ .text = "m", .scale = std.time.ns_per_min },
        .{ .text = "s", .scale = std.time.ns_per_s },
        .{ .text = "ms", .scale = std.time.ns_per_ms },
        .{ .text = "us", .scale = std.time.ns_per_us },
        .{ .text = "ns", .scale = 1 },
    };

    for (units) |each| {
        if (std.mem.eql(u8, unit, each.text)) return each.scale;
    }

    return error.DurationUnitUnknown;
}

fn decimal_scaled(text: []const u8, scale: i128) !i128 {
    assert(text.len > 0);
    assert(scale > 0);

    const dot = std.mem.findScalar(u8, text, '.') orelse text.len;
    const whole = std.fmt.parseInt(i128, text[0..dot], 10) catch return error.DurationMalformed;

    assert(whole >= 0);

    if (dot == text.len) {
        const result = whole * scale;

        assert(result >= whole);

        return result;
    }

    const fraction_text = text[dot + 1 ..];
    const fraction = std.fmt.parseInt(i128, fraction_text, 10) catch return error.DurationMalformed;

    var divisor: i128 = 1;

    for (fraction_text) |_| divisor *= 10;

    if (@rem(fraction * scale, divisor) != 0) return error.DurationInexact;

    const result = whole * scale + @divExact(fraction * scale, divisor);

    assert(result >= whole * scale);

    return result;
}

fn escape_event(state: *State) !void {
    assert(state.texts.len == text_bytes_total);
    assert(state.parse_bytes.len == parse_bytes_max);

    const random = state.prng.random();
    const length = random.uintAtMost(u32, 256);
    const text = state.texts[0..length];

    for (text) |*byte| {
        byte.* = switch (random.uintLessThan(u8, 4)) {
            0 => random.int(u8),
            1 => random.uintLessThan(u8, 0x20),
            2 => 'a' + random.uintLessThan(u8, 26),
            else => "\"\\\xc3\xa9\xf0\x9f\x98\x80"[random.uintLessThan(u8, 8)],
        };
    }

    state.buffer.reset();
    json.string_write(&state.buffer, text);

    var allocator_state: std.heap.FixedBufferAllocator = .init(&state.parse_bytes);

    const decoded = std.json.parseFromSliceLeaky(
        []const u8,
        allocator_state.allocator(),
        state.buffer.contents(),
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .use_last,
            .ignore_unknown_fields = false,
            .max_value_len = null,
            .parse_numbers = true,
        },
    ) catch return error.EscapeInvalidJson;

    if (!std.unicode.utf8ValidateSlice(text)) return;
    if (!std.mem.eql(u8, decoded, text)) return error.EscapeRoundTripDiverged;
}

fn sampler_reset(state: *State) void {
    assert(state.model.counts.len == Level.count);
    assert(state.model.resets.len == Level.count);

    const random = state.prng.random();
    const first = random.intRangeAtMost(u32, 1, 4);
    const thereafter = random.uintAtMost(u32, 4);

    state.sampler.init(&.{
        .first = first,
        .thereafter = thereafter,
        .tick_ns = std.time.ns_per_s,
    });

    state.model.counts = @splat(@splat(0));
    state.model.resets = @splat(@splat(0));
    state.time_ns = std.time.ns_per_s;
}

fn sampler_event(state: *State) !void {
    assert(state.sampler.first > 0);
    assert(state.sampler.tick_ns == std.time.ns_per_s);

    const random = state.prng.random();

    if (random.uintLessThan(u32, sampler_reset_interval) == 0) sampler_reset(state);

    const levels = [_]Level{ .debug, .information, .warn, .err };
    const level = levels[random.uintLessThan(u32, levels.len)];
    const messages = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
    const message = messages[random.uintLessThan(u32, messages.len)];
    const step_ns: i64 = random.intRangeAtMost(i64, 0, @divExact(std.time.ns_per_s, 4));

    state.time_ns += step_ns;

    const kept = state.sampler.sample(level, message, state.time_ns);
    const kept_model = model_sample(state, level, message, state.time_ns);
    if (kept != kept_model) return error.SamplerDiverged;

    if (!kept) state.witness.dropped_count += 1;
}

fn model_sample(state: *State, level: Level, message: []const u8, time_ns: i64) bool {
    assert(@backingInt(level) < @backingInt(Level.development_panic));
    assert(time_ns >= 0);
    assert(message.len > 0);

    var hash: u64 = 14_695_981_039_346_656_037;

    for (message) |byte| {
        hash ^= byte;
        hash *%= 1_099_511_628_211;
    }

    const bucket: u32 = @intCast(@rem(hash, sampler_module.bucket_count));
    const row = @backingInt(level);
    const reset_ns = state.model.resets[row][bucket];

    if (reset_ns == 0) {
        state.model.resets[row][bucket] = time_ns;
        state.model.counts[row][bucket] = 1;
    } else if (time_ns - reset_ns >= std.time.ns_per_s) {
        state.model.resets[row][bucket] = time_ns;
        state.model.counts[row][bucket] = 1;
    } else {
        state.model.counts[row][bucket] += 1;
    }

    const count = state.model.counts[row][bucket];
    const first = state.sampler.first;
    const thereafter = state.sampler.thereafter;

    if (count <= first) return true;
    if (thereafter == 0) return false;
    return @rem(count - first, thereafter) == 0;
}

fn encoder_event(io: std.Io, state: *State) !void {
    assert(state.pool.len == pool_count_max);
    assert(state.stream_bytes.len == stream_bytes_max);

    const random = state.prng.random();
    const encoding = encoding_random(state);

    state.texts_used = 0;

    const pool_count = random.intRangeAtMost(u32, 1, pool_count_max);

    for (0..pool_count) |index| field_random(state, @intCast(index));

    switch (random.uintLessThan(u8, 8)) {
        0 => pool_deepen(state, pool_count),
        1 => pool_namespace(state, pool_count),
        else => {},
    }

    const field_count = random.uintAtMost(u32, @min(pool_count, arc.limits.field_count_max));
    const context_count = random.uintAtMost(u32, field_count);
    const fields = state.pool[pool_count - field_count .. pool_count];
    const context = fields[0..context_count];
    const call = fields[context_count..];
    const message = text_random(state, message_bytes_fuzz);

    cores_configure(io, state, &encoding);

    var child: Logger = undefined;

    state.core.logger.child(&child, &.{ .fields = context, .name = "fuzz" });
    child.information(message, call, &@src());

    var named: Logger = undefined;

    state.core_plain.logger.child(&named, &.{ .fields = &.{}, .name = "fuzz" });
    named.information(message, fields, &@src());

    if (!std.mem.eql(u8, state.stream.buffered(), state.stream_plain.buffered())) {
        return error.ContextDiverged;
    }

    const clipped_count = state.core.clipped_count.load(.monotonic);
    const truncated_count = state.core.truncated_count.load(.monotonic);

    if (clipped_count != state.core_plain.clipped_count.load(.monotonic)) {
        return error.ClippingDiverged;
    }

    if (truncated_count != state.core_plain.truncated_count.load(.monotonic)) {
        return error.TruncationDiverged;
    }

    state.witness.clipped_count += clipped_count;
    state.witness.truncated_count += truncated_count;

    if (child.context.fragment_state != null) state.witness.fragment_count += 1;

    if (encoding.format == .json) try json_object_check(state, state.stream.buffered());
}

fn pool_deepen(state: *State, pool_count: u32) void {
    assert(pool_count > 0);
    assert(pool_count <= pool_count_max);

    if (pool_count < chain_count) return;

    for (pool_count - chain_count + 1..pool_count) |index| {
        const child = state.pool[index - 1 ..][0..1];

        state.pool[index] = .{ .key = "deep", .value = .{ .object = child } };
    }
}

fn pool_namespace(state: *State, pool_count: u32) void {
    assert(pool_count > 0);
    assert(pool_count <= pool_count_max);

    if (pool_count < chain_count) return;

    for (pool_count - chain_count..pool_count - 1) |index| {
        state.pool[index] = .{ .key = "n", .value = .namespace };
    }
}

fn witness_check(state: *const State, fuzzer: Fuzzer) error{WitnessMissing}!void {
    assert(fuzzer != .smoke);
    assert(witness_events_min > events_max_smoke);

    const witness = &state.witness;

    switch (fuzzer) {
        .datetime, .escape => {},
        .encoder => {
            std.debug.print("fuzz encoder: witnesses clipped={d} fragment={d} truncated={d}\n", .{
                witness.clipped_count,
                witness.fragment_count,
                witness.truncated_count,
            });

            if (witness.clipped_count == 0) return error.WitnessMissing;
            if (witness.fragment_count == 0) return error.WitnessMissing;
            if (witness.truncated_count == 0) return error.WitnessMissing;
        },
        .sampler => {
            std.debug.print("fuzz sampler: witnesses dropped={d}\n", .{witness.dropped_count});

            if (witness.dropped_count == 0) return error.WitnessMissing;
        },
        .smoke => unreachable,
    }
}

fn cores_configure(io: std.Io, state: *State, encoding: *const Encoding) void {
    assert(encoding.valid());
    assert(state.stream_bytes.len == state.stream_plain_bytes.len);

    const sinks = [_]Core.Sink{.{
        .encoding = encoding.*,
        .level = .debug,
        .writer = .{ .stream = &state.stream },
    }};

    const sinks_plain = [_]Core.Sink{.{
        .encoding = encoding.*,
        .level = .debug,
        .writer = .{ .stream = &state.stream_plain },
    }};

    var options: Core.Options = .{
        .caller = false,
        .clock = .{ .fixed_ns = state.prng.random().int(i64) },
        .error_output = .discard,
        .level = .debug,
        .sampling = null,
        .sinks = &sinks,
        .terminal_development_panic = .none,
        .terminal_fatal = .none,
        .thread_safe = false,
    };

    state.stream = .fixed(&state.stream_bytes);
    state.stream_plain = .fixed(&state.stream_plain_bytes);

    state.core.init(io, &options);

    options.sinks = &sinks_plain;

    state.core_plain.init(io, &options);
}

fn encoding_random(state: *State) Encoding {
    assert(Encoding.production.valid());
    assert(Encoding.development.valid());

    const random = state.prng.random();

    var encoding: Encoding = if (random.boolean()) .production else .development;

    encoding.console_fields = random.enumValue(Encoding.ConsoleFields);
    encoding.duration = random.enumValue(Encoding.Duration);
    encoding.format = random.enumValue(Encoding.Format);
    encoding.level = random.enumValue(Level.Style);
    encoding.line_ending = random.enumValue(Encoding.LineEnding);
    encoding.time = random.enumValue(Encoding.Time);
    encoding.time_offset_minutes = random.intRangeAtMost(i32, -1439, 1439);

    if (random.uintLessThan(u8, 8) == 0) encoding.key_level = "";
    if (random.uintLessThan(u8, 8) == 0) encoding.key_message = "";
    if (random.uintLessThan(u8, 8) == 0) encoding.key_time = "";

    assert(encoding.valid());

    return encoding;
}

fn field_random(state: *State, index: u32) void {
    assert(index < pool_count_max);
    assert(state.texts_used <= text_bytes_total);

    const random = state.prng.random();
    const kind = random.enumValue(FieldKind);
    const key = text_random_key(state);

    const value: Field.Value = switch (kind) {
        .binary => .{ .binary = text_random(state, text_bytes_fuzz) },
        .boolean => .{ .boolean = random.boolean() },
        .duration_ns => .{ .duration_ns = random.int(i64) },
        .float => .{ .float = @bitCast(random.int(u64)) },
        .integer => .{ .integer = random.int(i64) },
        .integer_list => blk: {
            for (&state.integers[index]) |*integer| integer.* = random.int(i64);

            const count = random.uintAtMost(u32, list_count_fuzz);

            break :blk .{ .integer_list = state.integers[index][0..count] };
        },
        .namespace => .namespace,
        .object => blk: {
            const count = random.uintAtMost(u32, @min(index, arc.limits.field_count_max));

            break :blk .{ .object = state.pool[index - count .. index] };
        },
        .skip => .skip,
        .string => .{ .string = text_random(state, text_bytes_fuzz) },
        .string_list => blk: {
            state.strings[index][0] = text_random(state, text_bytes_fuzz);
            state.strings[index][1] = text_random(state, text_bytes_fuzz);

            break :blk .{ .string_list = state.strings[index][0..random.uintAtMost(u32, 2)] };
        },
        .time_ns => .{ .time_ns = random.int(i64) },
        .unsigned => .{ .unsigned = random.int(u64) },
    };

    state.pool[index] = if (kind == .skip) .skip else .{ .key = key, .value = value };

    assert(state.pool[index].valid());
}

fn text_random(state: *State, length_max: u32) []const u8 {
    assert(length_max > 0);
    assert(state.texts_used + length_max <= text_bytes_total);

    const random = state.prng.random();
    const length = random.uintAtMost(u32, length_max);
    const text = state.texts[state.texts_used..][0..length];

    random.bytes(text);
    state.texts_used += length;

    return text;
}

fn text_random_key(state: *State) []const u8 {
    assert(state.texts_used + key_bytes_fuzz <= text_bytes_total);
    assert(key_bytes_fuzz > 0);

    const random = state.prng.random();
    const length = random.intRangeAtMost(u32, 1, key_bytes_fuzz);
    const text = state.texts[state.texts_used..][0..length];

    for (text) |*byte| byte.* = random.intRangeAtMost(u8, 0x20, 0x7e);

    state.texts_used += length;

    return text;
}

fn json_object_check(state: *State, text: []const u8) !void {
    assert(text.len <= stream_bytes_max);
    assert(state.parse_bytes.len == parse_bytes_max);

    const line = std.mem.trimEnd(u8, text, "\n");
    if (line.len == 0) return error.JsonEmpty;

    var allocator_state: std.heap.FixedBufferAllocator = .init(&state.parse_bytes);

    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator_state.allocator(), line, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .use_last,
        .ignore_unknown_fields = false,
        .max_value_len = null,
        .parse_numbers = true,
    }) catch return error.JsonInvalid;

    if (value != .object) return error.JsonNotAnObject;
}
