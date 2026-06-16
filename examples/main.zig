const std = @import("std");
const arc = @import("arc");

pub fn main() void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();

    const io = threaded.io();

    var logger = arc.Logger.init_production(io);
    defer logger.sync() catch {};

    logger.info("server starting", &.{
        arc.string("version", "0.0.1"),
        arc.int("port", 8080),
        arc.boolean("tls", true),
    }, @src());

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

    if (logger.check(.info)) {
        var ce = logger.check_entry(.info, "checked entry", @src()) orelse return;

        ce.write(&.{
            arc.string("reason", "pre-checked level"),
        });
    }

    var sugared = logger.sugar();
    const msg = sugared.format_message("server listening on port {d}", .{8080});

    logger.info(msg, &.{}, @src());

    logger.info("config loaded", &.{
        arc.string("file", "config.toml"),
        arc.boolean("valid", true),
    }, @src());

    logger.info("runtime level change: disabling info", &.{}, @src());
    logger.set_level(.err);
    logger.info("this should not appear", &.{}, @src());
    logger.@"error"("this should appear", &.{}, @src());
    logger.set_level(.info);
    logger.info("info re-enabled", &.{}, @src());

    var dev_logger = arc.Logger.init_development(io);
    defer dev_logger.sync() catch {};

    dev_logger.info("development console output", &.{
        arc.string("encoding", "console"),
        arc.uint8("workers", 4),
    }, @src());

    var custom = arc.Logger.init_with_config(
        io,
        arc.Config.production()
            .with_level(.debug)
            .without_sampling()
            .with_stacktrace_level(.fatal)
            .with_thread_safety(false),
    );

    defer custom.sync() catch {};

    custom.debug("custom config logger", &.{
        arc.string("note", "no sampling, no thread safety"),
    }, @src());
}
