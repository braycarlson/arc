const std = @import("std");

const arc = @import("arc.zig");

const assert = std.debug.assert;

const Core = arc.Core;
const Field = arc.Field;
const Logger = arc.Logger;
const Observer = arc.Observer;

const Harness = struct {
    bytes: [harness_bytes_max]u8,
    core: Core,
    stream: std.Io.Writer,

    fn text(harness: *const Harness) []const u8 {
        assert(harness.stream.end <= harness_bytes_max);
        assert(harness.core.sink_count > 0);

        return harness.stream.buffered();
    }

    fn contains(harness: *const Harness, needle: []const u8) bool {
        assert(needle.len > 0);
        assert(harness.stream.end <= harness_bytes_max);

        return std.mem.find(u8, harness.text(), needle) != null;
    }

    fn reset(harness: *Harness) void {
        assert(harness.stream.end <= harness_bytes_max);

        harness.stream.end = 0;
    }
};

const harness_bytes_max: u32 = 256 * 1024;

const options_test: Core.Options = .{
    .caller = false,
    .clock = .{ .fixed_ns = 1_700_000_000 * std.time.ns_per_s },
    .error_output = .discard,
    .level = .debug,
    .sampling = null,
    .sinks = &.{.{ .encoding = .production, .level = .debug, .writer = .discard }},
    .terminal_development_panic = .none,
    .terminal_fatal = .none,
    .thread_safe = false,
};

fn harness_create(options: *const Core.Options) !*Harness {
    assert(options.sinks.len == 1);
    assert(options.sinks[0].writer == .discard);

    const harness = try testing.allocator.create(Harness);

    const sinks = [1]Core.Sink{.{
        .encoding = options.sinks[0].encoding,
        .level = options.sinks[0].level,
        .writer = .{ .stream = &harness.stream },
    }};

    var patched = options.*;

    patched.sinks = &sinks;
    harness.stream = .fixed(&harness.bytes);

    harness.core.init(testing.io, &patched);

    return harness;
}

fn harness_destroy(harness: *Harness) void {
    assert(harness.core.sink_count > 0);
    assert(harness.stream.end <= harness_bytes_max);

    testing.allocator.destroy(harness);
}

fn line_count(text: []const u8) u32 {
    assert(text.len <= harness_bytes_max);

    const result: u32 = @intCast(std.mem.countScalar(u8, text, '\n'));

    assert(result <= text.len);

    return result;
}

fn json_lines_check(text: []const u8) !u32 {
    assert(text.len <= harness_bytes_max);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var count: u32 = 0;

    for (0..line_count(text) + 1) |_| {
        const line = lines.next() orelse break;
        if (line.len == 0) continue;

        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .use_last,
            .ignore_unknown_fields = false,
            .max_value_len = null,
            .parse_numbers = true,
        });

        defer parsed.deinit();

        try testing.expect(parsed.value == .object);

        count += 1;
    }

    return count;
}

const testing = std.testing;

test "a logger writes nothing below the threshold and moves with the threshold" {
    var options = options_test;

    options.level = .warn;

    const harness = try harness_create(&options);
    defer harness_destroy(harness);

    const logger = &harness.core.logger;

    logger.debug("hidden", &.{}, &@src());
    logger.information("hidden", &.{}, &@src());

    try testing.expectEqual(@as(usize, 0), harness.text().len);
    try testing.expect(!logger.enabled(.information));
    try testing.expect(logger.enabled(.warn));

    logger.warn("visible", &.{}, &@src());
    harness.core.level_set(.err);
    logger.warn("hidden", &.{}, &@src());
    logger.err("also visible", &.{}, &@src());

    try testing.expect(harness.contains("\"msg\":\"visible\""));
    try testing.expect(harness.contains("\"msg\":\"also visible\""));
    try testing.expect(!harness.contains("hidden"));
    try testing.expectEqual(@as(u32, 2), line_count(harness.text()));
}

