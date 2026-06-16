const std = @import("std");
const arc = @import("arc");

const Buffer = arc.buffer_mod.Buffer;
const Clock = arc.Clock;
const Config = arc.Config;
const Core = arc.Core;
const EncoderConfig = arc.EncoderConfig;
const Encoding = arc.encoder_mod.Encoding;
const IoCore = arc.IoCore;
const IncreaseLevelCore = arc.IncreaseLevelCore;
const Level = arc.Level;
const Logger = arc.Logger;
const Observer = arc.Observer;
const TeeCore = arc.TeeCore;

fn base_config() Config {
    return Config.production()
        .with_level(.debug)
        .without_sampling()
        .without_caller()
        .with_error_output(.{ .nop = {} })
        .with_thread_safety(false)
        .with_stacktrace_level(.fatal);
}

fn buffer_logger(output: *Buffer) Logger {
    var logger = Logger.init_with_config(
        std.testing.io,
        base_config().with_writer(.{ .buffer = output }),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    return logger;
}

fn config_logger(output: *Buffer, encoder_config: EncoderConfig) Logger {
    var logger = Logger.init_with_config(
        std.testing.io,
        base_config()
            .with_writer(.{ .buffer = output })
            .with_encoder_config(encoder_config),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    return logger;
}

fn make_io_core(output: *Buffer, at_level: Level) IoCore {
    return IoCore.init(
        at_level,
        Encoding.json,
        EncoderConfig.production(),
        .{ .buffer = output },
        false,
    );
}

const Address = struct {
    city: []const u8,
    arc_code: u32,

    pub fn marshal_log_object(self: *const Address, encoder: *arc.ObjectEncoder) void {
        encoder.add_string("city", self.city);
        encoder.add_uint("arc", self.arc_code);
    }
};

const User = struct {
    name: []const u8,
    age: u32,
    address: Address,

    pub fn marshal_log_object(self: *const User, encoder: *arc.ObjectEncoder) void {
        encoder.add_string("name", self.name);
        encoder.add_uint("age", self.age);
        encoder.add_object("address", &self.address);
    }
};

const Tags = struct {
    items: []const []const u8,

    pub fn marshal_log_array(self: *const Tags, encoder: *arc.ArrayEncoder) void {
        for (self.items) |item| {
            encoder.append_string(item);
        }
    }
};

const Metrics = struct {
    cpu: f64,
    cores: u32,
    active: bool,
    name: []const u8,
};

const Labeled = struct {
    text: []const u8,

    pub fn to_string(self: *const Labeled) []const u8 {
        return self.text;
    }
};

const Color = enum {
    red,
    green,
    blue,
};

test "chained with produces comma separated json" {
    var output = Buffer.init();
    var logger = buffer_logger(&output);

    var child = logger
        .with(&.{arc.string("a", "1")})
        .with(&.{arc.string("b", "2")});

    child.info("chained", &.{}, @src());

    try std.testing.expect(output.contains("\"a\":\"1\",\"b\":\"2\""));

    std.debug.assert(child.context_fields_count == 2);
}

test "context namespace wraps later fields" {
    var output = Buffer.init();
    var logger = buffer_logger(&output);

    var child = logger.with(&.{
        arc.namespace("ns"),
        arc.string("a", "1"),
    });

    child.info("nested", &.{
        arc.string("b", "2"),
    }, @src());

    try std.testing.expect(output.contains("\"ns\":{\"a\":\"1\",\"b\":\"2\"}"));

    std.debug.assert(child.context_fields_count == 2);
}

test "object field encodes nested marshaler" {
    var output = Buffer.init();
    var logger = buffer_logger(&output);

    const user = User{
        .name = "alice",
        .age = 30,
        .address = .{ .city = "denver", .arc_code = 80014 },
    };

    logger.info("login", &.{arc.object("user", &user)}, @src());

    try std.testing.expect(output.contains(
        "\"user\":{\"name\":\"alice\",\"age\":30," ++
            "\"address\":{\"city\":\"denver\",\"arc\":80014}}",
    ));

    std.debug.assert(output.contains("alice"));
}

test "inline object merges fields into parent" {
    var output = Buffer.init();
    var logger = buffer_logger(&output);

    const address = Address{ .city = "boulder", .arc_code = 80301 };

    logger.info("inlined", &.{
        arc.inline_object(&address),
        arc.string("trailing", "field"),
    }, @src());

    try std.testing.expect(output.contains(
        "\"city\":\"boulder\",\"arc\":80301,\"trailing\":\"field\"",
    ));

    std.debug.assert(output.contains("boulder"));
}

test "array field encodes array marshaler" {
    var output = Buffer.init();
    var logger = buffer_logger(&output);

    const tags = Tags{ .items = &.{ "red", "green", "blue" } };

    logger.info("tagged", &.{arc.array("tags", &tags)}, @src());

    try std.testing.expect(output.contains("\"tags\":[\"red\",\"green\",\"blue\"]"));

    std.debug.assert(output.contains("green"));
}

test "reflect serializes arbitrary struct" {
    var output = Buffer.init();
    var logger = buffer_logger(&output);

    const metrics = Metrics{ .cpu = 0.5, .cores = 8, .active = true, .name = "node-1" };

    logger.info("reflected", &.{arc.reflect("metrics", &metrics)}, @src());

    try std.testing.expect(output.contains(
        "\"metrics\":{\"cpu\":0.5,\"cores\":8,\"active\":true,\"name\":\"node-1\"}",
    ));

    std.debug.assert(output.contains("node-1"));
}

test "reflect serializes slice and enum" {
    var output = Buffer.init();
    var logger = buffer_logger(&output);

    const nums = [_]u32{ 1, 2, 3 };
    const color: Color = .green;

    logger.info("reflected", &.{
        arc.reflect("nums", &nums),
        arc.reflect("color", &color),
    }, @src());

    try std.testing.expect(output.contains("\"nums\":[1,2,3]"));
    try std.testing.expect(output.contains("\"color\":\"green\""));

    std.debug.assert(output.contains("green"));
}

test "stringer logs to_string output" {
    var output = Buffer.init();
    var logger = buffer_logger(&output);

    const labeled = Labeled{ .text = "v1.2.3" };

    logger.info("stringed", &.{arc.stringer("version", &labeled)}, @src());

    try std.testing.expect(output.contains("\"version\":\"v1.2.3\""));

    std.debug.assert(output.contains("v1.2.3"));
}

test "dict field encodes inline object" {
    var output = Buffer.init();
    var logger = buffer_logger(&output);

    logger.info("config", &.{arc.dict("cfg", &.{
        arc.string("host", "localhost"),
        arc.int("port", 8080),
    })}, @src());

    try std.testing.expect(output.contains("\"cfg\":{\"host\":\"localhost\",\"port\":8080}"));

    std.debug.assert(output.contains("localhost"));
}

test "byte_string encodes raw text not base64" {
    var output = Buffer.init();
    var logger = buffer_logger(&output);

    logger.info("raw", &.{arc.byte_string("payload", "hello")}, @src());

    try std.testing.expect(output.contains("\"payload\":\"hello\""));

    std.debug.assert(output.contains("hello"));
}

test "time_ns preserves sub second precision" {
    var output = Buffer.init();
    var logger = buffer_logger(&output);

    logger.info("timed", &.{arc.time_ns("at", 1_700_000_000_123_456_789)}, @src());

    try std.testing.expect(output.contains("\"at\":1700000000.123456789"));

    std.debug.assert(output.contains("1700000000.123456789"));
}

test "uints and durations encode as arrays" {
    var output = Buffer.init();
    var logger = buffer_logger(&output);

    logger.info("arrays", &.{
        arc.uints("counts", &.{ 1, 2, 3 }),
        arc.durations("waits", &.{ 1_000_000_000, 2_000_000_000 }),
    }, @src());

    try std.testing.expect(output.contains("\"counts\":[1,2,3]"));
    try std.testing.expect(output.contains("\"waits\":[1,2]"));

    std.debug.assert(output.contains("counts"));
}

test "duration string composes units" {
    var output = Buffer.init();
    var logger = config_logger(
        &output,
        EncoderConfig.production().with_duration_encoding(.string),
    );

    logger.info("durations", &.{
        arc.duration_ns("a", 90_000_000_000),
        arc.duration_ns("b", 3_661_000_000_000),
        arc.duration_ns("c", 1_500_000_000),
    }, @src());

    try std.testing.expect(output.contains("\"a\":\"1m30s\""));
    try std.testing.expect(output.contains("\"b\":\"1h1m1s\""));
    try std.testing.expect(output.contains("\"c\":\"1.5s\""));

    std.debug.assert(output.contains("1m30s"));
}

test "iso8601 honors time offset" {
    var output = Buffer.init();
    var logger = config_logger(
        &output,
        EncoderConfig.production().with_time_encoding(.iso8601).with_time_offset(330),
    );

    logger.info("offset", &.{}, @src());

    try std.testing.expect(output.contains("+05:30"));

    std.debug.assert(output.contains("+05:30"));
}

test "iso8601 renders pre-1970 timestamps with full precision" {
    var output = Buffer.init();
    var logger = config_logger(
        &output,
        EncoderConfig.production().with_time_encoding(.iso8601),
    );

    logger.info("past", &.{
        arc.time_ns("epoch_minus_one", -1_000_000_000),
        arc.time_ns("half_before_epoch", -500_000_000),
        arc.time_ns("nineteen_hundred", -2_208_988_800_000_000_000),
        arc.time_ns("nanos_after_epoch", 123_456_789),
    }, @src());

    try std.testing.expect(output.contains("\"epoch_minus_one\":\"1969-12-31T23:59:59Z\""));
    try std.testing.expect(output.contains("\"half_before_epoch\":\"1969-12-31T23:59:59.5Z\""));
    try std.testing.expect(output.contains("\"nineteen_hundred\":\"1900-01-01T00:00:00Z\""));
    try std.testing.expect(output.contains("\"nanos_after_epoch\":\"1970-01-01T00:00:00.123456789Z\""));

    std.debug.assert(output.contains("1970-01-01T00:00:00.123456789Z"));
}

test "uintptr and times encode" {
    var output = Buffer.init();
    var logger = config_logger(
        &output,
        EncoderConfig.production().with_time_encoding(.epoch_ns),
    );

    logger.info("values", &.{
        arc.uintptr("addr", 0xDEAD),
        arc.times("stamps", &.{ 1_000_000_000, 2_000_000_000 }),
    }, @src());

    try std.testing.expect(output.contains("\"addr\":57005"));
    try std.testing.expect(output.contains("\"stamps\":[1000000000,2000000000]"));

    std.debug.assert(output.contains("57005"));
}

test "non finite floats encode as json strings" {
    var output = Buffer.init();
    var logger = buffer_logger(&output);

    logger.info("metrics", &.{
        arc.float64("nan", std.math.nan(f64)),
        arc.float64("pos", std.math.inf(f64)),
        arc.float64("neg", -std.math.inf(f64)),
    }, @src());

    try std.testing.expect(output.contains("\"nan\":\"NaN\""));
    try std.testing.expect(output.contains("\"pos\":\"+Inf\""));
    try std.testing.expect(output.contains("\"neg\":\"-Inf\""));

    std.debug.assert(output.contains("NaN"));
}

test "err_from uses error name" {
    var output = Buffer.init();
    var logger = buffer_logger(&output);

    const failure = error.ConnectionRefused;

    logger.@"error"("failed", &.{arc.err_from(failure)}, @src());

    try std.testing.expect(output.contains("\"error\":\"ConnectionRefused\""));

    std.debug.assert(output.contains("ConnectionRefused"));
}

test "dpanic logs even when level disabled" {
    var output = Buffer.init();
    var logger = Logger.init_with_config(
        std.testing.io,
        base_config()
            .with_level(.fatal)
            .with_writer(.{ .buffer = &output })
            .with_dpanic_hook(.write_then_nop),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    try std.testing.expect(!logger.check(.dpanic));

    logger.dpanic("forced", &.{}, @src());

    try std.testing.expect(output.contains("forced"));

    std.debug.assert(output.contains("forced"));
}

test "init_with_core hosts tee core" {
    var output_a = Buffer.init();
    var output_b = Buffer.init();

    const cores = [_]IoCore{
        make_io_core(&output_a, .debug),
        make_io_core(&output_b, .debug),
    };

    var logger = Logger.init_with_core(
        std.testing.io,
        Core{ .tee = TeeCore.init(&cores) },
        base_config(),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    logger.info("fanout", &.{}, @src());

    try std.testing.expect(output_a.contains("fanout"));
    try std.testing.expect(output_b.contains("fanout"));

    std.debug.assert(output_a.contains("fanout"));
}

test "init_with_core hosts observer" {
    var observer = Observer.init(.debug);

    var logger = Logger.init_with_core(
        std.testing.io,
        Core{ .observer = &observer },
        base_config(),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    logger.info("recorded", &.{}, @src());
    logger.warn("again", &.{}, @src());

    try std.testing.expectEqual(@as(u32, 2), observer.len());

    std.debug.assert(observer.len() == 2);
}

test "init_with_core hosts increase level core" {
    var output = Buffer.init();
    var inner = Core{ .io = make_io_core(&output, .debug) };
    var raised = try IncreaseLevelCore.init(&inner, .err);

    var logger = Logger.init_with_core(
        std.testing.io,
        Core{ .increase = &raised },
        base_config(),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    try std.testing.expect(!logger.check(.info));
    try std.testing.expect(logger.check(.err));

    logger.info("hidden", &.{}, @src());
    try std.testing.expect(output.is_empty());

    logger.@"error"("shown", &.{}, @src());
    try std.testing.expect(output.contains("shown"));

    std.debug.assert(output.contains("shown"));
    std.debug.assert(!output.contains("hidden"));
}

test "sugar formats and structures" {
    var output = Buffer.init();
    var logger = buffer_logger(&output);

    var sugared = logger.sugar();

    sugared.infof("listening on port {d}", .{8080}, @src());
    try std.testing.expect(output.contains("listening on port 8080"));

    output.reset();

    sugared.warnw("disk low", &.{arc.uint("free_mb", 128)}, @src());
    try std.testing.expect(output.contains("disk low"));
    try std.testing.expect(output.contains("free_mb"));
    try std.testing.expect(output.contains("128"));

    std.debug.assert(output.contains("free_mb"));
}

test "buffered writer flusher thread flushes periodically" {
    var output = Buffer.init();
    var buffered = arc.BufferedWriter.init(.{ .buffer = &output });

    try buffered.start_flusher(std.testing.io, 5_000_000);

    try buffered.write(std.testing.io, "periodic-data");

    std.Io.sleep(std.testing.io, std.Io.Duration.fromNanoseconds(120_000_000), .awake) catch {};

    buffered.mutex.lockUncancelable(std.testing.io);
    const pending_after = buffered.pending();
    buffered.mutex.unlock(std.testing.io);

    buffered.stop_flusher(std.testing.io);

    try std.testing.expectEqual(@as(u32, 0), pending_after);
    try std.testing.expect(output.contains("periodic-data"));

    std.debug.assert(output.contains("periodic-data"));
}

test "buffered writer sink flushes through logger" {
    var output = Buffer.init();
    var buffered = arc.BufferedWriter.init(.{ .buffer = &output });

    var logger = Logger.init_with_config(
        std.testing.io,
        base_config().with_writer(.{ .buffered = &buffered }),
    );

    logger.set_clock(Clock.init_fixed(1_700_000_000));

    logger.info("buffered", &.{}, @src());
    try std.testing.expect(output.is_empty());

    try logger.sync();
    try std.testing.expect(output.contains("buffered"));

    std.debug.assert(output.contains("buffered"));
}
