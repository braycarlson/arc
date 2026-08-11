const std = @import("std");
const arc = @import("arc");

const Logger = arc.Logger;

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();

    const io = threaded.io();

    try run_production(io);
    try run_development(io);
    try run_custom(io);
}

fn run_production(io: std.Io) !void {
    var logger = Logger.init_production(io);

    logger.info("server starting", &.{
        arc.string("version", "0.0.1"),
        arc.int("port", 8080),
        arc.boolean("tls", true),
    }, @src());

    log_requests(&logger);
    log_checked_entry(&logger);
    log_sugared(&logger);

    logger.info("config loaded", &.{
        arc.string("file", "config.toml"),
        arc.boolean("valid", true),
    }, @src());

    log_level_changes(&logger);

    try logger.sync();
}

fn log_requests(logger: *Logger) void {
    var request_logger = logger.named("http").with(&.{
        arc.string("service", "api"),
    });

    request_logger.debug("request received", &.{
        arc.string("method", "GET"),
        arc.string("path", "/health"),
        arc.duration_ns("timeout", 5_000_000_000),
    }, @src());

    request_logger.info("request completed", &.{
        arc.int("status", 200),
        arc.uint("latency_ms", 42),
        arc.float("cpu_pct", 12.5),
    }, @src());

    request_logger.@"error"("request failed", &.{
        arc.int("status", 500),
        arc.err("connection refused"),
        arc.strings("attempted_hosts", &.{ "host-a", "host-b" }),
    }, @src());

    request_logger.warn("namespace example", &.{
        arc.namespace("request"),
        arc.string("id", "abc-123"),
        arc.int32("attempt", 3),
    }, @src());
}

fn log_checked_entry(logger: *Logger) void {
    if (!logger.check(.info)) {
        return;
    }

    var checked: arc.CheckedEntry = undefined;

    if (!logger.check_entry(&checked, .info, "checked entry", @src())) {
        return;
    }

    checked.write(&.{
        arc.string("reason", "pre-checked level"),
    });
}

fn log_sugared(logger: *Logger) void {
    var sugared = logger.sugar();
    const message = sugared.format_message("server listening on port {d}", .{8080});

    logger.info(message, &.{}, @src());
}

fn log_level_changes(logger: *Logger) void {
    logger.info("runtime level change: disabling info", &.{}, @src());
    logger.set_level(.err);
    logger.info("this should not appear", &.{}, @src());
    logger.@"error"("this should appear", &.{}, @src());
    logger.set_level(.info);
    logger.info("info re-enabled", &.{}, @src());
}

fn run_development(io: std.Io) !void {
    var logger = Logger.init_development(io);

    logger.info("development console output", &.{
        arc.string("encoding", "console"),
        arc.uint8("workers", 4),
    }, @src());

    try logger.sync();
}

fn run_custom(io: std.Io) !void {
    var logger = Logger.init_with_config(
        io,
        arc.Config.production()
            .with_level(.debug)
            .without_sampling()
            .with_stacktrace_level(.fatal)
            .with_thread_safety(false),
    );

    logger.debug("custom config logger", &.{
        arc.string("note", "no sampling, no thread safety"),
    }, @src());

    try logger.sync();
}
