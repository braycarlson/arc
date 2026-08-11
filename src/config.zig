const std = @import("std");
const checked_mod = @import("core/checked.zig");
const encoder_mod = @import("encoding/encoder.zig");
const encoder_config_mod = @import("encoding/config.zig");
const level_mod = @import("core/level.zig");
const sampler_mod = @import("core/sampler.zig");
const writer_mod = @import("io/writer.zig");

const assert = std.debug.assert;

const Encoding = encoder_mod.Encoding;
const EncoderConfig = encoder_config_mod.EncoderConfig;
const Level = level_mod.Level;
const TerminalAction = checked_mod.TerminalAction;
const Writer = writer_mod.Writer;

pub const SamplingConfig = sampler_mod.SamplingConfig;

pub const Config = struct {
    level: Level,
    encoding: Encoding,
    encoder_config: EncoderConfig,
    writer: Writer,
    error_output: Writer,
    sampling: SamplingConfig,
    caller_enabled: bool,
    stacktrace_level_min: Level,
    is_development: bool,
    thread_safe: bool,
    dpanic_action: TerminalAction,
    fatal_action: TerminalAction,

    pub fn production() Config {
        return .{
            .level = .info,
            .encoding = .json,
            .encoder_config = EncoderConfig.production(),
            .writer = .{ .stderr = {} },
            .error_output = .{ .stderr = {} },
            .sampling = .{
                .enabled = true,
                .tick_ns = sampler_mod.tick_ns_default,
                .first = 100,
                .thereafter = 100,
            },
            .caller_enabled = true,
            .stacktrace_level_min = .err,
            .is_development = false,
            .thread_safe = true,
            .dpanic_action = .write_then_nop,
            .fatal_action = .write_then_fatal,
        };
    }

    pub fn development() Config {
        return .{
            .level = .debug,
            .encoding = .console,
            .encoder_config = EncoderConfig.development(),
            .writer = .{ .stderr = {} },
            .error_output = .{ .stderr = {} },
            .sampling = .{
                .enabled = false,
                .tick_ns = sampler_mod.tick_ns_default,
                .first = 100,
                .thereafter = 100,
            },
            .caller_enabled = true,
            .stacktrace_level_min = .warn,
            .is_development = true,
            .thread_safe = false,
            .dpanic_action = .write_then_panic,
            .fatal_action = .write_then_fatal,
        };
    }

    pub fn nop() Config {
        return .{
            .level = .fatal,
            .encoding = .json,
            .encoder_config = EncoderConfig.production(),
            .writer = .{ .nop = {} },
            .error_output = .{ .nop = {} },
            .sampling = .{
                .enabled = false,
                .tick_ns = sampler_mod.tick_ns_default,
                .first = 100,
                .thereafter = 100,
            },
            .caller_enabled = false,
            .stacktrace_level_min = .fatal,
            .is_development = false,
            .thread_safe = false,
            .dpanic_action = .write_then_nop,
            .fatal_action = .write_then_fatal,
        };
    }

    pub fn is_valid(self: *const Config) bool {
        if (self.sampling.enabled and self.sampling.tick_ns <= 0) return false;
        if (self.sampling.enabled and self.sampling.first == 0) return false;

        return true;
    }

    pub fn with_level(self: *const Config, at_level: Level) Config {
        assert(self.is_valid());

        var config = self.*;
        config.level = at_level;

        return config;
    }

    pub fn with_encoding(self: *const Config, encoding: Encoding) Config {
        assert(self.is_valid());

        var config = self.*;
        config.encoding = encoding;

        return config;
    }

    pub fn with_writer(self: *const Config, writer: Writer) Config {
        assert(self.is_valid());

        var config = self.*;
        config.writer = writer;

        return config;
    }

    pub fn with_error_output(self: *const Config, writer: Writer) Config {
        assert(self.is_valid());

        var config = self.*;
        config.error_output = writer;

        return config;
    }

    pub fn with_encoder_config(self: *const Config, encoder_config: EncoderConfig) Config {
        assert(self.is_valid());

        assert(encoder_config.console_separator != 0);

        var config = self.*;
        config.encoder_config = encoder_config;

        return config;
    }

    pub fn with_sampling(self: *const Config, sampling: SamplingConfig) Config {
        if (sampling.enabled) {
            assert(sampling.tick_ns > 0);
            assert(sampling.first > 0);
        }

        var config = self.*;
        config.sampling = sampling;

        assert(config.is_valid());

        return config;
    }

    pub fn without_caller(self: *const Config) Config {
        assert(self.is_valid());

        var config = self.*;
        config.caller_enabled = false;

        return config;
    }

    pub fn without_sampling(self: *const Config) Config {
        assert(self.is_valid());

        var config = self.*;
        config.sampling.enabled = false;

        return config;
    }

    pub fn with_stacktrace_level(self: *const Config, at_level: Level) Config {
        assert(self.is_valid());

        var config = self.*;
        config.stacktrace_level_min = at_level;

        return config;
    }

    pub fn with_thread_safety(self: *const Config, enabled: bool) Config {
        assert(self.is_valid());

        var config = self.*;
        config.thread_safe = enabled;

        return config;
    }

    pub fn with_dpanic_hook(self: *const Config, action: TerminalAction) Config {
        assert(self.is_valid());

        var config = self.*;
        config.dpanic_action = action;

        return config;
    }

    pub fn with_fatal_hook(self: *const Config, action: TerminalAction) Config {
        assert(self.is_valid());

        var config = self.*;
        config.fatal_action = action;

        return config;
    }
};

