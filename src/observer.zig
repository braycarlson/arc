const std = @import("std");

const bounded = @import("bounded.zig");
const field_module = @import("field.zig");
const json = @import("json.zig");
const level_module = @import("level.zig");
const record_module = @import("record.zig");

const assert = std.debug.assert;

const Field = field_module.Field;
const Level = level_module.Level;

pub const Observer = struct {
    count: u32,
    dropped_count: u32,
    slots: [record_count_max]Record,

    pub const Record = struct {
        field_bytes: bounded.BoundedArrayType(u8, field_bytes_max),
        fields: bounded.BoundedArrayType(Field, field_module.field_count_max),
        level: Level,
        message: bounded.BoundedArrayType(u8, message_bytes_max),
        name: bounded.BoundedArrayType(u8, name_bytes_max),
        time_ns: i64,
        truncated: bool,

        pub fn field(record: *const Record, key: []const u8) ?Field {
            assert(key.len > 0);
            assert(record.fields.count <= field_module.field_count_max);

            for (record.fields.slice()) |each| {
                if (std.mem.eql(u8, each.key, key)) return each;
            }

            return null;
        }

        fn intern(record: *Record, bytes: []const u8) []const u8 {
            assert(bytes.len <= field_module.text_bytes_max);
            assert(record.field_bytes.count <= field_bytes_max);

            const start = record.field_bytes.count;
            const room = field_bytes_max - start;
            const kept = bytes[0..@min(bytes.len, room)];

            if (kept.len < bytes.len) record.truncated = true;

            record.field_bytes.push_slice_assume_capacity(kept);

            return record.field_bytes.slice()[start..];
        }

        fn add(record: *Record, source: *const Field) void {
            assert(source.valid());
            assert(record.fields.count < field_module.field_count_max);

            if (element_count(&source.value) > 0) record.truncated = true;

            const key = record.intern(source.key);

            const value: Field.Value = switch (source.value) {
                .binary => |bytes| .{ .binary = record.intern(bytes) },
                .boolean_list => .{ .boolean_list = &.{} },
                .duration_ns_list => .{ .duration_ns_list = &.{} },
                .float_list => .{ .float_list = &.{} },
                .integer_list => .{ .integer_list = &.{} },
                .object => .{ .object = &.{} },
                .string => |text| .{ .string = record.intern(text) },
                .string_list => .{ .string_list = &.{} },
                .time_ns_list => .{ .time_ns_list = &.{} },
                .unsigned_list => .{ .unsigned_list = &.{} },
                .boolean,
                .duration_ns,
                .float,
                .integer,
                .namespace,
                .skip,
                .time_ns,
                .unsigned,
                => source.value,
            };

            record.fields.push_slot_assume_capacity().* = .{ .key = key, .value = value };
        }
    };

    pub fn init(observer: *Observer) void {
        assert(observer.slots.len == record_count_max);

        observer.count = 0;
        observer.dropped_count = 0;

        assert(observer.records().len == 0);
    }

    pub fn records(observer: *const Observer) []const Record {
        assert(observer.count <= record_count_max);

        return observer.slots[0..observer.count];
    }

    pub fn reset(observer: *Observer) void {
        assert(observer.count <= record_count_max);

        observer.count = 0;
        observer.dropped_count = 0;
    }

    pub fn observe(
        observer: *Observer,
        source: *const record_module.Record,
        fields: *const json.Fields,
    ) void {
        assert(observer.count <= record_count_max);
        assert(fields.call.len <= field_module.field_count_max);

        if (observer.count == record_count_max) {
            observer.dropped_count += 1;

            return;
        }

        const record = &observer.slots[observer.count];
        const message = source.message[0..@min(source.message.len, message_bytes_max)];
        const name = source.name[0..@min(source.name.len, name_bytes_max)];

        record.field_bytes = .empty;
        record.fields = .empty;
        record.level = source.level;
        record.message = .empty;
        record.name = .empty;
        record.time_ns = source.time_ns;
        record.truncated = message.len < source.message.len;

        if (name.len < source.name.len) record.truncated = true;

        record.message.push_slice_assume_capacity(message);
        record.name.push_slice_assume_capacity(name);

        for ([2][]const Field{ fields.context, fields.call }) |slice| {
            for (slice) |*field| {
                if (record.fields.full()) {
                    record.truncated = true;

                    break;
                }

                record.add(field);
            }
        }

        observer.count += 1;
    }
};

pub const field_bytes_max: u32 = 2048;
pub const message_bytes_max: u32 = 512;
pub const name_bytes_max: u32 = 128;
pub const record_count_max: u32 = 128;

comptime {
    assert(field_bytes_max > field_module.key_bytes_max);
    assert(message_bytes_max > 0);
    assert(name_bytes_max > 0);
    assert(record_count_max > 0);
}

