const std = @import("std");
const checked_mod = @import("core/checked.zig");
const encoder_mod = @import("encoding/encoder.zig");
const encoder_config_mod = @import("encoding/config.zig");
const level_mod = @import("core/level.zig");
const sampler_mod = @import("core/sampler.zig");
const writer_mod = @import("io/writer.zig");

const Encoding = encoder_mod.Encoding;
const EncoderConfig = encoder_config_mod.EncoderConfig;
const Level = level_mod.Level;
const TerminalAction = checked_mod.TerminalAction;
const Writer = writer_mod.Writer;

pub const SamplingConfig = struct {
    enabled: bool,
    tick_ns: i64,
    initial: u64,
    thereafter: u64,
};

pub const Config = struct {
    level: Level,
    encoding: Encoding,
    encoder_config: EncoderConfig,
    writer: Writer,
    error_output: Writer,
    sampling: SamplingConfig,
    add_caller: bool,
    add_stacktrace_level: Level,
    is_development: bool,
    thread_safe: bool,
    on_dpanic: TerminalAction,
    on_fatal: TerminalAction,

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
                .initial = 100,
                .thereafter = 100,
            },
            .add_caller = true,
            .add_stacktrace_level = .err,
            .is_development = false,
            .thread_safe = true,
            .on_dpanic = .write_then_nop,
            .on_fatal = .write_then_fatal,
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
                .initial = 100,
                .thereafter = 100,
            },
            .add_caller = true,
            .add_stacktrace_level = .warn,
            .is_development = true,
            .thread_safe = false,
            .on_dpanic = .write_then_panic,
            .on_fatal = .write_then_fatal,
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
                .initial = 100,
                .thereafter = 100,
            },
            .add_caller = false,
            .add_stacktrace_level = .fatal,
            .is_development = false,
            .thread_safe = false,
            .on_dpanic = .write_then_nop,
            .on_fatal = .write_then_fatal,
        };
    }

    pub fn with_level(self: *const Config, at_level: Level) Config {
        var config = self.*;
        config.level = at_level;

        return config;
    }

    pub fn with_encoding(self: *const Config, encoding: Encoding) Config {
        var config = self.*;
        config.encoding = encoding;

        return config;
    }

    pub fn with_writer(self: *const Config, writer: Writer) Config {
        var config = self.*;
        config.writer = writer;

        return config;
    }

    pub fn with_error_output(self: *const Config, writer: Writer) Config {
        var config = self.*;
        config.error_output = writer;

        return config;
    }

    pub fn with_encoder_config(self: *const Config, encoder_config: EncoderConfig) Config {
        std.debug.assert(encoder_config.console_separator != 0);

        var config = self.*;
        config.encoder_config = encoder_config;

        return config;
    }

    pub fn with_sampling(self: *const Config, sampling: SamplingConfig) Config {
        if (sampling.enabled) {
            std.debug.assert(sampling.tick_ns > 0);
            std.debug.assert(sampling.initial > 0);
        }

        var config = self.*;
        config.sampling = sampling;

        return config;
    }

    pub fn without_caller(self: *const Config) Config {
        var config = self.*;
        config.add_caller = false;

        return config;
    }

    pub fn without_sampling(self: *const Config) Config {
        var config = self.*;
        config.sampling.enabled = false;

        return config;
    }

    pub fn with_stacktrace_level(self: *const Config, at_level: Level) Config {
        var config = self.*;
        config.add_stacktrace_level = at_level;

        return config;
    }

    pub fn with_thread_safety(self: *const Config, enabled: bool) Config {
        var config = self.*;
        config.thread_safe = enabled;

        return config;
    }

    pub fn with_dpanic_hook(self: *const Config, action: TerminalAction) Config {
        var config = self.*;
        config.on_dpanic = action;

        return config;
    }

    pub fn with_fatal_hook(self: *const Config, action: TerminalAction) Config {
        var config = self.*;
        config.on_fatal = action;

        return config;
    }
};
