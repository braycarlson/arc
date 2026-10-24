const std = @import("std");

const arc = @import("arc");

const assert = std.debug.assert;

const Core = arc.Core;
const Encoding = arc.Encoding;
const Field = arc.Field;
const Logger = arc.Logger;

const Benchmark = enum {
    adding_fields,
    accumulated_context,
    without_fields,
    nested_object,
    field_integer,
    field_string_clean,
    field_string_escaped,
    field_string_long,
    field_float,
    field_duration_string,
    field_time_rfc3339,
    disabled_level,
    enabled_check,
};

const Bench = struct {
    accumulator: u64,
    bytes: [arc.limits.entry_bytes_max]u8,
    core: Core,
    samples: [run_count]u64,
    stream: std.Io.Writer,
};

const Statistics = struct {
    deviation_percent: f64,
    operation_ns_median: f64,
    operation_ns_minimum: f64,
};

const iteration_count: u32 = 100_000;
const iteration_count_warmup: u32 = 1_000;
const run_count: u32 = 9;
const long_string: [256]u8 = @splat('x');

const fields_mixed = [_]Field{
    .{ .key = "int", .value = .{ .integer = 1 } },
    .{ .key = "int64", .value = .{ .integer = 2 } },
    .{ .key = "float64", .value = .{ .float = 3.0 } },
    .{ .key = "string", .value = .{ .string = "four!" } },
    .{ .key = "bool", .value = .{ .boolean = true } },
    .{ .key = "time", .value = .{ .time_ns = 1_700_000_000 * std.time.ns_per_s } },
    .{ .key = "duration", .value = .{ .duration_ns = 5_000_000_000 } },
    .{ .key = "error", .value = .{ .string = "an error message" } },
    .{ .key = "another string", .value = .{ .string = "done!" } },
    .{ .key = "another int", .value = .{ .integer = -1 } },
};

const fields_integer = [_]Field{
    .{ .key = "a", .value = .{ .integer = 1 } },
    .{ .key = "b", .value = .{ .integer = -2 } },
    .{ .key = "c", .value = .{ .integer = 3 } },
    .{ .key = "d", .value = .{ .integer = -4 } },
    .{ .key = "e", .value = .{ .integer = 5 } },
    .{ .key = "f", .value = .{ .integer = -6 } },
    .{ .key = "g", .value = .{ .integer = 7 } },
    .{ .key = "h", .value = .{ .integer = -8 } },
    .{ .key = "i", .value = .{ .integer = 9 } },
    .{ .key = "j", .value = .{ .integer = std.math.minInt(i64) } },
};

const fields_string_clean = [_]Field{
    .{ .key = "a", .value = .{ .string = "alpha" } },
    .{ .key = "b", .value = .{ .string = "bravo" } },
    .{ .key = "c", .value = .{ .string = "charlie" } },
    .{ .key = "d", .value = .{ .string = "delta" } },
    .{ .key = "e", .value = .{ .string = "echo" } },
    .{ .key = "f", .value = .{ .string = "foxtrot" } },
    .{ .key = "g", .value = .{ .string = "golf" } },
    .{ .key = "h", .value = .{ .string = "hotel" } },
    .{ .key = "i", .value = .{ .string = "india" } },
    .{ .key = "j", .value = .{ .string = "juliet" } },
};

const fields_string_escaped = [_]Field{
    .{ .key = "a", .value = .{ .string = "line\nbreak" } },
    .{ .key = "b", .value = .{ .string = "tab\tsep" } },
    .{ .key = "c", .value = .{ .string = "quote\"here" } },
    .{ .key = "d", .value = .{ .string = "back\\slash" } },
    .{ .key = "e", .value = .{ .string = "ctrl\x01char" } },
    .{ .key = "f", .value = .{ .string = "mix\n\t\"\\x" } },
    .{ .key = "g", .value = .{ .string = "carriage\rret" } },
    .{ .key = "h", .value = .{ .string = "bell\x07end" } },
    .{ .key = "i", .value = .{ .string = "two\nlines\nmore" } },
    .{ .key = "j", .value = .{ .string = "json\"{}\"" } },
};

const fields_string_long = [_]Field{
    .{ .key = "payload", .value = .{ .string = &long_string } },
};

const fields_float = [_]Field{
    .{ .key = "a", .value = .{ .float = 3.14159 } },
    .{ .key = "b", .value = .{ .float = 2.71828 } },
    .{ .key = "c", .value = .{ .float = 1.41421 } },
    .{ .key = "d", .value = .{ .float = 0.57721 } },
    .{ .key = "e", .value = .{ .float = 1.61803 } },
    .{ .key = "f", .value = .{ .float = 2.50000 } },
    .{ .key = "g", .value = .{ .float = 0.00001 } },
    .{ .key = "h", .value = .{ .float = 9999.9999 } },
    .{ .key = "i", .value = .{ .float = -273.15 } },
    .{ .key = "j", .value = .{ .float = 6.022e23 } },
};

