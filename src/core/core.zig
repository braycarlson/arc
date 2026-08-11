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
const clock_mod = @import("clock.zig");
const config_mod = @import("../config.zig");
const logger_mod = @import("../logger.zig");

const assert = std.debug.assert;

const Buffer = buffer_mod.Buffer;
const Encoder = encoder_mod.Encoder;
const Encoding = encoder_mod.Encoding;
const EncoderConfig = encoder_config_mod.EncoderConfig;
const Entry = entry_mod.Entry;
const EntryFields = field_mod.EntryFields;
const Level = level_mod.Level;
const AtomicLevel = level_mod.AtomicLevel;
const Observer = observer_mod.Observer;
const Writer = writer_mod.Writer;
const WriteError = writer_mod.WriteError;

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
        fields: EntryFields,
    ) WriteError!void {
        assert(fields.is_valid());

        switch (self.*) {
            .io => |*io_core| try io_core.write(io, entry, fields),
            .nop => {},
            .tee => |*tee_core| try tee_core.write(io, entry, fields),
            .observer => |observer| observer.record(entry, fields),
            .increase => |increase_core| try increase_core.write(io, entry, fields),
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
                assert(tee_core.cores_count > 0);

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
        fields: EntryFields,
    ) WriteError!void {
        assert(fields.is_valid());

        var buffer = Buffer.init();
        var state = json_encoder_mod.EncodeState.init();

        self.encoder.encode_entry(&state, &buffer, entry, fields);

        if (buffer.was_truncated()) {
            if (self.drop_counter) |counter| {
                _ = counter.fetchAdd(1, .monotonic);
            }

            self.encoder.encode_truncation_notice(&buffer, entry);
        }

        assert(buffer.length() > 0);

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
    cores: [tee_cores_max]IoCore,
    cores_count: u32,

    pub fn init(targets: []const IoCore) TeeCore {
        assert(targets.len > 0);

        if (targets.len > tee_cores_max) {
            @panic("tee core count exceeds tee_cores_max");
        }

        var tee_core: TeeCore = undefined;
        tee_core.cores_count = @intCast(targets.len);

        for (targets, 0..) |*target, index| {
            tee_core.cores[index] = target.*;
        }

        return tee_core;
    }

    pub fn enabled(self: *const TeeCore, at_level: Level) bool {
        assert(self.cores_count > 0);

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
        fields: EntryFields,
    ) WriteError!void {
        assert(self.cores_count > 0);
        assert(fields.is_valid());

        const active = self.cores[0..self.cores_count];

        for (active) |*io_core| {
            if (io_core.level.enabled(entry.level)) {
                try io_core.write(io, entry, fields);
            }
        }
    }

    pub fn sync(self: *TeeCore, io: std.Io) WriteError!void {
        assert(self.cores_count > 0);

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

        assert(@intFromEnum(at_level) >= @intFromEnum(current));

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
        fields: EntryFields,
    ) WriteError!void {
        assert(self.enabled(entry.level));
        assert(fields.is_valid());

        try self.inner.write(io, entry, fields);
    }

    pub fn sync(self: *IncreaseLevelCore, io: std.Io) WriteError!void {
        try self.inner.sync(io);
    }

    pub fn level(self: *const IncreaseLevelCore) Level {
        return self.minimum_level;
    }
};

pub const tee_cores_max: u32 = 4;

comptime {
    assert(tee_cores_max > 0);
}

const testing = std.testing;

const temporary = @import("../testing/temporary.zig");

fn make_io_core(output: *Buffer, at_level: Level) IoCore {
    return IoCore.init(
        at_level,
        Encoding.json,
        EncoderConfig.production(),
        .{ .buffer = output },
        false,
    );
}

test "a nop core is disabled at every level" {
    var core = Core{ .nop = {} };

    try testing.expect(!core.enabled(.debug));
    try testing.expect(!core.enabled(.info));
    try testing.expectEqual(@as(?Level, null), core.current_level());
    try testing.expectEqual(@as(?*level_mod.AtomicLevel, null), core.atomic_level());
    try testing.expectEqual(Level.fatal, core.minimum_level());

    const ignored = Entry.init(testing.io, .info, "ignored", "test");

    try core.write(testing.io, &ignored, .{ .context = &.{}, .message = &.{} });
    try core.sync(testing.io);
}

test "an io core enables only levels at or above its threshold" {
    var output = Buffer.init();
    var core = Core{ .io = make_io_core(&output, .warn) };

    try testing.expect(!core.enabled(.debug));
    try testing.expect(!core.enabled(.info));
    try testing.expect(core.enabled(.warn));
    try testing.expect(core.enabled(.err));

    try testing.expectEqual(Level.warn, core.current_level().?);
    try testing.expectEqual(Level.warn, core.minimum_level());

    assert(core.current_level().? == .warn);
    assert(core.minimum_level() == .warn);
}

test "an io core writes the encoded entry to its buffer" {
    var output = Buffer.init();
    var core = Core{ .io = make_io_core(&output, .debug) };

    var entry = Entry.init(testing.io, .info, "hello world", "app");

    try core.write(testing.io, &entry, .{ .context = &.{}, .message = &.{} });

    try testing.expect(!output.is_empty());
    try testing.expect(output.contains("hello world"));
    try testing.expect(output.contains("info"));

    assert(output.contains("hello world"));
    assert(output.contains("info"));
}

test "an io core writes the context fields alongside the entry" {
    var output = Buffer.init();
    var core = Core{ .io = make_io_core(&output, .debug) };

    var entry = Entry.init(testing.io, .info, "boot", "svc");

    try core.write(testing.io, &entry, .{
        .context = &.{
            field_mod.string("service", "auth"),
            field_mod.int("version", 2),
        },
        .message = &.{},
    });

    try testing.expect(output.contains("boot"));
    try testing.expect(output.contains("service"));
    try testing.expect(output.contains("auth"));
    try testing.expect(output.contains("version"));

    assert(output.contains("auth"));
}

test "a tee core writes to every child it holds" {
    var output_a = Buffer.init();
    var output_b = Buffer.init();

    const cores = [_]IoCore{
        make_io_core(&output_a, .debug),
        make_io_core(&output_b, .debug),
    };

    var core = Core{ .tee = TeeCore.init(&cores) };

    var entry = Entry.init(testing.io, .info, "fanout", "tee");

    try core.write(testing.io, &entry, .{ .context = &.{}, .message = &.{} });

    try testing.expect(output_a.contains("fanout"));
    try testing.expect(output_b.contains("fanout"));

    assert(output_a.contains("fanout"));
    assert(output_b.contains("fanout"));
}

test "a tee core lets each child apply its own level" {
    var output_info = Buffer.init();
    var output_err = Buffer.init();

    const cores = [_]IoCore{
        make_io_core(&output_info, .info),
        make_io_core(&output_err, .err),
    };

    var core = Core{ .tee = TeeCore.init(&cores) };

    var info_entry = Entry.init(testing.io, .info, "info only", "tee");

    try core.write(testing.io, &info_entry, .{ .context = &.{}, .message = &.{} });

    try testing.expect(output_info.contains("info only"));
    try testing.expect(!output_err.contains("info only"));

    var err_entry = Entry.init(testing.io, .err, "error both", "tee");

    try core.write(testing.io, &err_entry, .{ .context = &.{}, .message = &.{} });

    try testing.expect(output_info.contains("error both"));
    try testing.expect(output_err.contains("error both"));

    try testing.expectEqual(Level.info, core.minimum_level());
}

test "an increase level core refuses a minimum below the core it wraps" {
    var output = Buffer.init();
    var inner = Core{ .io = make_io_core(&output, .warn) };

    try testing.expectError(
        error.LevelNotIncreased,
        IncreaseLevelCore.init(&inner, .info),
    );
}

test "an increase level core raises the level that reaches the wrapped core" {
    var output = Buffer.init();
    var inner = Core{ .io = make_io_core(&output, .debug) };

    var raised = try IncreaseLevelCore.init(&inner, .err);

    try testing.expect(!raised.enabled(.debug));
    try testing.expect(!raised.enabled(.info));
    try testing.expect(!raised.enabled(.warn));
    try testing.expect(raised.enabled(.err));
    try testing.expect(raised.enabled(.fatal));
    try testing.expectEqual(Level.err, raised.level());

    var err_entry = Entry.init(testing.io, .err, "visible", "raised");

    try raised.write(testing.io, &err_entry, .{ .context = &.{}, .message = &.{} });

    try testing.expect(output.contains("visible"));
    try testing.expect(!output.contains("hidden"));

    assert(output.contains("visible"));
}

test "an increase level core forwards a sync to the core it wraps" {
    var output = Buffer.init();
    var inner = Core{ .io = make_io_core(&output, .debug) };
    var raised = try IncreaseLevelCore.init(&inner, .fatal);

    try raised.sync(testing.io);

    var entry = Entry.init(testing.io, .fatal, "synced", "raised");

    try raised.write(testing.io, &entry, .{ .context = &.{}, .message = &.{} });

    try testing.expect(output.contains("synced"));
}

test "a core exposes the atomic level of the io core inside it" {
    var output = Buffer.init();
    var core = Core{ .io = make_io_core(&output, .info) };

    const atomic = core.atomic_level().?;

    try testing.expectEqual(Level.info, atomic.level());

    atomic.set_level(.err);

    try testing.expectEqual(Level.err, atomic.level());
    try testing.expectEqual(Level.err, core.current_level().?);
    try testing.expect(!core.enabled(.info));
    try testing.expect(core.enabled(.err));

    assert(core.current_level().? == .err);
}

const Clock = clock_mod.Clock;
const Config = config_mod.Config;
const Logger = logger_mod.Logger;

test "a failing write reports to the error output and logging continues" {
    const io = testing.io;
    const path = ".zz_error_path.tmp";

    // Create a file, capture its descriptor, then close it so every write through
    // that descriptor fails. No descriptor is opened between the close and the
    // failing writes, so it cannot be reused underneath us.
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    const stale_file_descriptor = file.handle;
    file.close(io);
    defer temporary.remove_file(io, path);

    var errors = Buffer.init();

    var logger = Logger.init_with_config(
        io,
        Config.production()
            .with_level(.debug)
            .without_sampling()
            .without_caller()
            .with_writer(.{ .file_descriptor = stale_file_descriptor })
            .with_error_output(.{ .buffer = &errors })
            .with_thread_safety(false)
            .with_stacktrace_level(.fatal),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    logger.info("first", &.{}, @src());

    try testing.expect(errors.contains("arc internal error"));

    const after_first = errors.length();

    logger.info("second", &.{}, @src());

    try testing.expect(errors.length() > after_first);

    assert(errors.length() > after_first);
}
