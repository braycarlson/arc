const std = @import("std");
const arc = @import("arc");

const Buffer = arc.buffer_mod.Buffer;
const Clock = arc.Clock;
const Config = arc.Config;
const Field = arc.Field;
const Level = arc.Level;
const Logger = arc.Logger;
const Observer = arc.Observer;
const ObservedEntry = arc.ObservedEntry;
const Writer = arc.Writer;

fn test_logger(output: *Buffer) Logger {
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

fn test_observer_logger(observer: *Observer) Logger {
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

    logger.core = .{ .observer = observer };
    logger.set_clock(Clock.init_fixed(1_700_000_000));

    std.debug.assert(logger.core.enabled(observer.minimum_level));
    std.debug.assert(logger.context_fields_count == 0);
    return logger;
}

test "logger writes json output" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    logger.info("server started", &.{}, @src());

    try std.testing.expect(output.contains("server started"));
    try std.testing.expect(output.contains("info"));

    std.debug.assert(output.contains("server started"));
    std.debug.assert(!output.is_empty());
}

test "logger respects level threshold" {
    var output = Buffer.init();
    var logger = Logger.init_with_config(
        std.testing.io,
        Config.production()
            .with_level(.warn)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .buffer = &output })
            .with_error_output(.{ .nop = {} })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.debug("should not appear", &.{}, @src());
    logger.info("should not appear", &.{}, @src());

    try std.testing.expect(output.is_empty());

    logger.warn("should appear", &.{}, @src());

    try std.testing.expect(output.contains("should appear"));

    std.debug.assert(output.contains("should appear"));
    std.debug.assert(!output.contains("should not appear"));
}

test "logger includes structured fields" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    logger.info("request", &.{
        arc.string("method", "GET"),
        arc.string("path", "/health"),
        arc.int("status", 200),
    }, @src());

    try std.testing.expect(output.contains("method"));
    try std.testing.expect(output.contains("GET"));
    try std.testing.expect(output.contains("path"));
    try std.testing.expect(output.contains("/health"));
    try std.testing.expect(output.contains("status"));
    try std.testing.expect(output.contains("200"));

    std.debug.assert(output.contains("GET"));
    std.debug.assert(output.contains("/health"));
}

test "logger handles numeric and float fields" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    logger.info("metrics", &.{
        arc.uint64("bytes", 1024),
        arc.float64("ratio", 0.95),
        arc.int32("offset", -42),
    }, @src());

    try std.testing.expect(output.contains("bytes"));
    try std.testing.expect(output.contains("1024"));
    try std.testing.expect(output.contains("ratio"));
    try std.testing.expect(output.contains("offset"));
    try std.testing.expect(output.contains("-42"));

    std.debug.assert(output.contains("1024"));
    std.debug.assert(output.contains("-42"));
}

test "logger handles boolean and duration fields" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    logger.info("config", &.{
        arc.boolean("verbose", true),
        arc.boolean("dry_run", false),
        arc.duration_ns("timeout", 5_000_000_000),
    }, @src());

    try std.testing.expect(output.contains("verbose"));
    try std.testing.expect(output.contains("true"));
    try std.testing.expect(output.contains("dry_run"));
    try std.testing.expect(output.contains("false"));
    try std.testing.expect(output.contains("timeout"));

    std.debug.assert(output.contains("true"));
    std.debug.assert(output.contains("false"));
}

test "logger named child includes namespace" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    var child = logger.named("http");

    child.info("request", &.{}, @src());

    try std.testing.expect(output.contains("http"));
    try std.testing.expect(output.contains("request"));

    std.debug.assert(child.name().len > 0);
    std.debug.assert(output.contains("http"));
}

test "logger with context fields includes them" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    var child = logger.with(&.{
        arc.string("service", "api"),
    });

    child.info("test", &.{}, @src());

    try std.testing.expect(output.contains("service"));
    try std.testing.expect(output.contains("api"));

    std.debug.assert(child.context_fields_count == 1);
    std.debug.assert(output.contains("service"));
}

