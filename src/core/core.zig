const std = @import("std");
const buffer_mod = @import("../io/buffer.zig");
const encoder_mod = @import("../encoding/encoder.zig");
const encoder_config_mod = @import("../encoding/config.zig");
const entry_mod = @import("entry.zig");
const field_mod = @import("field.zig");
const json_encoder_mod = @import("../encoding/json.zig");
const level_mod = @import("level.zig");
const observer_mod = @import("../observer.zig");
const writer_mod = @import("../io/writer.zig");

const Buffer = buffer_mod.Buffer;
const Encoder = encoder_mod.Encoder;
const Encoding = encoder_mod.Encoding;
const EncoderConfig = encoder_config_mod.EncoderConfig;
const Entry = entry_mod.Entry;
const Field = field_mod.Field;
const Level = level_mod.Level;
const AtomicLevel = level_mod.AtomicLevel;
const Observer = observer_mod.Observer;
const Writer = writer_mod.Writer;
const WriteError = writer_mod.WriteError;

pub const cores_tee_max: u32 = 4;

pub const Core = union(enum) {
    io: IoCore,
    nop: void,
    tee: TeeCore,
    observer: *Observer,
    increase: *IncreaseLevelCore,

    pub fn enabled(self: *const Core, at_level: Level) bool {
        return switch (self.*) {
            .io => |*io_core| io_core.level.enabled(at_level),
            .nop => false,
            .tee => |*tee_core| tee_core.enabled(at_level),
            .observer => |observer| observer.enabled(at_level),
            .increase => |increase_core| increase_core.enabled(at_level),
        };
    }

    pub fn write(
        self: *Core,
        io: std.Io,
        entry: *const Entry,
        context_fields: []const Field,
        call_fields: []const Field,
    ) WriteError!void {
        std.debug.assert(context_fields.len <= field_mod.fields_max);
        std.debug.assert(call_fields.len <= field_mod.fields_max);

        switch (self.*) {
            .io => |*io_core| try io_core.write(io, entry, context_fields, call_fields),
            .nop => {},
            .tee => |*tee_core| try tee_core.write(io, entry, context_fields, call_fields),
            .observer => |observer| observer.record(entry, context_fields, call_fields),
            .increase => |increase_core| try increase_core.write(
                io,
                entry,
                context_fields,
                call_fields,
            ),
        }
    }

    pub fn sync(self: *Core, io: std.Io) WriteError!void {
        switch (self.*) {
            .io => |*io_core| try io_core.sync(io),
            .nop => {},
            .tee => |*tee_core| try tee_core.sync(io),
            .observer => {},
            .increase => |increase_core| try increase_core.sync(io),
        }
    }

    pub fn atomic_level(self: *Core) ?*AtomicLevel {
        return switch (self.*) {
            .io => |*io_core| &io_core.level,
            .nop => null,
            .tee => null,
            .observer => null,
            .increase => null,
        };
    }

    pub fn single_io_core(self: *Core) ?*IoCore {
        return switch (self.*) {
            .io => |*io_core| io_core,
            .nop, .tee, .observer, .increase => null,
        };
    }

    pub fn current_level(self: *const Core) ?Level {
        return switch (self.*) {
            .io => |*io_core| io_core.level.level(),
            .nop => null,
            .tee => null,
            .observer => |observer| observer.minimum_level,
            .increase => |increase_core| increase_core.level(),
        };
    }

    pub fn set_drop_counter(self: *Core, counter: *std.atomic.Value(u64)) void {
        switch (self.*) {
            .io => |*io_core| io_core.drop_counter = counter,
            .tee => |*tee_core| {
                const active = tee_core.cores[0..tee_core.cores_count];

                for (active) |*io_core| {
                    io_core.drop_counter = counter;
                }
            },
            .nop, .observer, .increase => {},
        }
    }

    pub fn minimum_level(self: *const Core) Level {
        return switch (self.*) {
            .io => |*io_core| io_core.level.level(),
            .nop => Level.fatal,
            .tee => |*tee_core| blk: {
                std.debug.assert(tee_core.cores_count > 0);

                var minimum = Level.fatal;
                const active = tee_core.cores[0..tee_core.cores_count];

                for (active) |*io_core| {
                    const io_level = io_core.level.level();
                    if (@intFromEnum(io_level) < @intFromEnum(minimum)) {
                        minimum = io_level;
                    }
                }

                break :blk minimum;
            },
            .observer => |observer| observer.minimum_level,
            .increase => |increase_core| increase_core.level(),
        };
    }
};