test "every level method writes its own level text" {
    const harness = try harness_create(&options_test);
    defer harness_destroy(harness);

    const logger = &harness.core.logger;

    logger.debug("d", &.{}, &@src());
    logger.information("i", &.{}, &@src());
    logger.warn("w", &.{}, &@src());
    logger.err("e", &.{}, &@src());
    logger.development_panic("p", &.{}, &@src());
    logger.fatal("f", &.{}, &@src());

    const expected = [_][]const u8{ "debug", "info", "warn", "error", "dpanic", "fatal" };

    for (expected) |text| {
        var needle: [32]u8 = undefined;

        const quoted = try std.mem.print(&needle, "\"level\":\"{s}\"", .{text});

        try testing.expect(harness.contains(quoted));
    }

    try testing.expectEqual(@as(u32, 6), try json_lines_check(harness.text()));
}

test "a development panic is written even when the threshold is fatal" {
    var options = options_test;

    options.level = .fatal;

    const harness = try harness_create(&options);
    defer harness_destroy(harness);

    try testing.expect(!harness.core.logger.enabled(.err));
    try testing.expect(harness.core.logger.enabled(.development_panic));

    harness.core.logger.development_panic("forced", &.{}, &@src());

    try testing.expect(harness.contains("\"msg\":\"forced\""));
}

test "a child carries its dotted name and its context into every entry" {
    const harness = try harness_create(&options_test);
    defer harness_destroy(harness);

    var http: Logger = undefined;
    var server: Logger = undefined;

    harness.core.logger.child(&http, &.{
        .fields = &.{.{ .key = "service", .value = .{ .string = "api" } }},
        .name = "http",
    });

    http.child(&server, &.{
        .fields = &.{.{ .key = "port", .value = .{ .integer = 8080 } }},
        .name = "server",
    });

    server.information("serving", &.{.{ .key = "path", .value = .{ .string = "/" } }}, &@src());

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"logger\":\"http.server\",\"msg\":\"serving\"," ++
            "\"service\":\"api\",\"port\":8080,\"path\":\"/\"}\n",
        harness.text(),
    );

    try testing.expectEqualStrings("http", http.name.slice());
    try testing.expectEqual(@as(u32, 0), harness.core.logger.name.count);
    try testing.expectEqual(@as(u32, 0), harness.core.logger.context.fields.count);
}

test "two children of one logger do not share the context added to either" {
    const harness = try harness_create(&options_test);
    defer harness_destroy(harness);

    var first: Logger = undefined;
    var second: Logger = undefined;

    harness.core.logger.child(&first, &.{
        .fields = &.{.{ .key = "branch", .value = .{ .string = "a" } }},
        .name = "",
    });

    harness.core.logger.child(&second, &.{
        .fields = &.{.{ .key = "branch", .value = .{ .string = "b" } }},
        .name = "",
    });

    first.information("from-a", &.{}, &@src());

    try testing.expect(harness.contains("\"branch\":\"a\""));
    try testing.expect(!harness.contains("\"branch\":\"b\""));

    harness.reset();
    second.information("from-b", &.{}, &@src());

    try testing.expect(harness.contains("\"branch\":\"b\""));
    try testing.expect(!harness.contains("\"branch\":\"a\""));
}

