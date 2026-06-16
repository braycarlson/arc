const std = @import("std");
const arc = @import("arc");

const Buffer = arc.buffer_mod.Buffer;
const Clock = arc.Clock;
const Config = arc.Config;
const EncoderConfig = arc.EncoderConfig;
const Level = arc.Level;
const Logger = arc.Logger;

const warmup_iterations: u32 = 1_000;
const bench_iterations: u32 = 100_000;
const runs: u32 = 9;

const long_string = "x" ** 256;

var bench_io: std.Io = undefined;

fn base_config() Config {
    return Config.production()
        .with_level(.debug)
        .without_sampling()
        .without_caller()
        .with_error_output(.{ .nop = {} })
        .with_thread_safety(false)
        .with_stacktrace_level(.fatal);
}

fn make_logger(out: *Buffer, config: Config) Logger {
    var logger = Logger.init_with_config(bench_io, config.with_writer(.{ .buffer = out }));
    logger.set_clock(Clock.init_fixed(1_700_000_000));

    return logger;
}

fn setup_standard(out: *Buffer) Logger {
    return make_logger(out, base_config());
}

fn setup_warn(out: *Buffer) Logger {
    return make_logger(out, base_config().with_level(.warn));
}

fn setup_iso(out: *Buffer) Logger {
    return make_logger(
        out,
        base_config().with_encoder_config(
            EncoderConfig.production().with_time_encoding(.iso8601),
        ),
    );
}

fn setup_duration_string(out: *Buffer) Logger {
    return make_logger(
        out,
        base_config().with_encoder_config(
            EncoderConfig.production().with_duration_encoding(.string),
        ),
    );
}

fn ten_fields() [10]arc.Field {
    return .{
        arc.int("int", 1),
        arc.int64("int64", 2),
        arc.float64("float64", 3.0),
        arc.string("string", "four!"),
        arc.boolean("bool", true),
        arc.time_s("time", 1_700_000_000),
        arc.duration_ns("duration", 5_000_000_000),
        arc.err("an error message"),
        arc.string("another string", "done!"),
        arc.int("another int", -1),
    };
}

fn ten_ints() [10]arc.Field {
    return .{
        arc.int("a", 1),                    arc.int("b", -2), arc.int("c", 3),
        arc.int("d", -4),                   arc.int("e", 5),  arc.int("f", -6),
        arc.int("g", 7),                    arc.int("h", -8), arc.int("i", 9),
        arc.int("j", std.math.minInt(i64)),
    };
}

fn ten_strings_clean() [10]arc.Field {
    return .{
        arc.string("a", "alpha"),   arc.string("b", "bravo"),
        arc.string("c", "charlie"), arc.string("d", "delta"),
        arc.string("e", "echo"),    arc.string("f", "foxtrot"),
        arc.string("g", "golf"),    arc.string("h", "hotel"),
        arc.string("i", "india"),   arc.string("j", "juliet"),
    };
}

fn ten_strings_escaped() [10]arc.Field {
    return .{
        arc.string("a", "line\nbreak"),      arc.string("b", "tab\tsep"),
        arc.string("c", "quote\"here"),      arc.string("d", "back\\slash"),
        arc.string("e", "ctrl\x01char"),     arc.string("f", "mix\n\t\"\\x"),
        arc.string("g", "carriage\rret"),    arc.string("h", "bell\x07end"),
        arc.string("i", "two\nlines\nmore"), arc.string("j", "json\"{}\""),
    };
}

fn ten_floats() [10]arc.Field {
    return .{
        arc.float64("a", 3.14159), arc.float64("b", 2.71828),
        arc.float64("c", 1.41421), arc.float64("d", 0.57721),
        arc.float64("e", 1.61803), arc.float64("f", 2.50000),
        arc.float64("g", 0.00001), arc.float64("h", 9999.9999),
        arc.float64("i", -273.15), arc.float64("j", 6.022e23),
    };
}

fn ten_durations() [10]arc.Field {
    return .{
        arc.duration_ns("a", 90_000_000_000),     arc.duration_ns("b", 3_661_000_000_000),
        arc.duration_ns("c", 1_500_000_000),      arc.duration_ns("d", 500_000_000),
        arc.duration_ns("e", 250_000),            arc.duration_ns("f", 7),
        arc.duration_ns("g", 86_400_000_000_000), arc.duration_ns("h", 1_000),
        arc.duration_ns("i", 999_999_999),        arc.duration_ns("j", 42_000_000),
    };
}

fn ten_times() [10]arc.Field {
    return .{
        arc.time_ns("a", 1_700_000_000_000_000_000), arc.time_ns("b", 1_700_000_000_123_456_789),
        arc.time_ns("c", 0),                         arc.time_ns("d", -1_000_000_000),
        arc.time_ns("e", 1_500_000_000_000_000_000), arc.time_ns("f", 1_600_000_000_000_000_000),
        arc.time_ns("g", 1_650_000_000_000_000_000), arc.time_ns("h", 1_680_000_000_000_000_000),
        arc.time_ns("i", 1_690_000_000_000_000_000), arc.time_ns("j", 1_695_000_000_000_000_000),
    };
}

