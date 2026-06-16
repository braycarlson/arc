const std = @import("std");
const arc = @import("arc");

const Buffer = arc.buffer_mod.Buffer;
const Clock = arc.Clock;
const Config = arc.Config;
const Logger = arc.Logger;
const Encoding = arc.encoder_mod.Encoding;
const EncoderConfig = arc.EncoderConfig;
const TimeEncoding = arc.encoder_config_mod.TimeEncoding;
const DurationEncoding = arc.encoder_config_mod.DurationEncoding;
const ConsoleFieldFormat = arc.encoder_config_mod.ConsoleFieldFormat;
const Field = arc.Field;

const seed_base: u64 = 0x9e3779b97f4a7c15;
const seed_count: u64 = 4;
const iterations_per_seed: u64 = 1_000_000;
const input_max: usize = 512;
const key_max: usize = 8;
const text_max: usize = 32;

const time_encodings = [_]TimeEncoding{ .epoch_s, .epoch_ms, .epoch_ns, .iso8601, .rfc3339 };
const duration_encodings = [_]DurationEncoding{ .seconds, .millis, .nanos, .string };
const encodings = [_]Encoding{ .json, .console };

fn config_logger(
    io: std.Io,
    output: *Buffer,
    encoding: Encoding,
    time_encoding: TimeEncoding,
    duration_encoding: DurationEncoding,
    offset_minutes: i32,
    console_fields: ConsoleFieldFormat,
) Logger {
    const encoder_config = EncoderConfig.production()
        .with_time_encoding(time_encoding)
        .with_duration_encoding(duration_encoding)
        .with_time_offset(offset_minutes)
        .with_console_fields(console_fields);

    var logger = Logger.init_with_config(
        io,
        Config.production()
            .with_level(.debug)
            .with_encoding(encoding)
            .with_encoder_config(encoder_config)
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

fn fill_biased(random: std.Random, out: []u8) void {
    for (out) |*byte| {
        byte.* = switch (random.uintLessThan(u8, 16)) {
            0, 1 => '"',
            2, 3 => '\\',
            4 => 0x00,
            5, 6 => random.uintLessThan(u8, 0x20),
            7, 8 => 0x80 + random.uintLessThan(u8, 0x40),
            9 => 0xc0 + random.uintLessThan(u8, 0x38),
            else => random.int(u8),
        };
    }
}

fn biased_i64(random: std.Random) i64 {
    return switch (random.uintLessThan(u8, 16)) {
        0 => std.math.minInt(i64),
        1 => std.math.minInt(i64) + 1,
        2 => std.math.maxInt(i64),
        3 => std.math.maxInt(i64) - 1,
        4 => 0,
        5 => 1,
        6 => -1,
        7 => 9_223_372_036,
        8 => 9_223_372_037,
        9 => -9_223_372_037,
        else => @bitCast(random.int(u64)),
    };
}

fn biased_u64(random: std.Random) u64 {
    return switch (random.uintLessThan(u8, 8)) {
        0 => 0,
        1 => 1,
        2 => std.math.maxInt(u64),
        3 => @as(u64, @intCast(std.math.maxInt(i64))) + 1,
        else => random.int(u64),
    };
}

fn biased_f64(random: std.Random) f64 {
    return switch (random.uintLessThan(u8, 8)) {
        0 => std.math.nan(f64),
        1 => std.math.inf(f64),
        2 => -std.math.inf(f64),
        3 => std.math.floatMax(f64),
        4 => -std.math.floatMax(f64),
        else => @bitCast(random.int(u64)),
    };
}

fn random_field(random: std.Random, key: []const u8, text: []u8) Field {
    return switch (random.uintLessThan(u8, 7)) {
        0 => blk: {
            const length = random.uintLessThan(usize, text.len + 1);
            fill_biased(random, text[0..length]);
            break :blk arc.string(key, text[0..length]);
        },
        1 => arc.int64(key, biased_i64(random)),
        2 => arc.uint64(key, biased_u64(random)),
        3 => arc.float64(key, biased_f64(random)),
        4 => arc.duration_ns(key, biased_i64(random)),
        5 => arc.time_ns(key, biased_i64(random)),
        else => arc.boolean(key, random.boolean()),
    };
}

fn valid_json(allocator: std.mem.Allocator, text: []const u8) bool {
    var line = text;

    while (line.len > 0 and (line[line.len - 1] == '\n' or line[line.len - 1] == '\r')) {
        line = line[0 .. line.len - 1];
    }

    if (line.len == 0) {
        return false;
    }

    return std.json.validate(allocator, line) catch false;
}

fn report_failure(prng_seed: u64, encoding: Encoding, mode: u8, index: u64) void {
    std.debug.print(
        "fuzz FAIL: invalid output. encoding={s} mode={d} seed=0x{x} iteration={d}\n",
        .{ @tagName(encoding), mode, prng_seed, index },
    );

    std.process.exit(1);
}

fn run_mode(random: std.Random, logger: *Logger, mode: u8) void {
    var input: [input_max]u8 = undefined;
    var key: [key_max]u8 = undefined;
    var text: [text_max]u8 = undefined;

    switch (mode) {
        0 => {
            const length = random.uintLessThan(usize, input_max + 1);
            fill_biased(random, input[0..length]);
            logger.info(input[0..length], &.{}, @src());
        },
        1 => {
            const length = random.uintLessThan(usize, input_max + 1);
            fill_biased(random, input[0..length]);
            logger.info("message", &.{arc.string("field", input[0..length])}, @src());
        },
        2 => {
            const length = random.uintLessThan(usize, input_max + 1);
            fill_biased(random, input[0..length]);
            logger.info("message", &.{arc.binary("payload", input[0..length])}, @src());
        },
        3 => {
            const field = random_field(random, "value", &text);
            logger.info("message", &.{field}, @src());
        },
        4 => run_multi(random, logger),
        else => {
            const length = 1 + random.uintLessThan(usize, key_max);
            fill_biased(random, key[0..length]);
            logger.info("message", &.{arc.string(key[0..length], "value")}, @src());
        },
    }
}

fn run_multi(random: std.Random, logger: *Logger) void {
    var fields: [arc.fields_max]Field = undefined;
    var keys: [arc.fields_max][key_max]u8 = undefined;
    var texts: [arc.fields_max][text_max]u8 = undefined;

    const count = random.uintLessThan(usize, arc.fields_max + 1);

    var index: usize = 0;

    while (index < count) : (index += 1) {
        const key_length = 1 + random.uintLessThan(usize, key_max);
        fill_biased(random, keys[index][0..key_length]);

        fields[index] = random_field(random, keys[index][0..key_length], texts[index][0..]);
    }

    logger.info("message", fields[0..count], @src());
}

fn run_seed(io: std.Io, scratch: []u8, prng_seed: u64) void {
    var prng = std.Random.DefaultPrng.init(prng_seed);
    const random = prng.random();

    var index: u64 = 0;

    while (index < iterations_per_seed) : (index += 1) {
        const encoding = encodings[random.uintLessThan(usize, encodings.len)];
        const time_encoding = time_encodings[random.uintLessThan(usize, time_encodings.len)];
        const duration_encoding = duration_encodings[random.uintLessThan(usize, duration_encodings.len)];
        const offset_minutes = random.intRangeAtMost(i32, -1439, 1439);
        const console_fields: ConsoleFieldFormat = if (random.boolean()) .key_value else .json;

        var output = Buffer.init();
        var logger = config_logger(io, &output, encoding, time_encoding, duration_encoding, offset_minutes, console_fields);

        const mode = random.uintLessThan(u8, 6);

        run_mode(random, &logger, mode);

        if (encoding == .json) {
            var fba = std.heap.FixedBufferAllocator.init(scratch);

            if (!valid_json(fba.allocator(), output.contents())) {
                report_failure(prng_seed, encoding, mode, index);
            }
        } else if (output.is_empty()) {
            report_failure(prng_seed, encoding, mode, index);
        }
    }
}

pub fn main() void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();

    const io = threaded.io();

    var scratch: [64 * 1024]u8 = undefined;

    var seed_index: u64 = 0;

    while (seed_index < seed_count) : (seed_index += 1) {
        const prng_seed = seed_base +% seed_index *% 0x100000001b3;

        run_seed(io, &scratch, prng_seed);
    }

    std.debug.print(
        "fuzz OK: seeds={d} iterations_each={d} total={d}\n",
        .{ seed_count, iterations_per_seed, seed_count * iterations_per_seed },
    );
}