test "an encoded context matches the same fields given at the call site" {
    const context = [_]Field{
        .{ .key = "a", .value = .{ .integer = 1 } },
        .{ .key = "b", .value = .{ .string = "x" } },
        .{ .key = "ns", .value = .namespace },
        .{ .key = "c", .value = .{ .duration_ns = 1_500_000_000 } },
        .skip,
    };

    const call = [_]Field{
        .{ .key = "d", .value = .{ .integer = 4 } },
        .{ .key = "e", .value = .{ .boolean = true } },
    };

    var combined: [context.len + call.len]Field = undefined;

    @memcpy(combined[0..context.len], &context);
    @memcpy(combined[context.len..], &call);

    var encodings = [_]arc.Encoding{ .production, .production, .development };

    encodings[1].format = .console;

    for (&encodings) |*encoding| {
        const sinks = [_]Core.Sink{.{
            .encoding = encoding.*,
            .level = .debug,
            .writer = .discard,
        }};

        var options = options_test;

        options.sinks = &sinks;

        const cached = try harness_create(&options);
        defer harness_destroy(cached);

        const plain = try harness_create(&options);
        defer harness_destroy(plain);

        var child: Logger = undefined;

        cached.core.logger.child(&child, &.{ .fields = &context, .name = "" });

        try testing.expect(child.context.fragment_state != null);

        child.information("message", &call, &@src());
        plain.core.logger.information("message", &combined, &@src());

        try testing.expectEqualStrings(plain.text(), cached.text());
    }
}

test "a context too large to cache still encodes on every call" {
    const big: [600]u8 = @splat('c');
    const harness = try harness_create(&options_test);
    defer harness_destroy(harness);

    var child: Logger = undefined;

    harness.core.logger.child(&child, &.{
        .fields = &.{.{ .key = "big", .value = .{ .string = &big } }},
        .name = "",
    });

    try testing.expect(child.context.fragment_state == null);

    child.information("first", &.{}, &@src());
    child.information("second", &.{}, &@src());

    try testing.expectEqual(@as(u32, 2), try json_lines_check(harness.text()));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, harness.text(), &big));
}

test "an oversized entry is replaced by a notice and counted" {
    const big: [9000]u8 = @splat('z');
    const harness = try harness_create(&options_test);
    defer harness_destroy(harness);

    harness.core.logger.information(&big, &.{}, &@src());

    harness.core.logger.information(
        "payload",
        &.{
            .{ .key = "body", .value = .{ .string = &big } },
        },
        &@src(),
    );

    harness.core.logger.information("small", &.{}, &@src());

    try testing.expectEqual(@as(u64, 2), harness.core.truncated_count.load(.monotonic));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, harness.text(), "arc_truncated"));
    try testing.expectEqual(@as(u32, 3), try json_lines_check(harness.text()));
}

test "a sampler keeps the first entries of a message each tick and counts the rest" {
    var options = options_test;

    options.sampling = .{ .first = 2, .thereafter = 0, .tick_ns = std.time.ns_per_s };

    const harness = try harness_create(&options);
    defer harness_destroy(harness);

    const logger = &harness.core.logger;

    for (0..3) |_| logger.information("repeat", &.{}, &@src());
    for (0..3) |_| logger.information("other", &.{}, &@src());

    try testing.expectEqual(@as(u32, 4), line_count(harness.text()));
    try testing.expectEqual(@as(u64, 2), harness.core.sampler.dropped_count.load(.monotonic));

    harness.core.clock.fixed_ns += 2 * std.time.ns_per_s;

    for (0..3) |_| logger.information("repeat", &.{}, &@src());

    try testing.expectEqual(@as(u32, 6), line_count(harness.text()));
    try testing.expectEqual(@as(u64, 3), harness.core.sampler.dropped_count.load(.monotonic));

    logger.development_panic("repeat", &.{}, &@src());

    try testing.expectEqual(@as(u32, 7), line_count(harness.text()));
}