test "logger set_level changes level at runtime" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    logger.set_level(.err);

    logger.info("hidden", &.{}, @src());

    try std.testing.expect(output.is_empty());

    logger.@"error"("visible", &.{}, @src());

    try std.testing.expect(output.contains("visible"));
    try std.testing.expect(!output.contains("hidden"));

    std.debug.assert(output.contains("visible"));
    std.debug.assert(!output.contains("hidden"));
}

test "logger check returns correct enablement" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    try std.testing.expect(logger.check(.debug));
    try std.testing.expect(logger.check(.info));
    try std.testing.expect(logger.check(.fatal));

    logger.set_level(.err);

    try std.testing.expect(!logger.check(.debug));
    try std.testing.expect(!logger.check(.info));
    try std.testing.expect(logger.check(.err));
    try std.testing.expect(logger.check(.fatal));

    std.debug.assert(!logger.check(.debug));
    std.debug.assert(logger.check(.err));
}

test "logger nop produces no output" {
    var logger = Logger.init_nop();

    logger.info("nothing", &.{}, @src());
    logger.@"error"("nothing", &.{}, @src());

    try std.testing.expect(!logger.check(.debug));
    try std.testing.expect(!logger.check(.info));
    try std.testing.expect(!logger.check(.err));
    try std.testing.expect(logger.check(.fatal));

    std.debug.assert(!logger.check(.info));
    std.debug.assert(logger.check(.fatal));
}

test "logger all level methods produce output" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    logger.debug("d", &.{}, @src());
    try std.testing.expect(output.contains("d"));

    output.reset();
    logger.info("i", &.{}, @src());
    try std.testing.expect(output.contains("i"));

    output.reset();
    logger.warn("w", &.{}, @src());
    try std.testing.expect(output.contains("w"));

    output.reset();
    logger.@"error"("e", &.{}, @src());
    try std.testing.expect(output.contains("e"));

    std.debug.assert(!output.is_empty());
    std.debug.assert(output.len() > 0);
}

test "logger includes fixed timestamp" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    logger.info("timestamped", &.{}, @src());

    try std.testing.expect(output.contains("1700000000"));

    std.debug.assert(output.contains("1700000000"));
    std.debug.assert(output.contains("timestamped"));
}

test "logger observer records entries" {
    var observer = Observer.init(.debug);
    var logger = test_observer_logger(&observer);

    logger.info("hello", &.{}, @src());
    logger.debug("world", &.{}, @src());

    try std.testing.expectEqual(@as(u32, 2), observer.len());
    try std.testing.expect(!observer.is_empty());

    const first = observer.first().?;
    try std.testing.expectEqualStrings("hello", first.message());
    try std.testing.expectEqual(Level.info, first.at_level);

    const last = observer.last().?;
    try std.testing.expectEqualStrings("world", last.message());
    try std.testing.expectEqual(Level.debug, last.at_level);

    std.debug.assert(observer.len() == 2);
    std.debug.assert(first.at_level == .info);
}

test "logger observer respects minimum level" {
    var observer = Observer.init(.warn);
    var logger = test_observer_logger(&observer);

    logger.core = .{ .observer = &observer };

    logger.debug("hidden-d", &.{}, @src());
    logger.info("hidden-i", &.{}, @src());
    logger.warn("visible-w", &.{}, @src());
    logger.@"error"("visible-e", &.{}, @src());

    try std.testing.expectEqual(@as(u32, 2), observer.len());
    try std.testing.expectEqual(@as(u32, 1), observer.count_by_level(.warn));
    try std.testing.expectEqual(@as(u32, 1), observer.count_by_level(.err));
    try std.testing.expectEqual(@as(u32, 0), observer.count_by_level(.info));

    std.debug.assert(observer.count_by_level(.debug) == 0);
    std.debug.assert(observer.count_by_level(.warn) == 1);
}