const Address = struct {
    city: []const u8,
    zip_code: u32,

    pub fn marshal_log_object(self: *const Address, encoder: *arc.ObjectEncoder) void {
        encoder.add_string("city", self.city);
        encoder.add_uint("zip", self.zip_code);
    }
};

const User = struct {
    name: []const u8,
    age: u32,
    address: Address,

    pub fn marshal_log_object(self: *const User, encoder: *arc.ObjectEncoder) void {
        encoder.add_string("name", self.name);
        encoder.add_uint("age", self.age);
        encoder.add_object("address", &self.address);
    }
};

fn fold(accumulator: *u64, data: []const u8) void {
    var sum = accumulator.*;

    for (data) |byte| {
        sum +%= byte;
    }

    accumulator.* = sum;
}

fn run_fields(logger: *Logger, out: *Buffer, accumulator: *u64, iterations: u32, fields: []const arc.Field) void {
    var i: u32 = 0;

    while (i < iterations) : (i += 1) {
        out.reset();
        logger.info("bench", fields, @src());
        fold(accumulator, out.contents());
    }

    std.debug.assert(i == iterations);
}

fn run_adding_fields(logger: *Logger, out: *Buffer, accumulator: *u64, iterations: u32) void {
    const fields = ten_fields();
    run_fields(logger, out, accumulator, iterations, &fields);
}

fn run_accumulated_context(logger: *Logger, out: *Buffer, accumulator: *u64, iterations: u32) void {
    const fields = ten_fields();
    var child = logger.with(&fields);

    var i: u32 = 0;

    while (i < iterations) : (i += 1) {
        out.reset();
        child.info("bench", &.{}, @src());
        fold(accumulator, out.contents());
    }

    std.debug.assert(i == iterations);
}

fn run_without_fields(logger: *Logger, out: *Buffer, accumulator: *u64, iterations: u32) void {
    run_fields(logger, out, accumulator, iterations, &.{});
}

fn run_int_fields(logger: *Logger, out: *Buffer, accumulator: *u64, iterations: u32) void {
    const fields = ten_ints();
    run_fields(logger, out, accumulator, iterations, &fields);
}

fn run_string_clean(logger: *Logger, out: *Buffer, accumulator: *u64, iterations: u32) void {
    const fields = ten_strings_clean();
    run_fields(logger, out, accumulator, iterations, &fields);
}

fn run_string_escaped(logger: *Logger, out: *Buffer, accumulator: *u64, iterations: u32) void {
    const fields = ten_strings_escaped();
    run_fields(logger, out, accumulator, iterations, &fields);
}

fn run_string_long(logger: *Logger, out: *Buffer, accumulator: *u64, iterations: u32) void {
    run_fields(logger, out, accumulator, iterations, &.{arc.string("payload", long_string)});
}

fn run_float_fields(logger: *Logger, out: *Buffer, accumulator: *u64, iterations: u32) void {
    const fields = ten_floats();
    run_fields(logger, out, accumulator, iterations, &fields);
}

fn run_duration_string(logger: *Logger, out: *Buffer, accumulator: *u64, iterations: u32) void {
    const fields = ten_durations();
    run_fields(logger, out, accumulator, iterations, &fields);
}

fn run_time_iso(logger: *Logger, out: *Buffer, accumulator: *u64, iterations: u32) void {
    const fields = ten_times();
    run_fields(logger, out, accumulator, iterations, &fields);
}

fn run_nested_object(logger: *Logger, out: *Buffer, accumulator: *u64, iterations: u32) void {
    const user = User{ .name = "alice", .age = 30, .address = .{ .city = "denver", .zip_code = 80014 } };

    var i: u32 = 0;

    while (i < iterations) : (i += 1) {
        out.reset();
        logger.info("bench", &.{arc.object("user", &user)}, @src());
        fold(accumulator, out.contents());
    }

    std.debug.assert(i == iterations);
}

fn run_checked_entry(logger: *Logger, out: *Buffer, accumulator: *u64, iterations: u32) void {
    const fields = ten_fields();

    var i: u32 = 0;

    while (i < iterations) : (i += 1) {
        out.reset();

        var maybe = logger.check_entry(.info, "bench", @src());

        if (maybe) |*checked_entry| {
            checked_entry.write(&fields);
        }

        fold(accumulator, out.contents());
    }

    std.debug.assert(i == iterations);
}

fn run_disabled_level(logger: *Logger, out: *Buffer, accumulator: *u64, iterations: u32) void {
    _ = out;

    var i: u32 = 0;

    while (i < iterations) : (i += 1) {
        var fields = ten_fields();
        std.mem.doNotOptimizeAway(&fields);
        logger.debug("disabled", &fields, @src());
        accumulator.* +%= @intFromBool(logger.check(.debug));
    }

    std.debug.assert(i == iterations);
}