test "an observer sink records structured entries at or above its level" {
    const observer = try testing.allocator.create(Observer);
    defer testing.allocator.destroy(observer);

    const core = try testing.allocator.create(Core);
    defer testing.allocator.destroy(core);

    const sinks = [_]Core.Sink{.{
        .encoding = .production,
        .level = .warn,
        .writer = .{ .observer = observer },
    }};

    var options = options_test;

    options.sinks = &sinks;

    observer.init();
    core.init(testing.io, &options);

    var child: Logger = undefined;

    core.logger.child(&child, &.{
        .fields = &.{.{ .key = "service", .value = .{ .string = "api" } }},
        .name = "http",
    });

    child.information("hidden", &.{}, &@src());
    child.warn("slow", &.{.{ .key = "status", .value = .{ .integer = 503 } }}, &@src());
    child.err("down", &.{}, &@src());

    const records = observer.records();

    try testing.expectEqual(@as(usize, 2), records.len);
    try testing.expectEqual(arc.Level.warn, records[0].level);
    try testing.expectEqualStrings("slow", records[0].message.slice());
    try testing.expectEqualStrings("http", records[0].name.slice());
    try testing.expectEqual(@as(u32, 2), records[0].fields.count);

    const status = records[0].field("status") orelse return error.FieldMissing;

    try testing.expectEqual(@as(i64, 503), status.value.integer);
    try testing.expectEqual(@as(i64, 1_700_000_000 * std.time.ns_per_s), records[1].time_ns);
}

test "a tee writes each entry to every sink whose level admits it" {
    var buffer_all: [4096]u8 = undefined;
    var buffer_errors: [4096]u8 = undefined;
    var stream_all: std.Io.Writer = .fixed(&buffer_all);
    var stream_errors: std.Io.Writer = .fixed(&buffer_errors);

    const core = try testing.allocator.create(Core);
    defer testing.allocator.destroy(core);

    var console: arc.Encoding = .production;

    console.format = .console;

    const sinks = [_]Core.Sink{
        .{ .encoding = .production, .level = .debug, .writer = .{ .stream = &stream_all } },
        .{ .encoding = console, .level = .err, .writer = .{ .stream = &stream_errors } },
    };

    var options = options_test;

    options.sinks = &sinks;

    core.init(testing.io, &options);
    core.logger.information("routine", &.{}, &@src());
    core.logger.err("broken", &.{}, &@src());

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"ts\":1700000000,\"msg\":\"routine\"}\n" ++
            "{\"level\":\"error\",\"ts\":1700000000,\"msg\":\"broken\"}\n",
        stream_all.buffered(),
    );

    try testing.expectEqualStrings("1700000000\terror\tbroken\n", stream_errors.buffered());
    try testing.expect(core.logger.enabled(.debug));
}

test "a failing write reports to the error output and logging continues" {
    const failure_text = "arc internal error: failed to write log entry\n";

    var buffer_full: [8]u8 = undefined;
    var buffer_errors: [512]u8 = undefined;
    var stream_full: std.Io.Writer = .fixed(&buffer_full);
    var stream_errors: std.Io.Writer = .fixed(&buffer_errors);

    const core = try testing.allocator.create(Core);
    defer testing.allocator.destroy(core);

    const sinks = [_]Core.Sink{.{
        .encoding = .production,
        .level = .debug,
        .writer = .{ .stream = &stream_full },
    }};

    var options = options_test;

    options.error_output = .{ .stream = &stream_errors };
    options.sinks = &sinks;

    core.init(testing.io, &options);
    core.logger.information("first", &.{}, &@src());
    core.logger.information("second", &.{}, &@src());

    try testing.expectEqual(@as(u64, 2), core.failed_count.load(.monotonic));

    try testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, stream_errors.buffered(), failure_text),
    );
}

test "a closed file descriptor fails every write without stopping the logger" {
    const path = ".zz_core_stale.tmp";

    const file = try std.Io.Dir.cwd().createFile(testing.io, path, .{
        .exclusive = false,
        .lock = .none,
        .lock_nonblocking = false,
        .permissions = .default_file,
        .read = false,
        .truncate = true,
    });

    file.close(testing.io);
    defer std.Io.Dir.cwd().deleteFile(testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.panic("failed to remove {s}: {t}", .{ path, err }),
    };

    const core = try testing.allocator.create(Core);
    defer testing.allocator.destroy(core);

    const sinks = [_]Core.Sink{.{
        .encoding = .production,
        .level = .debug,
        .writer = .{ .file = file },
    }};

    var options = options_test;

    options.sinks = &sinks;

    core.init(testing.io, &options);
    core.logger.information("first", &.{}, &@src());
    core.logger.information("second", &.{}, &@src());

    try testing.expectEqual(@as(u64, 2), core.failed_count.load(.monotonic));
}