test "logger observer records context fields" {
    var observer = Observer.init(.debug);
    var logger = test_observer_logger(&observer);

    logger.info("request", &.{
        arc.string("service", "api"),
        arc.int32("version", 2),
        arc.string("method", "GET"),
    }, @src());

    try std.testing.expectEqual(@as(u32, 1), observer.len());

    const entry = observer.first().?;
    try std.testing.expectEqualStrings("request", entry.message());
    try std.testing.expect(entry.has_field("service"));
    try std.testing.expect(entry.has_field("version"));
    try std.testing.expect(entry.has_field("method"));
    try std.testing.expectEqual(@as(u32, 3), entry.fields_count);

    std.debug.assert(entry.fields_count == 3);
    std.debug.assert(entry.has_field("service"));
}

test "logger observer records logger name" {
    var observer = Observer.init(.debug);
    var logger = test_observer_logger(&observer);

    var child = logger.named("http").named("server");

    child.info("serving", &.{}, @src());

    try std.testing.expectEqual(@as(u32, 1), observer.len());

    const entry = observer.first().?;
    try std.testing.expectEqualStrings("http.server", entry.logger_name());

    std.debug.assert(entry.logger_name().len == "http.server".len);
}

test "logger observer filter by message" {
    var observer = Observer.init(.debug);
    var logger = test_observer_logger(&observer);

    logger.info("alpha", &.{}, @src());
    logger.info("beta", &.{}, @src());
    logger.info("alpha", &.{}, @src());
    logger.warn("gamma", &.{}, @src());

    try std.testing.expectEqual(@as(u32, 4), observer.len());
    try std.testing.expectEqual(@as(u32, 2), observer.count_by_message("alpha"));
    try std.testing.expectEqual(@as(u32, 1), observer.count_by_message("beta"));
    try std.testing.expectEqual(@as(u32, 1), observer.count_by_message("gamma"));

    std.debug.assert(observer.count_by_message("alpha") == 2);
    std.debug.assert(observer.count_by_message("nonexistent") == 0);
}

test "logger observer filter by level" {
    var observer = Observer.init(.debug);
    var logger = test_observer_logger(&observer);

    logger.debug("d1", &.{}, @src());
    logger.debug("d2", &.{}, @src());
    logger.info("i1", &.{}, @src());
    logger.warn("w1", &.{}, @src());
    logger.@"error"("e1", &.{}, @src());

    try std.testing.expectEqual(@as(u32, 5), observer.len());
    try std.testing.expectEqual(@as(u32, 2), observer.count_by_level(.debug));
    try std.testing.expectEqual(@as(u32, 1), observer.count_by_level(.info));
    try std.testing.expectEqual(@as(u32, 1), observer.count_by_level(.warn));
    try std.testing.expectEqual(@as(u32, 1), observer.count_by_level(.err));

    std.debug.assert(observer.count_by_level(.debug) == 2);
    std.debug.assert(observer.count_by_level(.fatal) == 0);
}

test "logger observer reset clears entries" {
    var observer = Observer.init(.debug);
    var logger = test_observer_logger(&observer);

    logger.info("one", &.{}, @src());
    logger.info("two", &.{}, @src());

    try std.testing.expectEqual(@as(u32, 2), observer.len());

    observer.reset();

    try std.testing.expectEqual(@as(u32, 0), observer.len());
    try std.testing.expect(observer.is_empty());
    try std.testing.expect(observer.first() == null);
    try std.testing.expect(observer.last() == null);

    std.debug.assert(observer.is_empty());
}

test "logger observer records timestamp" {
    var observer = Observer.init(.debug);
    var logger = test_observer_logger(&observer);

    logger.info("timed", &.{}, @src());

    const entry = observer.first().?;
    try std.testing.expectEqual(@as(i64, 1_700_000_000), entry.timestamp_s);

    std.debug.assert(entry.timestamp_s == 1_700_000_000);
}

