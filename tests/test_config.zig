const std = @import("std");
const arc = @import("arc");

const Config = arc.Config;
const Level = arc.Level;

test "production config defaults" {
    const cfg = Config.production();

    try std.testing.expectEqual(Level.info, cfg.level);
    try std.testing.expect(cfg.add_caller);
    try std.testing.expect(cfg.sampling.enabled);
    try std.testing.expect(cfg.thread_safe);
    try std.testing.expect(!cfg.is_development);

    std.debug.assert(cfg.sampling.tick_ns > 0);
    std.debug.assert(cfg.sampling.initial > 0);
}

test "development config defaults" {
    const cfg = Config.development();

    try std.testing.expectEqual(Level.debug, cfg.level);
    try std.testing.expect(cfg.add_caller);
    try std.testing.expect(!cfg.sampling.enabled);
    try std.testing.expect(!cfg.thread_safe);
    try std.testing.expect(cfg.is_development);

    std.debug.assert(@intFromEnum(cfg.level) == 0);
    std.debug.assert(cfg.is_development);
}

test "nop config disables everything" {
    const cfg = Config.nop();

    try std.testing.expectEqual(Level.fatal, cfg.level);
    try std.testing.expect(!cfg.add_caller);
    try std.testing.expect(!cfg.sampling.enabled);
    try std.testing.expect(!cfg.thread_safe);
    try std.testing.expect(!cfg.is_development);

    std.debug.assert(@intFromEnum(cfg.level) == @intFromEnum(Level.fatal));
    std.debug.assert(!cfg.add_caller);
}

test "with_level overrides level" {
    const cfg = Config.production().with_level(.debug);

    try std.testing.expectEqual(Level.debug, cfg.level);
    try std.testing.expect(cfg.add_caller);

    std.debug.assert(@intFromEnum(cfg.level) == 0);
    std.debug.assert(cfg.thread_safe);
}

test "without_sampling disables sampling" {
    const cfg = Config.production().without_sampling();

    try std.testing.expect(!cfg.sampling.enabled);
    try std.testing.expectEqual(Level.info, cfg.level);

    std.debug.assert(!cfg.sampling.enabled);
    std.debug.assert(cfg.add_caller);
}

test "without_caller disables caller" {
    const cfg = Config.production().without_caller();

    try std.testing.expect(!cfg.add_caller);
    try std.testing.expectEqual(Level.info, cfg.level);

    std.debug.assert(!cfg.add_caller);
    std.debug.assert(cfg.thread_safe);
}

test "with_thread_safety toggles thread safety" {
    const cfg = Config.production().with_thread_safety(false);

    try std.testing.expect(!cfg.thread_safe);
    try std.testing.expectEqual(Level.info, cfg.level);

    std.debug.assert(!cfg.thread_safe);
    std.debug.assert(cfg.add_caller);
}

test "with_stacktrace_level overrides stacktrace threshold" {
    const cfg = Config.production().with_stacktrace_level(.fatal);

    try std.testing.expectEqual(Level.fatal, cfg.add_stacktrace_level);

    std.debug.assert(@intFromEnum(cfg.add_stacktrace_level) == @intFromEnum(Level.fatal));
    std.debug.assert(cfg.add_caller);
}

test "chained config modifications" {
    const cfg = Config.production()
        .with_level(.debug)
        .without_sampling()
        .with_thread_safety(false)
        .with_stacktrace_level(.fatal);

    try std.testing.expectEqual(Level.debug, cfg.level);
    try std.testing.expect(!cfg.sampling.enabled);
    try std.testing.expect(!cfg.thread_safe);
    try std.testing.expectEqual(Level.fatal, cfg.add_stacktrace_level);

    std.debug.assert(@intFromEnum(cfg.level) == 0);
    std.debug.assert(!cfg.sampling.enabled);
}