test "entries reach a rotating file through a development encoding" {
    const path = ".zz_core_rotating.tmp";
    defer std.Io.Dir.cwd().deleteFile(testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.panic("failed to remove {s}: {t}", .{ path, err }),
    };

    var rotating_file: arc.RotatingFile = undefined;

    try rotating_file.init(testing.io, &.{
        .backup_count = 1,
        .path = path,
        .roll_daily = false,
        .size_max = 1024 * 1024,
    });

    const core = try testing.allocator.create(Core);
    defer testing.allocator.destroy(core);

    var encoding: arc.Encoding = .development;

    encoding.level = .capital;
    encoding.time = .rfc3339_nano;

    const sinks = [_]Core.Sink{.{
        .encoding = encoding,
        .level = .debug,
        .writer = .{ .rotating_file = &rotating_file },
    }};

    var options = options_test;

    options.clock = .{ .fixed_ns = std.time.ns_per_s };
    options.sinks = &sinks;

    core.init(testing.io, &options);

    core.logger.information(
        "integration message",
        &.{
            .{ .key = "phase", .value = .{ .string = "startup" } },
        },
        &@src(),
    );

    try core.flush();

    rotating_file.deinit(testing.io);

    var buffer: [4096]u8 = undefined;

    const content = try std.Io.Dir.cwd().readFile(testing.io, path, &buffer);

    try testing.expectEqualStrings(
        "1970-01-01T00:00:01.000000000Z\tINFO\tintegration message\t{\"phase\":\"startup\"}\n",
        content,
    );
}

test "exactly the field bound of fields encode to valid json" {
    var fields: [arc.limits.field_count_max]Field = undefined;
    var keys: [arc.limits.field_count_max][8]u8 = undefined;

    for (&fields, &keys, 0..) |*field, *key, index| {
        field.* = .{
            .key = try std.mem.print(key, "k{d}", .{index}),
            .value = .{ .integer = @intCast(index) },
        };
    }

    const harness = try harness_create(&options_test);
    defer harness_destroy(harness);

    harness.core.logger.information("max", &fields, &@src());

    try testing.expectEqual(@as(u32, 1), try json_lines_check(harness.text()));
    try testing.expect(harness.contains("\"k0\":0"));
    try testing.expect(harness.contains("\"k31\":31"));
}

test "a name segment of the full name bound fits" {
    const segment: [arc.limits.name_bytes_max]u8 = @splat('x');
    const harness = try harness_create(&options_test);
    defer harness_destroy(harness);

    var named: Logger = undefined;

    harness.core.logger.child(&named, &.{ .fields = &.{}, .name = &segment });
    named.information("named", &.{}, &@src());

    try testing.expectEqual(arc.limits.name_bytes_max, named.name.count);
    try testing.expect(harness.contains(&segment));
}

test "nesting past the object and namespace bounds is dropped and stays balanced" {
    var objects: [12]Field = undefined;

    objects[11] = .{ .key = "leaf", .value = .{ .string = "deep" } };

    for (0..11) |offset| {
        const index = 10 - offset;

        objects[index] = .{ .key = "level", .value = .{ .object = objects[index + 1 ..][0..1] } };
    }

    var namespaces: [12]Field = undefined;

    for (namespaces[0..11]) |*field| field.* = .{ .key = "n", .value = .namespace };

    namespaces[11] = .{ .key = "leaf", .value = .{ .string = "value" } };

    const harness = try harness_create(&options_test);
    defer harness_destroy(harness);

    harness.core.logger.information("objects", objects[0..1], &@src());
    harness.core.logger.information("namespaces", &namespaces, &@src());

    try testing.expectEqual(@as(u32, 2), try json_lines_check(harness.text()));
    try testing.expect(!harness.contains("deep"));
    try testing.expect(harness.contains("\"leaf\":\"value\""));
}