test "logger named does not mutate parent" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    const child = logger.named("child");

    try std.testing.expectEqualStrings("", logger.name());
    try std.testing.expectEqualStrings("child", child.name());

    std.debug.assert(logger.name().len == 0);
    std.debug.assert(logger.scopes_count == 0);
}

test "logger with does not mutate parent" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    const child = logger.with(&.{
        arc.string("k", "v"),
    });

    try std.testing.expectEqual(@as(u32, 0), logger.context_fields_count);
    try std.testing.expectEqual(@as(u32, 1), child.context_fields_count);

    std.debug.assert(logger.context_fields_count == 0);
}

test "logger with siblings do not share context" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    var child_a = logger.with(&.{
        arc.string("branch", "a"),
    });

    var child_b = logger.with(&.{
        arc.string("branch", "b"),
    });

    child_a.info("from-a", &.{}, @src());
    try std.testing.expect(output.contains("branch"));
    try std.testing.expect(output.contains("\"a\""));
    try std.testing.expect(!output.contains("\"b\""));

    output.reset();

    child_b.info("from-b", &.{}, @src());
    try std.testing.expect(output.contains("branch"));
    try std.testing.expect(output.contains("\"b\""));
    try std.testing.expect(!output.contains("\"a\""));

    std.debug.assert(child_a.context_fields_count == 1);
    std.debug.assert(child_b.context_fields_count == 1);
}

test "logger naming chains build dotted name" {
    var logger = Logger.init_nop();

    var child = logger.named("a").named("b").named("c");

    try std.testing.expectEqualStrings("a.b.c", child.name());

    std.debug.assert(child.name_length == 5);
    std.debug.assert(child.scopes_count == 3);
}

test "logger check_entry returns null when disabled" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    logger.set_level(.err);

    const result = logger.check_entry(.info, "hidden", @src());
    try std.testing.expect(result == null);
    try std.testing.expect(output.is_empty());

    std.debug.assert(result == null);
}

test "logger check_entry returns entry when enabled" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    const result = logger.check_entry(.info, "visible", @src());
    try std.testing.expect(result != null);

    std.debug.assert(result != null);
}

test "logger dpanic does not panic in production mode" {
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
            .with_stacktrace_level(.fatal)
            .with_dpanic_hook(.write_then_nop),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    logger.dpanic("production dpanic", &.{}, @src());

    try std.testing.expect(output.contains("production dpanic"));
    try std.testing.expect(output.contains("dpanic"));

    std.debug.assert(output.contains("production dpanic"));
    std.debug.assert(!output.is_empty());
}

test "logger sync does not error on buffer writer" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    logger.info("before sync", &.{}, @src());

    try logger.sync();

    try std.testing.expect(output.contains("before sync"));

    std.debug.assert(!output.is_empty());
}

test "logger init_production has correct defaults" {
    const logger = Logger.init_production(std.testing.io);

    try std.testing.expect(logger.check(.info));
    try std.testing.expect(logger.check(.warn));
    try std.testing.expect(logger.check(.err));
    try std.testing.expect(!logger.check(.debug));
    try std.testing.expect(logger.add_caller);
    try std.testing.expectEqual(@as(u32, 0), logger.context_fields_count);
    try std.testing.expectEqual(@as(u32, 0), logger.name_length);

    std.debug.assert(logger.add_caller);
    std.debug.assert(logger.context_fields_count == 0);
}

test "logger init_development has correct defaults" {
    const logger = Logger.init_development(std.testing.io);

    try std.testing.expect(logger.check(.debug));
    try std.testing.expect(logger.check(.info));
    try std.testing.expect(logger.development);
    try std.testing.expect(logger.add_caller);
    try std.testing.expectEqual(@as(u32, 0), logger.context_fields_count);
    try std.testing.expectEqual(@as(u32, 0), logger.name_length);

    std.debug.assert(logger.development);
    std.debug.assert(logger.check(.debug));
}