pub const IoCore = struct {
    level: AtomicLevel,
    encoder: Encoder,
    writer: Writer,
    mutex: std.Io.Mutex,
    thread_safe: bool,
    drop_counter: ?*std.atomic.Value(u64),

    pub fn init(
        at_level: Level,
        encoding: Encoding,
        config: EncoderConfig,
        writer: Writer,
        thread_safe: bool,
    ) IoCore {
        return IoCore{
            .level = AtomicLevel.init(at_level),
            .encoder = Encoder.init(encoding, config),
            .writer = writer,
            .mutex = .init,
            .thread_safe = thread_safe,
            .drop_counter = null,
        };
    }

    pub fn write(
        self: *IoCore,
        io: std.Io,
        entry: *const Entry,
        context_fields: []const Field,
        call_fields: []const Field,
    ) WriteError!void {
        std.debug.assert(context_fields.len <= field_mod.fields_max);
        std.debug.assert(call_fields.len <= field_mod.fields_max);

        var buffer = Buffer.init();
        var state = json_encoder_mod.EncodeState.init();

        self.encoder.encode_entry(
            &state,
            &buffer,
            entry,
            context_fields,
            call_fields,
        );

        if (buffer.was_truncated()) {
            if (self.drop_counter) |counter| {
                _ = counter.fetchAdd(1, .monotonic);
            }

            self.encoder.encode_truncation_notice(&buffer, entry);
        }

        std.debug.assert(buffer.len() > 0);

        if (self.thread_safe) {
            self.mutex.lockUncancelable(io);
        }
        defer {
            if (self.thread_safe) {
                self.mutex.unlock(io);
            }
        }

        try self.writer.write(io, buffer.contents());
    }

    pub fn sync(self: *IoCore, io: std.Io) WriteError!void {
        if (self.thread_safe) {
            self.mutex.lockUncancelable(io);
        }
        defer {
            if (self.thread_safe) {
                self.mutex.unlock(io);
            }
        }

        try self.writer.sync(io);
    }

    pub fn set_level(self: *IoCore, at_level: Level) void {
        self.level.set_level(at_level);
    }
};

pub const TeeCore = struct {
    cores: [cores_tee_max]IoCore,
    cores_count: u32,

    pub fn init(targets: []const IoCore) TeeCore {
        std.debug.assert(targets.len > 0);

        if (targets.len > cores_tee_max) {
            @panic("tee core count exceeds cores_tee_max");
        }

        var tee_core: TeeCore = undefined;
        tee_core.cores_count = @intCast(targets.len);

        for (targets, 0..) |*target, index| {
            tee_core.cores[index] = target.*;
        }

        return tee_core;
    }

    pub fn enabled(self: *const TeeCore, at_level: Level) bool {
        std.debug.assert(self.cores_count > 0);

        const active = self.cores[0..self.cores_count];

        for (active) |*io_core| {
            if (io_core.level.enabled(at_level)) {
                return true;
            }
        }

        return false;
    }

    pub fn write(
        self: *TeeCore,
        io: std.Io,
        entry: *const Entry,
        context_fields: []const Field,
        call_fields: []const Field,
    ) WriteError!void {
        std.debug.assert(self.cores_count > 0);
        std.debug.assert(context_fields.len <= field_mod.fields_max);

        const active = self.cores[0..self.cores_count];

        for (active) |*io_core| {
            if (io_core.level.enabled(entry.level)) {
                try io_core.write(io, entry, context_fields, call_fields);
            }
        }
    }

    pub fn sync(self: *TeeCore, io: std.Io) WriteError!void {
        std.debug.assert(self.cores_count > 0);

        const active = self.cores[0..self.cores_count];

        for (active) |*io_core| {
            try io_core.sync(io);
        }
    }
};

pub const IncreaseLevelError = error{LevelNotIncreased};

pub const IncreaseLevelCore = struct {
    inner: *Core,
    minimum_level: Level,

    pub fn init(inner: *Core, at_level: Level) IncreaseLevelError!IncreaseLevelCore {
        const current = inner.minimum_level();

        if (@intFromEnum(at_level) < @intFromEnum(current)) {
            return error.LevelNotIncreased;
        }

        std.debug.assert(@intFromEnum(at_level) >= @intFromEnum(current));

        return .{
            .inner = inner,
            .minimum_level = at_level,
        };
    }

    pub fn enabled(self: *const IncreaseLevelCore, at_level: Level) bool {
        if (!self.minimum_level.enabled(at_level)) {
            return false;
        }

        return self.inner.enabled(at_level);
    }

    pub fn write(
        self: *IncreaseLevelCore,
        io: std.Io,
        entry: *const Entry,
        context_fields: []const Field,
        call_fields: []const Field,
    ) WriteError!void {
        std.debug.assert(self.enabled(entry.level));
        std.debug.assert(context_fields.len <= field_mod.fields_max);

        try self.inner.write(io, entry, context_fields, call_fields);
    }

    pub fn sync(self: *IncreaseLevelCore, io: std.Io) WriteError!void {
        try self.inner.sync(io);
    }

    pub fn level(self: *const IncreaseLevelCore) Level {
        return self.minimum_level;
    }
};