test "an entry clipped at a nesting bound is written and counted" {
    var objects: [12]Field = undefined;

    objects[11] = .{ .key = "leaf", .value = .{ .string = "deep" } };

    for (0..11) |offset| {
        const index = 10 - offset;

        objects[index] = .{ .key = "level", .value = .{ .object = objects[index + 1 ..][0..1] } };
    }

    const harness = try harness_create(&options_test);
    defer harness_destroy(harness);

    harness.core.logger.information("shallow", objects[10..11], &@src());

    try testing.expectEqual(@as(u64, 0), harness.core.clipped_count.load(.monotonic));

    harness.core.logger.information("deep", objects[0..1], &@src());

    try testing.expectEqual(@as(u64, 1), harness.core.clipped_count.load(.monotonic));
    try testing.expectEqual(@as(u64, 0), harness.core.truncated_count.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), try json_lines_check(harness.text()));
}

test "a console prefix past its bound drops the namespace and counts the entry" {
    const key: [arc.limits.key_bytes_max]u8 = @splat('n');

    comptime assert(7 * (key.len + 1) <= arc.limits.console_prefix_bytes_max);
    comptime assert(8 * (key.len + 1) > arc.limits.console_prefix_bytes_max);

    var fields: [9]Field = undefined;

    for (fields[0..8]) |*field| field.* = .{ .key = &key, .value = .namespace };

    fields[8] = .{ .key = "leaf", .value = .{ .integer = 1 } };

    var options = options_test;
    var encoding: arc.Encoding = .production;

    encoding.format = .console;
    encoding.console_fields = .key_value;

    const sinks = [_]Core.Sink{.{ .encoding = encoding, .level = .debug, .writer = .discard }};

    options.sinks = &sinks;

    const harness = try harness_create(&options);
    defer harness_destroy(harness);

    harness.core.logger.information("prefix", fields[1..], &@src());

    try testing.expectEqual(@as(u64, 0), harness.core.clipped_count.load(.monotonic));

    harness.core.logger.information("prefix", &fields, &@src());

    try testing.expectEqual(@as(u64, 1), harness.core.clipped_count.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), line_count(harness.text()));
    try testing.expect(harness.contains("n.leaf=1"));
}

const Worker = struct {
    big: []const u8,
    logger: *const Logger,

    fn run(worker: *const Worker) void {
        assert(worker.big.len > arc.limits.entry_bytes_max);
        assert(worker.logger.enabled(.information));

        for (0..worker_entry_count) |index| {
            worker.logger.information(
                "concurrent",
                &.{
                    .{ .key = "index", .value = .{ .unsigned = index } },
                },
                &@src(),
            );
        }

        for (0..worker_big_count) |_| worker.logger.information(worker.big, &.{}, &@src());
    }
};

const worker_big_count: u32 = 50;
const worker_count: u32 = 8;
const worker_entry_count: u32 = 200;

const spawn_config: std.Thread.SpawnConfig = .{
    .allocator = null,
    .stack_size = std.Thread.SpawnConfig.default_stack_size,
};

test "concurrent writes through a thread-safe core are whole lines and none are lost" {
    const big: [arc.limits.entry_bytes_max + 1]u8 = @splat('x');

    var options = options_test;

    options.thread_safe = true;

    const harness = try harness_create(&options);
    defer harness_destroy(harness);

    const worker: Worker = .{ .big = &big, .logger = &harness.core.logger };

    var threads: [worker_count]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(spawn_config, Worker.run, .{&worker});
    }

    for (&threads) |*thread| thread.join();

    const expected = worker_count * (worker_entry_count + worker_big_count);

    try testing.expectEqual(expected, try json_lines_check(harness.text()));

    try testing.expectEqual(
        @as(u64, worker_count * worker_big_count),
        harness.core.truncated_count.load(.monotonic),
    );
}