const fields_duration = [_]Field{
    .{ .key = "a", .value = .{ .duration_ns = 90_000_000_000 } },
    .{ .key = "b", .value = .{ .duration_ns = 3_661_000_000_000 } },
    .{ .key = "c", .value = .{ .duration_ns = 1_500_000_000 } },
    .{ .key = "d", .value = .{ .duration_ns = 500_000_000 } },
    .{ .key = "e", .value = .{ .duration_ns = 250_000 } },
    .{ .key = "f", .value = .{ .duration_ns = 7 } },
    .{ .key = "g", .value = .{ .duration_ns = 86_400_000_000_000 } },
    .{ .key = "h", .value = .{ .duration_ns = 1_000 } },
    .{ .key = "i", .value = .{ .duration_ns = 999_999_999 } },
    .{ .key = "j", .value = .{ .duration_ns = 42_000_000 } },
};

const fields_time = [_]Field{
    .{ .key = "a", .value = .{ .time_ns = 1_700_000_000_000_000_000 } },
    .{ .key = "b", .value = .{ .time_ns = 1_700_000_000_123_456_789 } },
    .{ .key = "c", .value = .{ .time_ns = 0 } },
    .{ .key = "d", .value = .{ .time_ns = -1_000_000_000 } },
    .{ .key = "e", .value = .{ .time_ns = 1_500_000_000_000_000_000 } },
    .{ .key = "f", .value = .{ .time_ns = 1_600_000_000_000_000_000 } },
    .{ .key = "g", .value = .{ .time_ns = 1_650_000_000_000_000_000 } },
    .{ .key = "h", .value = .{ .time_ns = 1_680_000_000_000_000_000 } },
    .{ .key = "i", .value = .{ .time_ns = 1_690_000_000_000_000_000 } },
    .{ .key = "j", .value = .{ .time_ns = 1_695_000_000_000_000_000 } },
};

const fields_nested = [_]Field{
    .{ .key = "user", .value = .{ .object = &.{
        .{ .key = "name", .value = .{ .string = "alice" } },
        .{ .key = "age", .value = .{ .unsigned = 30 } },
        .{ .key = "address", .value = .{ .object = &.{
            .{ .key = "city", .value = .{ .string = "denver" } },
            .{ .key = "zip", .value = .{ .unsigned = 80014 } },
        } } },
    } } },
};

comptime {
    assert(iteration_count > iteration_count_warmup);
    assert(run_count > 2);
    assert(@typeInfo(Benchmark).@"enum".field_names.len == 13);
}

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len > 0);

    const bench = try init.gpa.create(Bench);
    defer init.gpa.destroy(bench);

    bench.accumulator = 0;

    std.debug.print("\n{s:<24} {s:>12} {s:>12} {s:>14} {s:>9}\n", .{
        "benchmark",
        "median ns",
        "min ns",
        "ops/sec",
        "stddev%",
    });

    for (std.enums.values(Benchmark)) |benchmark| {
        measure(init.io, bench, benchmark);
        report(benchmark, &statistics_of(&bench.samples));
    }

    std.mem.doNotOptimizeAway(bench.accumulator);
    std.debug.print("\n", .{});
}

fn measure(io: std.Io, bench: *Bench, benchmark: Benchmark) void {
    assert(bench.samples.len == run_count);
    assert(@typeInfo(Benchmark).@"enum".field_names.len > 0);

    for (&bench.samples) |*sample| {
        core_configure(io, bench, benchmark);
        run(bench, benchmark, iteration_count_warmup);

        const start = std.Io.Timestamp.now(io, .awake).nanoseconds;

        run(bench, benchmark, iteration_count);

        const end = std.Io.Timestamp.now(io, .awake).nanoseconds;

        assert(end > start);

        sample.* = @intCast(end - start);
    }
}

fn core_configure(io: std.Io, bench: *Bench, benchmark: Benchmark) void {
    assert(bench.bytes.len == arc.limits.entry_bytes_max);
    assert(bench.samples.len == run_count);

    var encoding: Encoding = .production;

    switch (benchmark) {
        .field_duration_string => encoding.duration = .string,
        .field_time_rfc3339 => encoding.time = .rfc3339,
        else => {},
    }

    const level: arc.Level = switch (benchmark) {
        .disabled_level, .enabled_check => .warn,
        else => .debug,
    };

    const sinks = [_]Core.Sink{.{
        .encoding = encoding,
        .level = .debug,
        .writer = .{ .stream = &bench.stream },
    }};

    bench.stream = .fixed(&bench.bytes);

    bench.core.init(io, &.{
        .caller = false,
        .clock = .{ .fixed_ns = 1_700_000_000 * std.time.ns_per_s },
        .error_output = .discard,
        .level = level,
        .sampling = null,
        .sinks = &sinks,
        .terminal_development_panic = .none,
        .terminal_fatal = .exit,
        .thread_safe = false,
    });
}