fn element_count(value: *const Field.Value) u32 {
    const count: u32 = @intCast(switch (value.*) {
        .boolean_list => |list| list.len,
        .duration_ns_list, .integer_list, .time_ns_list => |list| list.len,
        .float_list => |list| list.len,
        .object => |fields| fields.len,
        .string_list => |list| list.len,
        .unsigned_list => |list| list.len,
        .binary,
        .boolean,
        .duration_ns,
        .float,
        .integer,
        .namespace,
        .skip,
        .string,
        .time_ns,
        .unsigned,
        => 0,
    });

    assert(count <= @max(field_module.list_count_max, field_module.field_count_max));

    return count;
}

const testing = std.testing;

fn test_source(message: []const u8) record_module.Record {
    assert(message.len > 0);
    assert(message.len <= message_bytes_max * 2);

    return .{
        .caller = null,
        .level = .information,
        .message = message,
        .name = "watcher",
        .time_ns = 7,
    };
}

test Observer {
    const observer = try testing.allocator.create(Observer);
    defer testing.allocator.destroy(observer);

    observer.init();

    var source = test_source("disk filling");

    source.level = .warn;

    observer.observe(&source, &.{
        .call = &.{.{ .key = "free_bytes", .value = .{ .unsigned = 1024 } }},
        .context = &.{.{ .key = "host", .value = .{ .string = "db-1" } }},
        .fragment = null,
    });

    const record = &observer.records()[0];

    try testing.expectEqual(Level.warn, record.level);
    try testing.expectEqualStrings("disk filling", record.message.slice());
    try testing.expectEqualStrings("watcher", record.name.slice());
    try testing.expectEqualStrings("host", record.fields.get(0).key);
    const free_bytes = record.field("free_bytes") orelse return error.FieldMissing;

    try testing.expectEqual(@as(u64, 1024), free_bytes.value.unsigned);
    try testing.expect(record.field("missing") == null);
}

test "an observer owns the bytes of the fields it recorded" {
    const observer = try testing.allocator.create(Observer);
    defer testing.allocator.destroy(observer);

    var key: [8]u8 = "changing".*;
    var value: [7]u8 = "initial".*;

    const source = test_source("borrowed");

    observer.init();

    observer.observe(&source, &.{
        .call = &.{.{ .key = &key, .value = .{ .string = &value } }},
        .context = &.{},
        .fragment = null,
    });

    @memset(&key, 'z');
    @memset(&value, 'z');

    const field = observer.records()[0].fields.get(0);

    try testing.expectEqualStrings("changing", field.key);
    try testing.expectEqualStrings("initial", field.value.string);
}

test "an observer stops recording once it is full and resets to empty" {
    const observer = try testing.allocator.create(Observer);
    defer testing.allocator.destroy(observer);

    const source = test_source("flood");
    const fields: json.Fields = .{ .call = &.{}, .context = &.{}, .fragment = null };

    observer.init();

    for (0..record_count_max + 8) |_| observer.observe(&source, &fields);

    try testing.expectEqual(record_count_max, observer.count);

    observer.reset();

    try testing.expectEqual(@as(usize, 0), observer.records().len);
}

test "an observer truncates a long message and keeps at most the field bound" {
    const observer = try testing.allocator.create(Observer);
    defer testing.allocator.destroy(observer);

    const message: [message_bytes_max * 2]u8 = @splat('m');

    const many: [field_module.field_count_max]Field = @splat(.{
        .key = "k",
        .value = .{ .integer = 1 },
    });

    const source = test_source(&message);

    observer.init();
    observer.observe(&source, &.{ .call = &many, .context = &many, .fragment = null });

    const record = &observer.records()[0];

    try testing.expectEqual(message_bytes_max, record.message.count);
    try testing.expectEqual(field_module.field_count_max, record.fields.count);
}

test "an observer counts the records it drops and flags a record it clipped" {
    const observer = try testing.allocator.create(Observer);
    defer testing.allocator.destroy(observer);

    const message: [message_bytes_max + 1]u8 = @splat('m');
    const clipped = test_source(&message);
    const plain = test_source("plain");

    observer.init();

    observer.observe(&plain, &.{
        .call = &.{.{ .key = "empty", .value = .{ .integer_list = &.{} } }},
        .context = &.{},
        .fragment = null,
    });

    observer.observe(&clipped, &.{ .call = &.{}, .context = &.{}, .fragment = null });

    observer.observe(&plain, &.{
        .call = &.{.{ .key = "list", .value = .{ .integer_list = &.{ 1, 2 } } }},
        .context = &.{},
        .fragment = null,
    });

    const records = observer.records();

    try testing.expect(!records[0].truncated);
    try testing.expect(records[1].truncated);
    try testing.expect(records[2].truncated);
    try testing.expectEqual(@as(usize, 0), records[2].fields.get(0).value.integer_list.len);

    for (0..record_count_max) |_| {
        observer.observe(&plain, &.{ .call = &.{}, .context = &.{}, .fragment = null });
    }

    try testing.expectEqual(record_count_max, observer.count);
    try testing.expectEqual(@as(u32, 3), observer.dropped_count);
}