fn run_check_disabled(logger: *Logger, out: *Buffer, accumulator: *u64, iterations: u32) void {
    _ = out;

    var i: u32 = 0;

    while (i < iterations) : (i += 1) {
        const enabled = logger.check(.debug);
        accumulator.* +%= @intFromBool(enabled);

        if (enabled) {
            logger.debug("never", &.{}, @src());
        }
    }

    std.debug.assert(i == iterations);
}

const RunFn = *const fn (*Logger, *Buffer, *u64, u32) void;
const SetupFn = *const fn (*Buffer) Logger;

const Benchmark = struct {
    name: []const u8,
    setup: SetupFn,
    func: RunFn,
};

const benchmarks = [_]Benchmark{
    .{ .name = "adding_fields", .setup = setup_standard, .func = run_adding_fields },
    .{ .name = "accumulated_context", .setup = setup_standard, .func = run_accumulated_context },
    .{ .name = "without_fields", .setup = setup_standard, .func = run_without_fields },
    .{ .name = "checked_entry", .setup = setup_standard, .func = run_checked_entry },
    .{ .name = "nested_object", .setup = setup_standard, .func = run_nested_object },
    .{ .name = "field_int", .setup = setup_standard, .func = run_int_fields },
    .{ .name = "field_string_clean", .setup = setup_standard, .func = run_string_clean },
    .{ .name = "field_string_escaped", .setup = setup_standard, .func = run_string_escaped },
    .{ .name = "field_string_long", .setup = setup_standard, .func = run_string_long },
    .{ .name = "field_float", .setup = setup_standard, .func = run_float_fields },
    .{ .name = "field_duration_string", .setup = setup_duration_string, .func = run_duration_string },
    .{ .name = "field_time_iso", .setup = setup_iso, .func = run_time_iso },
    .{ .name = "disabled_level", .setup = setup_warn, .func = run_disabled_level },
    .{ .name = "check_disabled", .setup = setup_warn, .func = run_check_disabled },
};

fn now_ns(io: std.Io) i128 {
    return std.Io.Timestamp.now(io, .awake).toNanoseconds();
}

fn elapsed_ns(io: std.Io, start: i128) u64 {
    const delta = now_ns(io) - start;

    std.debug.assert(delta >= 0);

    return @intCast(delta);
}

const Stats = struct {
    median_ns_per_op: f64,
    min_ns_per_op: f64,
    stddev_percent: f64,
};

fn compute_stats(samples: []u64) Stats {
    std.debug.assert(samples.len == runs);

    std.mem.sort(u64, samples, {}, std.sort.asc(u64));

    const median_total: f64 = @floatFromInt(samples[runs / 2]);
    const min_total: f64 = @floatFromInt(samples[0]);

    var sum: f64 = 0.0;

    for (samples) |sample| {
        sum += @floatFromInt(sample);
    }

    const mean = sum / @as(f64, @floatFromInt(runs));

    var variance: f64 = 0.0;

    for (samples) |sample| {
        const delta = @as(f64, @floatFromInt(sample)) - mean;
        variance += delta * delta;
    }

    variance /= @as(f64, @floatFromInt(runs));

    const stddev = @sqrt(variance);
    const iterations: f64 = @floatFromInt(bench_iterations);

    return .{
        .median_ns_per_op = median_total / iterations,
        .min_ns_per_op = min_total / iterations,
        .stddev_percent = if (mean > 0.0) (stddev / mean) * 100.0 else 0.0,
    };
}

fn measure(io: std.Io, bench: Benchmark, accumulator: *u64, samples: []u64) void {
    std.debug.assert(samples.len == runs);

    var run: u32 = 0;

    while (run < runs) : (run += 1) {
        var out = Buffer.init();
        var logger = bench.setup(&out);

        bench.func(&logger, &out, accumulator, warmup_iterations);

        const start = now_ns(io);
        bench.func(&logger, &out, accumulator, bench_iterations);
        samples[run] = elapsed_ns(io, start);

        std.debug.assert(samples[run] > 0);
    }

    std.debug.assert(run == runs);
}

pub fn main() void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();

    const io = threaded.io();
    bench_io = io;

    var accumulator: u64 = 0;

    std.debug.print(
        "\n{s:<24} {s:>12} {s:>12} {s:>14} {s:>9}\n",
        .{ "benchmark", "median ns", "min ns", "ops/sec", "stddev%" },
    );

    std.debug.print(
        "{s:<24} {s:>12} {s:>12} {s:>14} {s:>9}\n",
        .{ "------------------------", "------------", "------------", "--------------", "---------" },
    );

    for (benchmarks) |bench| {
        var samples: [runs]u64 = undefined;
        measure(io, bench, &accumulator, &samples);

        const stats = compute_stats(&samples);
        const ops_per_sec = if (stats.median_ns_per_op > 0.0)
            1_000_000_000.0 / stats.median_ns_per_op
        else
            0.0;

        std.debug.print(
            "{s:<24} {d:>12.2} {d:>12.2} {d:>14.0} {d:>9.1}\n",
            .{ bench.name, stats.median_ns_per_op, stats.min_ns_per_op, ops_per_sec, stats.stddev_percent },
        );
    }

    std.mem.doNotOptimizeAway(accumulator);

    std.debug.print("\n", .{});
}
