const std = @import("std");
const arc = @import("arc");

const Buffer = arc.buffer_mod.Buffer;
const Core = arc.core_mod.Core;
const IoCore = arc.core_mod.IoCore;
const TeeCore = arc.core_mod.TeeCore;
const IncreaseLevelCore = arc.core_mod.IncreaseLevelCore;
const Entry = arc.entry_mod.Entry;
const Field = arc.Field;
const Level = arc.Level;
const Encoding = arc.encoder_mod.Encoding;
const EncoderConfig = arc.EncoderConfig;

fn make_io_core(output: *Buffer, at_level: Level) IoCore {
    return IoCore.init(
        at_level,
        Encoding.json,
        EncoderConfig.production(),
        .{ .buffer = output },
        false,
    );
}

test "nop core is always disabled and has no level" {
    var core = Core{ .nop = {} };

    try std.testing.expect(!core.enabled(.debug));
    try std.testing.expect(!core.enabled(.info));
    try std.testing.expectEqual(@as(?Level, null), core.current_level());
    try std.testing.expectEqual(@as(?*arc.AtomicLevel, null), core.atomic_level());
    try std.testing.expectEqual(Level.fatal, core.minimum_level());

    try core.write(std.testing.io, &Entry.init(std.testing.io, .info, "ignored", "test"), &.{}, &.{});
    try core.sync(std.testing.io);
}

test "io core enabled respects threshold" {
    var output = Buffer.init();
    var core = Core{ .io = make_io_core(&output, .warn) };

    try std.testing.expect(!core.enabled(.debug));
    try std.testing.expect(!core.enabled(.info));
    try std.testing.expect(core.enabled(.warn));
    try std.testing.expect(core.enabled(.err));

    try std.testing.expectEqual(Level.warn, core.current_level().?);
    try std.testing.expectEqual(Level.warn, core.minimum_level());

    std.debug.assert(core.current_level().? == .warn);
    std.debug.assert(core.minimum_level() == .warn);
}

test "io core writes encoded entry to buffer" {
    var output = Buffer.init();
    var core = Core{ .io = make_io_core(&output, .debug) };

    var entry = Entry.init(std.testing.io, .info, "hello world", "app");
    try core.write(std.testing.io, &entry, &.{}, &.{});

    try std.testing.expect(!output.is_empty());
    try std.testing.expect(output.contains("hello world"));
    try std.testing.expect(output.contains("info"));

    std.debug.assert(output.contains("hello world"));
    std.debug.assert(output.contains("info"));
}

test "io core includes context fields in writes" {
    var output = Buffer.init();
    var core = Core{ .io = make_io_core(&output, .debug) };

    var entry = Entry.init(std.testing.io, .info, "boot", "svc");
    try core.write(std.testing.io, &entry, &.{
        arc.string("service", "auth"),
        arc.int("version", 2),
    }, &.{});

    try std.testing.expect(output.contains("boot"));
    try std.testing.expect(output.contains("service"));
    try std.testing.expect(output.contains("auth"));
    try std.testing.expect(output.contains("version"));

    std.debug.assert(output.contains("auth"));
}

test "tee core writes to all enabled outputs" {
    var output_a = Buffer.init();
    var output_b = Buffer.init();

    const cores = [_]IoCore{
        make_io_core(&output_a, .debug),
        make_io_core(&output_b, .debug),
    };

    var core = Core{ .tee = TeeCore.init(&cores) };

    var entry = Entry.init(std.testing.io, .info, "fanout", "tee");
    try core.write(std.testing.io, &entry, &.{}, &.{});

    try std.testing.expect(output_a.contains("fanout"));
    try std.testing.expect(output_b.contains("fanout"));

    std.debug.assert(output_a.contains("fanout"));
    std.debug.assert(output_b.contains("fanout"));
}

test "tee core filters per child level" {
    var output_info = Buffer.init();
    var output_err = Buffer.init();

    const cores = [_]IoCore{
        make_io_core(&output_info, .info),
        make_io_core(&output_err, .err),
    };

    var core = Core{ .tee = TeeCore.init(&cores) };

    var info_entry = Entry.init(std.testing.io, .info, "info only", "tee");
    try core.write(std.testing.io, &info_entry, &.{}, &.{});

    try std.testing.expect(output_info.contains("info only"));
    try std.testing.expect(!output_err.contains("info only"));

    var err_entry = Entry.init(std.testing.io, .err, "error both", "tee");
    try core.write(std.testing.io, &err_entry, &.{}, &.{});

    try std.testing.expect(output_info.contains("error both"));
    try std.testing.expect(output_err.contains("error both"));

    try std.testing.expectEqual(Level.info, core.minimum_level());
}

test "increase level core rejects lower minimum than wrapped core" {
    var output = Buffer.init();
    var inner = Core{ .io = make_io_core(&output, .warn) };

    try std.testing.expectError(
        error.LevelNotIncreased,
        IncreaseLevelCore.init(&inner, .info),
    );
}

test "increase level core raises effective minimum" {
    var output = Buffer.init();
    var inner = Core{ .io = make_io_core(&output, .debug) };

    var raised = try IncreaseLevelCore.init(&inner, .err);

    try std.testing.expect(!raised.enabled(.debug));
    try std.testing.expect(!raised.enabled(.info));
    try std.testing.expect(!raised.enabled(.warn));
    try std.testing.expect(raised.enabled(.err));
    try std.testing.expect(raised.enabled(.fatal));
    try std.testing.expectEqual(Level.err, raised.level());

    var err_entry = Entry.init(std.testing.io, .err, "visible", "raised");
    try raised.write(std.testing.io, &err_entry, &.{}, &.{});

    try std.testing.expect(output.contains("visible"));
    try std.testing.expect(!output.contains("hidden"));

    std.debug.assert(output.contains("visible"));
}

test "increase level core sync delegates to inner core" {
    var output = Buffer.init();
    var inner = Core{ .io = make_io_core(&output, .debug) };
    var raised = try IncreaseLevelCore.init(&inner, .fatal);

    try raised.sync(std.testing.io);

    var entry = Entry.init(std.testing.io, .fatal, "synced", "raised");
    try raised.write(std.testing.io, &entry, &.{}, &.{});

    try std.testing.expect(output.contains("synced"));
}

test "core atomic level exposes io core atomic level" {
    var output = Buffer.init();
    var core = Core{ .io = make_io_core(&output, .info) };

    const atomic = core.atomic_level().?;
    try std.testing.expectEqual(Level.info, atomic.level());

    atomic.set_level(.err);

    try std.testing.expectEqual(Level.err, atomic.level());
    try std.testing.expectEqual(Level.err, core.current_level().?);
    try std.testing.expect(!core.enabled(.info));
    try std.testing.expect(core.enabled(.err));

    std.debug.assert(core.current_level().? == .err);
}
