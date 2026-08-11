const std = @import("std");
const arc = @import("arc");

const assert = std.debug.assert;

const Buffer = arc.Buffer;
const Clock = arc.Clock;
const Config = arc.Config;
const Logger = arc.Logger;
const Observer = arc.Observer;
const Sampler = arc.Sampler;
const SamplingCounter = arc.SamplingCounter;

fn make_logger(output: *Buffer) Logger {
    var logger = Logger.init_with_config(
        std.testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = output })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    assert(logger.check(.debug));
    assert(logger.context_fields_count == 0);

    return logger;
}

fn make_sampled_logger(output: *Buffer, sampler: *Sampler) Logger {
    var logger = Logger.init_with_config(
        std.testing.io,
        Config.production()
            .with_level(.debug)
            .without_caller()
            .with_writer(.{ .buffer = output })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.set_sampler(sampler);
    logger.set_clock(Clock.init_fixed(1_700_000_000));

    return logger;
}

test "scenario: a disabled level with no fields writes nothing" {
    var output = Buffer.init();

    var logger = Logger.init_with_config(
        std.testing.io,
        Config.production()
            .with_level(.err)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    logger.debug("debug hidden", &.{}, @src());
    logger.info("info hidden", &.{}, @src());
    logger.warn("warn hidden", &.{}, @src());

    try std.testing.expect(output.is_empty());
    try std.testing.expect(!logger.check(.debug));
    try std.testing.expect(!logger.check(.info));
    try std.testing.expect(!logger.check(.warn));
    try std.testing.expect(logger.check(.err));

    logger.@"error"("error visible", &.{}, @src());

    try std.testing.expect(output.contains("error visible"));
    try std.testing.expect(!output.contains("debug hidden"));
    try std.testing.expect(!output.contains("info hidden"));
    try std.testing.expect(!output.contains("warn hidden"));

    assert(output.contains("error visible"));
}

test "scenario: a disabled level with accumulated context writes nothing" {
    var output = Buffer.init();

    var logger = Logger.init_with_config(
        std.testing.io,
        Config.production()
            .with_level(.err)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    var child = logger.with(&.{
        arc.string("service", "payments"),
        arc.string("region", "ca-central"),
    });

    child.info("hidden", &.{}, @src());

    try std.testing.expect(output.is_empty());
    try std.testing.expect(!child.check(.info));
    try std.testing.expect(child.check(.err));

    child.@"error"("visible", &.{}, @src());

    try std.testing.expect(output.contains("visible"));
    try std.testing.expect(output.contains("service"));
    try std.testing.expect(output.contains("payments"));
    try std.testing.expect(output.contains("region"));
    try std.testing.expect(output.contains("ca-central"));
    try std.testing.expect(!output.contains("hidden"));

    assert(output.contains("visible"));
    assert(output.contains("payments"));
}

test "scenario: a disabled level with call-site fields writes nothing" {
    var output = Buffer.init();

    var logger = Logger.init_with_config(
        std.testing.io,
        Config.production()
            .with_level(.err)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    logger.info("hidden", &.{
        arc.string("method", "GET"),
        arc.string("path", "/health"),
        arc.int("status", 200),
    }, @src());

    try std.testing.expect(output.is_empty());

    logger.@"error"("visible", &.{
        arc.string("method", "POST"),
        arc.string("path", "/orders"),
        arc.int("status", 500),
    }, @src());

    try std.testing.expect(output.contains("visible"));
    try std.testing.expect(output.contains("method"));
    try std.testing.expect(output.contains("POST"));
    try std.testing.expect(output.contains("path"));
    try std.testing.expect(output.contains("/orders"));
    try std.testing.expect(output.contains("status"));
    try std.testing.expect(output.contains("500"));
    try std.testing.expect(!output.contains("hidden"));

    assert(output.contains("/orders"));
}

test "scenario: an enabled level with no fields writes an envelope" {
    var output = Buffer.init();
    var logger = make_logger(&output);

    logger.debug("debug msg", &.{}, @src());
    try std.testing.expect(output.contains("debug msg"));
    output.reset();

    logger.info("info msg", &.{}, @src());
    try std.testing.expect(output.contains("info msg"));
    output.reset();

    logger.warn("warn msg", &.{}, @src());
    try std.testing.expect(output.contains("warn msg"));
    output.reset();

    logger.@"error"("error msg", &.{}, @src());
    try std.testing.expect(output.contains("error msg"));
    output.reset();

    logger.dpanic("dpanic msg", &.{}, @src());
    try std.testing.expect(output.contains("dpanic msg"));
    output.reset();

    assert(logger.check(.debug));
    assert(logger.check(.fatal));
}

test "scenario: an enabled level writes its accumulated context" {
    var output = Buffer.init();
    var logger = make_logger(&output);

    var child = logger
        .named("api")
        .with(&.{
        arc.string("service", "billing"),
        arc.boolean("sampled", true),
    });

    child.info("request complete", &.{}, @src());

    try std.testing.expect(output.contains("request complete"));
    try std.testing.expect(output.contains("api"));
    try std.testing.expect(output.contains("service"));
    try std.testing.expect(output.contains("billing"));
    try std.testing.expect(output.contains("sampled"));
    try std.testing.expect(output.contains("true"));

    assert(output.contains("billing"));
    assert(child.context_fields_count > 0);
}

test "scenario: an enabled level writes the fields given at the call site" {
    var output = Buffer.init();
    var logger = make_logger(&output);

    logger.info("request", &.{
        arc.string("method", "GET"),
        arc.string("path", "/v1/users"),
        arc.int("status", 200),
        arc.uint("bytes", 512),
        arc.boolean("cache_hit", false),
    }, @src());

    try std.testing.expect(output.contains("request"));
    try std.testing.expect(output.contains("method"));
    try std.testing.expect(output.contains("GET"));
    try std.testing.expect(output.contains("path"));
    try std.testing.expect(output.contains("/v1/users"));
    try std.testing.expect(output.contains("status"));
    try std.testing.expect(output.contains("200"));
    try std.testing.expect(output.contains("bytes"));
    try std.testing.expect(output.contains("512"));
    try std.testing.expect(output.contains("cache_hit"));
    try std.testing.expect(output.contains("false"));

    assert(output.contains("/v1/users"));
    assert(output.contains("512"));
}

test "scenario: an enabled level combines accumulated and call-site fields" {
    var output = Buffer.init();
    var logger = make_logger(&output);

    var child = logger.with(&.{
        arc.string("service", "auth"),
        arc.string("node", "a-01"),
    });

    child.info("login", &.{
        arc.string("user", "alice"),
        arc.boolean("success", true),
    }, @src());

    try std.testing.expect(output.contains("login"));
    try std.testing.expect(output.contains("service"));
    try std.testing.expect(output.contains("auth"));
    try std.testing.expect(output.contains("node"));
    try std.testing.expect(output.contains("a-01"));
    try std.testing.expect(output.contains("user"));
    try std.testing.expect(output.contains("alice"));
    try std.testing.expect(output.contains("success"));
    try std.testing.expect(output.contains("true"));

    assert(output.contains("alice"));
}

test "scenario: a chained logger name reaches the output" {
    var output = Buffer.init();
    var logger = make_logger(&output);

    var child = logger.named("http").named("server").named("access");

    try std.testing.expectEqualStrings("http.server.access", child.name());

    child.info("served", &.{}, @src());

    try std.testing.expect(output.contains("http.server.access"));
    try std.testing.expect(output.contains("served"));

    assert(child.name().len == "http.server.access".len);
    assert(output.contains("http.server.access"));
}

test "scenario: a runtime level change hides and reveals entries" {
    var output = Buffer.init();
    var logger = make_logger(&output);

    logger.info("before change", &.{}, @src());
    try std.testing.expect(output.contains("before change"));

    output.reset();
    logger.set_level(.err);

    logger.info("hidden", &.{}, @src());
    try std.testing.expect(output.is_empty());

    logger.@"error"("visible", &.{}, @src());
    try std.testing.expect(output.contains("visible"));
    try std.testing.expect(!output.contains("hidden"));

    assert(logger.check(.err));
    assert(!logger.check(.info));
}

test "scenario: a fixed clock reaches the encoded output" {
    var output = Buffer.init();
    var logger = make_logger(&output);

    logger.info("timestamped", &.{}, @src());

    try std.testing.expect(output.contains("1700000000"));
    try std.testing.expect(output.contains("timestamped"));

    assert(output.contains("1700000000"));
}

test "scenario: a sampler keeps the first duplicates and drops the rest" {
    var output = Buffer.init();
    var counter = SamplingCounter.init();
    var sampler: Sampler = undefined;

    sampler.init(.{ .tick_ns = 1_000_000_000, .first = 2, .thereafter = 0 });
    sampler.with_hook(.{ .counter = &counter });

    var logger = make_sampled_logger(&output, &sampler);

    logger.info("repeat", &.{}, @src());
    logger.info("repeat", &.{}, @src());
    logger.info("repeat", &.{}, @src());
    logger.info("repeat", &.{}, @src());

    try std.testing.expectEqual(@as(u64, 2), counter.sampled_count());
    try std.testing.expectEqual(@as(u64, 2), counter.dropped_count());

    assert(counter.sampled_count() == 2);
    assert(counter.dropped_count() == 2);
}

test "scenario: a sampler treats different messages independently" {
    var output = Buffer.init();
    var counter = SamplingCounter.init();
    var sampler: Sampler = undefined;

    sampler.init(.{ .tick_ns = 1_000_000_000, .first = 2, .thereafter = 0 });
    sampler.with_hook(.{ .counter = &counter });

    var logger = make_sampled_logger(&output, &sampler);

    logger.info("msg-a", &.{}, @src());
    logger.info("msg-a", &.{}, @src());
    logger.info("msg-a", &.{}, @src());

    logger.info("msg-b", &.{}, @src());
    logger.info("msg-b", &.{}, @src());
    logger.info("msg-b", &.{}, @src());

    try std.testing.expectEqual(@as(u64, 4), counter.sampled_count());
    try std.testing.expectEqual(@as(u64, 2), counter.dropped_count());

    assert(counter.sampled_count() == 4);
    assert(counter.dropped_count() == 2);
}

test "scenario: a named child inherits the context of its parent" {
    var output = Buffer.init();
    var logger = make_logger(&output);

    var child_a = logger.named("db").with(&.{
        arc.string("engine", "postgres"),
    });

    var child_b = logger.named("cache").with(&.{
        arc.string("engine", "redis"),
    });

    child_a.info("from a", &.{}, @src());
    try std.testing.expect(output.contains("db"));
    try std.testing.expect(output.contains("postgres"));
    try std.testing.expect(!output.contains("redis"));

    output.reset();

    child_b.info("from b", &.{}, @src());
    try std.testing.expect(output.contains("cache"));
    try std.testing.expect(output.contains("redis"));
    try std.testing.expect(!output.contains("postgres"));

    assert(child_a.name().len == 2);
    assert(child_b.name().len == 5);
}

test "scenario: an observer counts the entries written at each level" {
    var observer: Observer = undefined;

    observer.init(.debug);

    var logger = Logger.init_with_config(
        std.testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .nop = {} })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.core = .{ .observer = &observer };
    logger.set_clock(Clock.init_fixed(1_700_000_000));

    logger.debug("d", &.{}, @src());
    logger.info("i", &.{}, @src());
    logger.warn("w", &.{}, @src());
    logger.@"error"("e", &.{}, @src());

    try std.testing.expectEqual(@as(u32, 4), observer.count());
    try std.testing.expectEqual(@as(u32, 1), observer.count_by_level(.debug));
    try std.testing.expectEqual(@as(u32, 1), observer.count_by_level(.info));
    try std.testing.expectEqual(@as(u32, 1), observer.count_by_level(.warn));
    try std.testing.expectEqual(@as(u32, 1), observer.count_by_level(.err));

    assert(observer.count() == 4);
}

test "scenario: an observer records accumulated context beside call-site fields" {
    var output = Buffer.init();

    var logger = Logger.init_with_config(
        std.testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    var child = logger.with(&.{
        arc.string("env", "staging"),
    });

    child.info("deploy", &.{
        arc.string("version", "1.2.3"),
        arc.boolean("canary", true),
    }, @src());

    try std.testing.expect(output.contains("deploy"));
    try std.testing.expect(output.contains("env"));
    try std.testing.expect(output.contains("staging"));
    try std.testing.expect(output.contains("version"));
    try std.testing.expect(output.contains("1.2.3"));
    try std.testing.expect(output.contains("canary"));
    try std.testing.expect(output.contains("true"));

    assert(child.context_fields_count == 1);
    assert(!output.is_empty());
}

test "scenario: an observer returns the indexes of entries matching a message" {
    var observer: Observer = undefined;

    observer.init(.debug);

    var logger = Logger.init_with_config(
        std.testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .nop = {} })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.core = .{ .observer = &observer };
    logger.set_clock(Clock.init_fixed(1_700_000_000));

    logger.info("alpha", &.{}, @src());
    logger.info("beta", &.{}, @src());
    logger.info("alpha", &.{}, @src());
    logger.warn("alpha", &.{}, @src());

    var indices: [128]u32 = undefined;
    const count = observer.filter_by_message("alpha", &indices);

    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expectEqual(@as(u32, 0), indices[0]);
    try std.testing.expectEqual(@as(u32, 2), indices[1]);
    try std.testing.expectEqual(@as(u32, 3), indices[2]);

    assert(count == 3);
}

test "scenario: an observer returns the indexes of entries at a level" {
    var observer: Observer = undefined;

    observer.init(.debug);

    var logger = Logger.init_with_config(
        std.testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .nop = {} })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.core = .{ .observer = &observer };
    logger.set_clock(Clock.init_fixed(1_700_000_000));

    logger.debug("d", &.{}, @src());
    logger.info("i", &.{}, @src());
    logger.warn("w", &.{}, @src());
    logger.info("i2", &.{}, @src());

    var indices: [128]u32 = undefined;
    const count = observer.filter_by_level(.info, &indices);

    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expectEqual(@as(u32, 1), indices[0]);
    try std.testing.expectEqual(@as(u32, 3), indices[1]);

    assert(count == 2);
}

test "scenario: an observer survives repeated resets and stays usable" {
    var output = Buffer.init();
    var logger = make_logger(&output);

    logger.info("first", &.{}, @src());
    try std.testing.expect(output.contains("first"));

    output.reset();
    try std.testing.expect(output.is_empty());

    logger.info("second", &.{}, @src());
    try std.testing.expect(output.contains("second"));
    try std.testing.expect(!output.contains("first"));

    output.reset();

    logger.warn("third", &.{}, @src());
    try std.testing.expect(output.contains("third"));

    assert(!output.is_empty());
}

test "scenario: raising the level from debug to fatal narrows the output" {
    var output = Buffer.init();
    var logger = make_logger(&output);

    logger.set_level(.debug);
    logger.debug("at-debug", &.{}, @src());
    try std.testing.expect(output.contains("at-debug"));

    output.reset();
    logger.set_level(.info);
    logger.debug("hidden-debug", &.{}, @src());
    try std.testing.expect(output.is_empty());

    logger.info("at-info", &.{}, @src());
    try std.testing.expect(output.contains("at-info"));

    output.reset();
    logger.set_level(.warn);
    logger.info("hidden-info", &.{}, @src());
    try std.testing.expect(output.is_empty());

    logger.warn("at-warn", &.{}, @src());
    try std.testing.expect(output.contains("at-warn"));

    output.reset();
    logger.set_level(.err);
    logger.warn("hidden-warn", &.{}, @src());
    try std.testing.expect(output.is_empty());

    logger.@"error"("at-error", &.{}, @src());
    try std.testing.expect(output.contains("at-error"));

    assert(logger.check(.err));
    assert(!logger.check(.warn));
}

test "scenario: a child logger inherits the clock of its parent" {
    var observer: Observer = undefined;

    observer.init(.debug);

    var logger = Logger.init_with_config(
        std.testing.io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .nop = {} })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.core = .{ .observer = &observer };
    logger.set_clock(Clock.init_fixed(999));

    var child = logger.named("sub");

    child.info("timed", &.{}, @src());

    const entry = observer.first().?;

    try std.testing.expectEqual(@as(i64, 999), entry.timestamp_s);

    assert(entry.timestamp_s == 999);
}

test "scenario: deeply nested naming builds one dotted name" {
    var logger = Logger.init_nop();

    var child = logger
        .named("a")
        .named("b")
        .named("c")
        .named("d")
        .named("e");

    try std.testing.expectEqualStrings("a.b.c.d.e", child.name());
    try std.testing.expectEqual(@as(u32, 5), child.scopes_count);

    assert(child.scopes_count == 5);
    assert(child.name_length == "a.b.c.d.e".len);
}

test "scenario: advancing the clock resets the counts a sampler keeps" {
    var output = Buffer.init();
    var counter = SamplingCounter.init();
    var sampler: Sampler = undefined;

    sampler.init(.{ .tick_ns = 1_000_000_000, .first = 2, .thereafter = 0 });
    sampler.with_hook(.{ .counter = &counter });

    var logger = make_sampled_logger(&output, &sampler);

    logger.info("msg", &.{}, @src());
    logger.info("msg", &.{}, @src());
    logger.info("msg", &.{}, @src());

    try std.testing.expectEqual(@as(u64, 2), counter.sampled_count());
    try std.testing.expectEqual(@as(u64, 1), counter.dropped_count());

    logger.clock.advance(2);

    logger.info("msg", &.{}, @src());
    logger.info("msg", &.{}, @src());
    logger.info("msg", &.{}, @src());

    try std.testing.expectEqual(@as(u64, 4), counter.sampled_count());
    try std.testing.expectEqual(@as(u64, 2), counter.dropped_count());

    assert(counter.sampled_count() == 4);
    assert(counter.dropped_count() == 2);
}
