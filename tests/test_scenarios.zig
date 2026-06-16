const std = @import("std");
const arc = @import("arc");

const Buffer = arc.buffer_mod.Buffer;
const Clock = arc.Clock;
const Config = arc.Config;
const Level = arc.Level;
const Logger = arc.Logger;
const Observer = arc.Observer;
const Sampler = arc.sampler_mod.Sampler;
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

    std.debug.assert(logger.check(.debug));
    std.debug.assert(logger.context_fields_count == 0);
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

test "scenario disabled without fields" {
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

    std.debug.assert(output.contains("error visible"));
}

test "scenario disabled accumulated context" {
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

    std.debug.assert(output.contains("visible"));
    std.debug.assert(output.contains("payments"));
}

test "scenario disabled adding fields at call site" {
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

    std.debug.assert(output.contains("/orders"));
}

test "scenario enabled without fields across levels" {
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

    std.debug.assert(logger.check(.debug));
    std.debug.assert(logger.check(.fatal));
}

test "scenario enabled accumulated context" {
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

    std.debug.assert(output.contains("billing"));
    std.debug.assert(child.context_fields_count > 0);
}

test "scenario enabled adding fields at call site" {
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

    std.debug.assert(output.contains("/v1/users"));
    std.debug.assert(output.contains("512"));
}

test "scenario enabled combines accumulated and call-site fields" {
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

    std.debug.assert(output.contains("alice"));
}

test "scenario logger naming chains are reflected in output" {
    var output = Buffer.init();
    var logger = make_logger(&output);

    var child = logger.named("http").named("server").named("access");

    try std.testing.expectEqualStrings("http.server.access", child.name());

    child.info("served", &.{}, @src());

    try std.testing.expect(output.contains("http.server.access"));
    try std.testing.expect(output.contains("served"));

    std.debug.assert(child.name().len == "http.server.access".len);
    std.debug.assert(output.contains("http.server.access"));
}

test "scenario runtime level changes hide and reveal logs" {
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

    std.debug.assert(logger.check(.err));
    std.debug.assert(!logger.check(.info));
}

test "scenario fixed clock is encoded into log output" {
    var output = Buffer.init();
    var logger = make_logger(&output);

    logger.info("timestamped", &.{}, @src());

    try std.testing.expect(output.contains("1700000000"));
    try std.testing.expect(output.contains("timestamped"));

    std.debug.assert(output.contains("1700000000"));
}

test "scenario sampler keeps first two then drops later duplicates" {
    var output = Buffer.init();
    var counter = SamplingCounter.init();
    var sampler = Sampler.init(1_000_000_000, 2, 0);
    sampler.with_hook(.{ .counter = &counter });

    var logger = make_sampled_logger(&output, &sampler);

    logger.info("repeat", &.{}, @src());
    logger.info("repeat", &.{}, @src());
    logger.info("repeat", &.{}, @src());
    logger.info("repeat", &.{}, @src());

    try std.testing.expectEqual(@as(u64, 2), counter.sampled_count());
    try std.testing.expectEqual(@as(u64, 2), counter.dropped_count());

    std.debug.assert(counter.sampled_count() == 2);
    std.debug.assert(counter.dropped_count() == 2);
}

test "scenario sampler treats different messages independently" {
    var output = Buffer.init();
    var counter = SamplingCounter.init();
    var sampler = Sampler.init(1_000_000_000, 2, 0);
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

    std.debug.assert(counter.sampled_count() == 4);
    std.debug.assert(counter.dropped_count() == 2);
}

test "scenario named child inherits parent context" {
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

    std.debug.assert(child_a.name().len == 2);
    std.debug.assert(child_b.name().len == 5);
}

test "scenario observer based level counting" {
    var observer = Observer.init(.debug);
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

    try std.testing.expectEqual(@as(u32, 4), observer.len());
    try std.testing.expectEqual(@as(u32, 1), observer.count_by_level(.debug));
    try std.testing.expectEqual(@as(u32, 1), observer.count_by_level(.info));
    try std.testing.expectEqual(@as(u32, 1), observer.count_by_level(.warn));
    try std.testing.expectEqual(@as(u32, 1), observer.count_by_level(.err));

    std.debug.assert(observer.len() == 4);
}

test "scenario observer with accumulated context and call fields" {
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

    std.debug.assert(child.context_fields_count == 1);
    std.debug.assert(!output.is_empty());
}

test "scenario observer filter by message returns indices" {
    var observer = Observer.init(.debug);
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

    std.debug.assert(count == 3);
}

test "scenario observer filter by level returns indices" {
    var observer = Observer.init(.debug);
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

    std.debug.assert(count == 2);
}

test "scenario multiple resets allow reuse" {
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

    std.debug.assert(!output.is_empty());
}

test "scenario level escalation from debug to fatal" {
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

    std.debug.assert(logger.check(.err));
    std.debug.assert(!logger.check(.warn));
}

test "scenario child inherits clock from parent" {
    var observer = Observer.init(.debug);
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

    std.debug.assert(entry.timestamp_s == 999);
}

test "scenario deeply nested naming" {
    var logger = Logger.init_nop();

    var child = logger
        .named("a")
        .named("b")
        .named("c")
        .named("d")
        .named("e");

    try std.testing.expectEqualStrings("a.b.c.d.e", child.name());
    try std.testing.expectEqual(@as(u32, 5), child.scopes_count);

    std.debug.assert(child.scopes_count == 5);
    std.debug.assert(child.name_length == "a.b.c.d.e".len);
}

test "scenario sampler with clock advance resets counts" {
    var output = Buffer.init();
    var counter = SamplingCounter.init();
    var sampler = Sampler.init(1_000_000_000, 2, 0);
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

    std.debug.assert(counter.sampled_count() == 4);
    std.debug.assert(counter.dropped_count() == 2);
}