const testing = std.testing;

test "a production config carries the production defaults" {
    const cfg = Config.production();

    try testing.expectEqual(Level.info, cfg.level);
    try testing.expect(cfg.caller_enabled);
    try testing.expect(cfg.sampling.enabled);
    try testing.expect(cfg.thread_safe);
    try testing.expect(!cfg.is_development);

    assert(cfg.sampling.tick_ns > 0);
    assert(cfg.sampling.first > 0);
}

test "a development config carries the development defaults" {
    const cfg = Config.development();

    try testing.expectEqual(Level.debug, cfg.level);
    try testing.expect(cfg.caller_enabled);
    try testing.expect(!cfg.sampling.enabled);
    try testing.expect(!cfg.thread_safe);
    try testing.expect(cfg.is_development);

    assert(@intFromEnum(cfg.level) == 0);
    assert(cfg.is_development);
}

test "a nop config disables every output" {
    const cfg = Config.nop();

    try testing.expectEqual(Level.fatal, cfg.level);
    try testing.expect(!cfg.caller_enabled);
    try testing.expect(!cfg.sampling.enabled);
    try testing.expect(!cfg.thread_safe);
    try testing.expect(!cfg.is_development);

    assert(@intFromEnum(cfg.level) == @intFromEnum(Level.fatal));
    assert(!cfg.caller_enabled);
}

test "setting a level overrides the one the config carried" {
    const cfg = Config.production().with_level(.debug);

    try testing.expectEqual(Level.debug, cfg.level);
    try testing.expect(cfg.caller_enabled);

    assert(@intFromEnum(cfg.level) == 0);
    assert(cfg.thread_safe);
}

test "dropping sampling clears the sampling settings" {
    const cfg = Config.production().without_sampling();

    try testing.expect(!cfg.sampling.enabled);
    try testing.expectEqual(Level.info, cfg.level);

    assert(!cfg.sampling.enabled);
    assert(cfg.caller_enabled);
}

test "dropping the caller clears caller reporting" {
    const cfg = Config.production().without_caller();

    try testing.expect(!cfg.caller_enabled);
    try testing.expectEqual(Level.info, cfg.level);

    assert(!cfg.caller_enabled);
    assert(cfg.thread_safe);
}

test "setting thread safety toggles the locking the config asks for" {
    const cfg = Config.production().with_thread_safety(false);

    try testing.expect(!cfg.thread_safe);
    try testing.expectEqual(Level.info, cfg.level);

    assert(!cfg.thread_safe);
    assert(cfg.caller_enabled);
}

test "setting a stacktrace level overrides the threshold the config carried" {
    const cfg = Config.production().with_stacktrace_level(.fatal);

    try testing.expectEqual(Level.fatal, cfg.stacktrace_level_min);

    assert(@intFromEnum(cfg.stacktrace_level_min) == @intFromEnum(Level.fatal));
    assert(cfg.caller_enabled);
}

test "chained builder calls each keep the previous change" {
    const cfg = Config.production()
        .with_level(.debug)
        .without_sampling()
        .with_thread_safety(false)
        .with_stacktrace_level(.fatal);

    try testing.expectEqual(Level.debug, cfg.level);
    try testing.expect(!cfg.sampling.enabled);
    try testing.expect(!cfg.thread_safe);
    try testing.expectEqual(Level.fatal, cfg.stacktrace_level_min);

    assert(@intFromEnum(cfg.level) == 0);
    assert(!cfg.sampling.enabled);
}