test "logger current_level returns configured level" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    const initial = logger.current_level();
    try std.testing.expect(initial != null);
    try std.testing.expectEqual(Level.debug, initial.?);

    logger.set_level(.warn);

    const updated = logger.current_level();
    try std.testing.expect(updated != null);
    try std.testing.expectEqual(Level.warn, updated.?);

    std.debug.assert(updated.? == .warn);
}

test "logger nop current_level returns fatal" {
    const logger = Logger.init_nop();

    const lvl = logger.current_level();
    try std.testing.expect(lvl != null);
    try std.testing.expectEqual(Level.fatal, lvl.?);

    std.debug.assert(lvl.? == .fatal);
}

test "logger empty fields slice produces no field output" {
    var observer = Observer.init(.debug);
    var logger = test_observer_logger(&observer);

    logger.info("no-fields", &.{}, @src());

    try std.testing.expectEqual(@as(u32, 1), observer.len());

    const entry = observer.first().?;
    try std.testing.expectEqual(@as(u32, 0), entry.fields_count);
    try std.testing.expectEqualStrings("no-fields", entry.message());

    std.debug.assert(entry.fields_count == 0);
}

test "logger sugar returns sugared logger" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    const sugared = logger.sugar();

    try std.testing.expect(sugared.logger == &logger);

    std.debug.assert(sugared.logger == &logger);
}

test "logger multiple context accumulation" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    var child = logger
        .with(&.{arc.string("a", "1")})
        .with(&.{arc.string("b", "2")});

    child.info("multi-ctx", &.{}, @src());

    try std.testing.expect(output.contains("multi-ctx"));
    try std.testing.expect(output.contains("\"a\""));
    try std.testing.expect(output.contains("\"1\""));
    try std.testing.expect(output.contains("\"b\""));
    try std.testing.expect(output.contains("\"2\""));

    std.debug.assert(child.context_fields_count == 2);
    std.debug.assert(!output.is_empty());
}

test "logger named plus with combined" {
    var output = Buffer.init();
    var logger = test_logger(&output);

    var child = logger
        .named("db")
        .with(&.{arc.string("engine", "postgres")});

    child.info("query", &.{
        arc.int32("rows", 42),
    }, @src());

    try std.testing.expect(output.contains("db"));
    try std.testing.expect(output.contains("engine"));
    try std.testing.expect(output.contains("postgres"));
    try std.testing.expect(output.contains("rows"));
    try std.testing.expect(output.contains("42"));
    try std.testing.expect(output.contains("query"));

    std.debug.assert(child.name().len == 2);
    std.debug.assert(child.context_fields_count == 1);
}

test "logger observer field_by_key returns null for missing key" {
    var observer = Observer.init(.debug);
    var logger = test_observer_logger(&observer);

    logger.info("sparse", &.{
        arc.string("present", "yes"),
    }, @src());

    const entry = observer.first().?;
    try std.testing.expect(entry.field_by_key("present") != null);
    try std.testing.expect(entry.field_by_key("absent") == null);

    std.debug.assert(entry.field_by_key("absent") == null);
}

test "logger observer all returns full slice" {
    var observer = Observer.init(.debug);
    var logger = test_observer_logger(&observer);

    logger.info("one", &.{}, @src());
    logger.info("two", &.{}, @src());
    logger.info("three", &.{}, @src());

    const entries = observer.all();
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("one", entries[0].message());
    try std.testing.expectEqualStrings("two", entries[1].message());
    try std.testing.expectEqualStrings("three", entries[2].message());

    std.debug.assert(entries.len == 3);
}

test "logger observer empty returns defaults" {
    var observer = Observer.init(.debug);

    try std.testing.expect(observer.is_empty());
    try std.testing.expectEqual(@as(u32, 0), observer.len());
    try std.testing.expect(observer.first() == null);
    try std.testing.expect(observer.last() == null);
    try std.testing.expectEqual(@as(usize, 0), observer.all().len);

    std.debug.assert(observer.is_empty());
}