fn run(bench: *Bench, benchmark: Benchmark, iterations: u32) void {
    assert(iterations > 0);
    assert(iterations <= iteration_count);

    switch (benchmark) {
        .adding_fields => run_fields(bench, &fields_mixed, iterations),
        .accumulated_context => run_context(bench, iterations),
        .without_fields => run_fields(bench, &.{}, iterations),
        .nested_object => run_fields(bench, &fields_nested, iterations),
        .field_integer => run_fields(bench, &fields_integer, iterations),
        .field_string_clean => run_fields(bench, &fields_string_clean, iterations),
        .field_string_escaped => run_fields(bench, &fields_string_escaped, iterations),
        .field_string_long => run_fields(bench, &fields_string_long, iterations),
        .field_float => run_fields(bench, &fields_float, iterations),
        .field_duration_string => run_fields(bench, &fields_duration, iterations),
        .field_time_rfc3339 => run_fields(bench, &fields_time, iterations),
        .disabled_level => run_disabled(bench, iterations),
        .enabled_check => run_check(bench, iterations),
    }
}

fn run_fields(bench: *Bench, fields: []const Field, iterations: u32) void {
    assert(fields.len <= arc.limits.field_count_max);
    assert(iterations > 0);

    const logger = &bench.core.logger;

    for (0..iterations) |_| {
        bench.stream.end = 0;

        logger.information("bench", fields, &@src());
        bench.accumulator +%= checksum(bench.stream.buffered());
    }
}

fn run_context(bench: *Bench, iterations: u32) void {
    assert(iterations > 0);
    assert(fields_mixed.len <= arc.limits.context_field_count_max);

    var child: Logger = undefined;

    bench.core.logger.child(&child, &.{ .fields = &fields_mixed, .name = "" });

    for (0..iterations) |_| {
        bench.stream.end = 0;

        child.information("bench", &.{}, &@src());
        bench.accumulator +%= checksum(bench.stream.buffered());
    }
}

fn run_disabled(bench: *Bench, iterations: u32) void {
    assert(iterations > 0);
    assert(!bench.core.logger.enabled(.debug));

    const logger = &bench.core.logger;

    for (0..iterations) |_| {
        var fields = fields_mixed;

        std.mem.doNotOptimizeAway(&fields);
        logger.debug("disabled", &fields, &@src());
        bench.accumulator +%= @intFromBool(logger.enabled(.debug));
    }
}

fn run_check(bench: *Bench, iterations: u32) void {
    assert(iterations > 0);
    assert(!bench.core.logger.enabled(.debug));

    const logger = &bench.core.logger;

    for (0..iterations) |_| {
        std.mem.doNotOptimizeAway(logger);

        const enabled = logger.enabled(.debug);

        bench.accumulator +%= @intFromBool(enabled);

        if (enabled) logger.debug("never", &.{}, &@src());
    }
}

fn checksum(bytes: []const u8) u64 {
    assert(bytes.len <= arc.limits.entry_bytes_max);
    assert(bytes.len > 0);

    var sum: u64 = 0;

    for (bytes) |byte| sum += byte;

    return sum;
}

fn statistics_of(samples: *[run_count]u64) Statistics {
    assert(samples.len == run_count);
    assert(samples[0] > 0);

    std.mem.sort(u64, samples, {}, std.sort.asc(u64));

    var total: f64 = 0;

    for (samples) |sample| total += @floatFromInt(sample);

    const mean: f64 = total / run_count;

    var variance: f64 = 0;

    for (samples) |sample| {
        const delta = @as(f64, @floatFromInt(sample)) - mean;

        variance += delta * delta;
    }

    const deviation: f64 = @sqrt(variance / run_count);
    const median: f64 = @floatFromInt(samples[@divFloor(run_count, 2)]);
    const minimum: f64 = @floatFromInt(samples[0]);

    return .{
        .deviation_percent = deviation / mean * 100,
        .operation_ns_median = median / iteration_count,
        .operation_ns_minimum = minimum / iteration_count,
    };
}

fn report(benchmark: Benchmark, statistics: *const Statistics) void {
    assert(statistics.operation_ns_median > 0);
    assert(statistics.operation_ns_minimum <= statistics.operation_ns_median);

    const operations_per_second = 1_000_000_000 / statistics.operation_ns_median;

    std.debug.print("{s:<24} {d:>12.2} {d:>12.2} {d:>14.0} {d:>9.1}\n", .{
        @tagName(benchmark),
        statistics.operation_ns_median,
        statistics.operation_ns_minimum,
        operations_per_second,
        statistics.deviation_percent,
    });
}
