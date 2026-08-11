const std = @import("std");
const entry_mod = @import("core/entry.zig");
const field_mod = @import("core/field.zig");
const level_mod = @import("core/level.zig");

const assert = std.debug.assert;

const Entry = entry_mod.Entry;
const Field = field_mod.Field;
const EntryFields = field_mod.EntryFields;
const Level = level_mod.Level;

pub const Observer = struct {
    entries: [entries_max]ObservedEntry,
    entries_count: u32,
    minimum_level: Level,

    pub fn init(observer: *Observer, at_minimum_level: Level) void {
        observer.entries_count = 0;
        observer.minimum_level = at_minimum_level;

        assert(observer.is_valid());
    }

    pub fn record(
        self: *Observer,
        entry: *const Entry,
        fields: EntryFields,
    ) void {
        assert(fields.is_valid());
        assert(self.is_valid());

        if (!self.minimum_level.enabled(entry.level)) {
            return;
        }

        if (self.entries_count >= entries_max) {
            return;
        }

        const slot = &self.entries[self.entries_count];
        slot.at_level = entry.level;
        slot.timestamp_s = entry.timestamp_s;

        const message_length: u32 = @intCast(@min(entry.message.len, entry_message_bytes_max));
        @memcpy(slot.message_buffer[0..message_length], entry.message[0..message_length]);
        slot.message_length = message_length;

        const name_length: u32 = @intCast(@min(entry.logger_name.len, entry_name_bytes_max));
        @memcpy(slot.name_buffer[0..name_length], entry.logger_name[0..name_length]);
        slot.name_length = name_length;

        slot.field_bytes_length = 0;
        slot.fields_count = 0;

        for (fields.context) |*field| {
            observe_field(slot, field);
        }

        for (fields.message) |*field| {
            observe_field(slot, field);
        }

        self.entries_count += 1;

        assert(self.is_valid());
    }

    pub fn enabled(self: *const Observer, at_level: Level) bool {
        return self.minimum_level.enabled(at_level);
    }

    pub fn all(self: *const Observer) []const ObservedEntry {
        assert(self.entries_count <= entries_max);

        return self.entries[0..self.entries_count];
    }

    pub fn count(self: *const Observer) u32 {
        return self.entries_count;
    }

    pub fn is_empty(self: *const Observer) bool {
        return self.entries_count == 0;
    }

    pub fn is_valid(self: *const Observer) bool {
        return self.entries_count <= entries_max;
    }

    pub fn reset(self: *Observer) void {
        self.entries_count = 0;
    }

    pub fn count_by_level(self: *const Observer, at_level: Level) u32 {
        assert(self.entries_count <= entries_max);

        var matches: u32 = 0;
        const active = self.entries[0..self.entries_count];

        for (active) |*observed_entry| {
            if (observed_entry.at_level == at_level) {
                matches += 1;
            }
        }

        return matches;
    }

    pub fn count_by_message(self: *const Observer, target_message: []const u8) u32 {
        assert(self.entries_count <= entries_max);
        assert(target_message.len > 0);

        var matches: u32 = 0;
        const active = self.entries[0..self.entries_count];

        for (active) |*observed_entry| {
            if (std.mem.eql(u8, observed_entry.message(), target_message)) {
                matches += 1;
            }
        }

        return matches;
    }

    pub fn filter_by_level(
        self: *const Observer,
        at_level: Level,
        result: *[entries_max]u32,
    ) u32 {
        assert(self.entries_count <= entries_max);

        var matches: u32 = 0;
        const active = self.entries[0..self.entries_count];

        for (active, 0..) |*observed_entry, index| {
            if (observed_entry.at_level == at_level) {
                result[matches] = @intCast(index);
                matches += 1;
            }
        }

        return matches;
    }

    pub fn filter_by_message(
        self: *const Observer,
        target_message: []const u8,
        result: *[entries_max]u32,
    ) u32 {
        assert(self.entries_count <= entries_max);
        assert(target_message.len > 0);

        var matches: u32 = 0;
        const active = self.entries[0..self.entries_count];

        for (active, 0..) |*observed_entry, index| {
            if (std.mem.eql(u8, observed_entry.message(), target_message)) {
                result[matches] = @intCast(index);
                matches += 1;
            }
        }

        return matches;
    }

    pub fn last(self: *const Observer) ?*const ObservedEntry {
        if (self.entries_count == 0) {
            return null;
        }

        return &self.entries[self.entries_count - 1];
    }

    pub fn first(self: *const Observer) ?*const ObservedEntry {
        if (self.entries_count == 0) {
            return null;
        }

        return &self.entries[0];
    }
};

pub const ObservedEntry = struct {
    at_level: Level,
    message_buffer: [entry_message_bytes_max]u8,
    message_length: u32,
    name_buffer: [entry_name_bytes_max]u8,
    name_length: u32,
    fields: [entry_fields_max]Field,
    fields_count: u32,
    field_bytes: [entry_field_bytes_max]u8,
    field_bytes_length: u32,
    timestamp_s: i64,

    pub fn message(self: *const ObservedEntry) []const u8 {
        assert(self.message_length <= entry_message_bytes_max);

        return self.message_buffer[0..self.message_length];
    }

    pub fn logger_name(self: *const ObservedEntry) []const u8 {
        assert(self.name_length <= entry_name_bytes_max);

        return self.name_buffer[0..self.name_length];
    }

    pub fn all_fields(self: *const ObservedEntry) []const Field {
        assert(self.fields_count <= entry_fields_max);

        return self.fields[0..self.fields_count];
    }

    pub fn has_field(self: *const ObservedEntry, key: []const u8) bool {
        assert(key.len > 0);
        assert(self.fields_count <= entry_fields_max);

        const active = self.fields[0..self.fields_count];

        for (active) |field| {
            if (std.mem.eql(u8, field.key, key)) {
                return true;
            }
        }

        return false;
    }

    pub fn field_by_key(self: *const ObservedEntry, key: []const u8) ?Field {
        assert(key.len > 0);
        assert(self.fields_count <= entry_fields_max);

        const active = self.fields[0..self.fields_count];

        for (active) |field| {
            if (std.mem.eql(u8, field.key, key)) {
                return field;
            }
        }

        return null;
    }
};

pub const entries_max: u32 = 128;
pub const entry_fields_max: u32 = field_mod.fields_max;
pub const entry_message_bytes_max: u32 = 512;
pub const entry_name_bytes_max: u32 = 128;
pub const entry_field_bytes_max: u32 = 2048;

comptime {
    assert(entries_max > 0);
    assert(entry_fields_max == field_mod.fields_max);
    assert(entry_message_bytes_max > 0);
    assert(entry_name_bytes_max > 0);
    assert(entry_field_bytes_max > 0);
}

fn observe_intern(slot: *ObservedEntry, data: []const u8) []const u8 {
    assert(slot.field_bytes_length <= entry_field_bytes_max);

    const available: u32 = entry_field_bytes_max - slot.field_bytes_length;
    const copy_length: u32 = @intCast(@min(data.len, available));
    const start = slot.field_bytes_length;

    @memcpy(slot.field_bytes[start..][0..copy_length], data[0..copy_length]);
    slot.field_bytes_length += copy_length;

    assert(slot.field_bytes_length <= entry_field_bytes_max);

    return slot.field_bytes[start..][0..copy_length];
}

fn observe_field(slot: *ObservedEntry, field: *const Field) void {
    assert(slot.fields_count <= entry_fields_max);

    if (slot.fields_count >= entry_fields_max) {
        return;
    }

    const owned_key = observe_intern(slot, field.key);

    var stored: Field = .{
        .key = owned_key,
        .field_type = field.field_type,
        .value = .{ .none = {} },
    };

    switch (field.value) {
        .text => |text| stored.value = .{ .text = observe_intern(slot, text) },
        .bytes => |bytes| stored.value = .{ .bytes = observe_intern(slot, bytes) },
        .signed => |value| stored.value = .{ .signed = value },
        .unsigned => |value| stored.value = .{ .unsigned = value },
        .float => |value| stored.value = .{ .float = value },
        .boolean => |value| stored.value = .{ .boolean = value },
        .none => {},
        .text_list,
        .signed_list,
        .unsigned_list,
        .float_list,
        .bool_list,
        .field_list,
        .marshal,
        => {},
    }

    slot.fields[slot.fields_count] = stored;
    slot.fields_count += 1;
}

const testing = std.testing;

fn entry_at(at_level: Level, message: []const u8) Entry {
    return Entry.init(testing.io, at_level, message, "watcher");
}

test "a new observer holds no entries" {
    var observer: Observer = undefined;

    observer.init(.debug);

    try testing.expect(observer.is_empty());
    try testing.expectEqual(@as(u32, 0), observer.count());
    try testing.expect(observer.first() == null);
    try testing.expect(observer.last() == null);

    assert(observer.entries_count == 0);
}

test "an observer records an entry with its message, name, and level" {
    var observer: Observer = undefined;

    observer.init(.debug);
    const entry = entry_at(.warn, "disk filling");

    observer.record(&entry, .{ .context = &.{}, .message = &.{} });

    try testing.expectEqual(@as(u32, 1), observer.count());

    const recorded = observer.last() orelse return error.MissingEntry;

    try testing.expectEqual(Level.warn, recorded.at_level);
    try testing.expectEqualStrings("disk filling", recorded.message());
    try testing.expectEqualStrings("watcher", recorded.logger_name());

    assert(!observer.is_empty());
}

test "an observer drops entries below its minimum level" {
    var observer: Observer = undefined;

    observer.init(.warn);
    const quiet = entry_at(.info, "quiet");
    const loud = entry_at(.err, "loud");

    try testing.expect(!observer.enabled(.info));
    try testing.expect(observer.enabled(.err));

    observer.record(&quiet, .{ .context = &.{}, .message = &.{} });
    observer.record(&loud, .{ .context = &.{}, .message = &.{} });

    try testing.expectEqual(@as(u32, 1), observer.count());

    const recorded = observer.first() orelse return error.MissingEntry;

    try testing.expectEqualStrings("loud", recorded.message());

    assert(observer.entries_count == 1);
}

test "an observer copies context fields before call fields" {
    var observer: Observer = undefined;

    observer.init(.debug);
    const entry = entry_at(.info, "request");

    observer.record(&entry, .{
        .context = &.{field_mod.string("service", "api")},
        .message = &.{
            field_mod.int64("status", 200),
            field_mod.boolean("cached", false),
        },
    });

    const recorded = observer.last() orelse return error.MissingEntry;

    try testing.expectEqual(@as(u32, 3), recorded.fields_count);
    try testing.expectEqualStrings("service", recorded.all_fields()[0].key);
    try testing.expectEqualStrings("status", recorded.all_fields()[1].key);
    try testing.expect(recorded.has_field("cached"));
    try testing.expect(!recorded.has_field("missing"));

    const status = recorded.field_by_key("status") orelse return error.MissingField;

    try testing.expectEqual(@as(i64, 200), status.value.signed);
    try testing.expect(recorded.field_by_key("missing") == null);

    assert(recorded.fields_count == 3);
}

test "an observer owns the bytes of the fields it recorded" {
    var observer: Observer = undefined;

    observer.init(.debug);
    const entry = entry_at(.info, "borrowed");

    var key_storage: [8]u8 = "changing".*;
    var value_storage: [7]u8 = "initial".*;

    observer.record(&entry, .{
        .context = &.{},
        .message = &.{field_mod.string(&key_storage, &value_storage)},
    });

    @memset(&key_storage, 'z');
    @memset(&value_storage, 'z');

    const recorded = observer.last() orelse return error.MissingEntry;

    try testing.expectEqualStrings("changing", recorded.all_fields()[0].key);
    try testing.expectEqualStrings("initial", recorded.all_fields()[0].value.text);

    assert(recorded.fields_count == 1);
}

test "an observer counts and filters by level and by message" {
    var observer: Observer = undefined;

    observer.init(.debug);
    const first_warn = entry_at(.warn, "retry");
    const second_warn = entry_at(.warn, "retry");
    const single_error = entry_at(.err, "give up");

    observer.record(&first_warn, .{ .context = &.{}, .message = &.{} });
    observer.record(&second_warn, .{ .context = &.{}, .message = &.{} });
    observer.record(&single_error, .{ .context = &.{}, .message = &.{} });

    try testing.expectEqual(@as(u32, 2), observer.count_by_level(.warn));
    try testing.expectEqual(@as(u32, 1), observer.count_by_level(.err));
    try testing.expectEqual(@as(u32, 0), observer.count_by_level(.debug));
    try testing.expectEqual(@as(u32, 2), observer.count_by_message("retry"));
    try testing.expectEqual(@as(u32, 0), observer.count_by_message("absent"));

    var indexes: [entries_max]u32 = undefined;

    try testing.expectEqual(@as(u32, 2), observer.filter_by_level(.warn, &indexes));
    try testing.expectEqual(@as(u32, 0), indexes[0]);
    try testing.expectEqual(@as(u32, 1), indexes[1]);
    try testing.expectEqual(@as(u32, 1), observer.filter_by_message("give up", &indexes));
    try testing.expectEqual(@as(u32, 2), indexes[0]);

    assert(observer.all().len == 3);
}

test "an observer stops recording once it is full and resets to empty" {
    var observer: Observer = undefined;

    observer.init(.debug);
    const entry = entry_at(.info, "flood");

    var index: u32 = 0;

    while (index < entries_max + 8) : (index += 1) {
        observer.record(&entry, .{ .context = &.{}, .message = &.{} });
    }

    try testing.expectEqual(entries_max, observer.count());

    observer.reset();

    try testing.expect(observer.is_empty());

    assert(observer.entries_count == 0);
}

test "an observer truncates a message longer than its slot" {
    var observer: Observer = undefined;

    observer.init(.debug);

    var long_message: [entry_message_bytes_max * 2]u8 = @splat('m');
    const entry = entry_at(.info, &long_message);

    observer.record(&entry, .{ .context = &.{}, .message = &.{} });

    const recorded = observer.last() orelse return error.MissingEntry;

    try testing.expectEqual(entry_message_bytes_max, recorded.message_length);

    assert(recorded.message().len == entry_message_bytes_max);
}

test "an observer stores at most entry_fields_max fields per entry" {
    var observer: Observer = undefined;

    observer.init(.debug);
    const entry = entry_at(.info, "wide");

    var fields: [field_mod.fields_max]Field = undefined;

    for (&fields) |*field| {
        field.* = field_mod.int64("k", 1);
    }

    observer.record(&entry, .{ .context = fields[0..], .message = fields[0..] });

    const recorded = observer.last() orelse return error.MissingEntry;

    try testing.expectEqual(entry_fields_max, recorded.fields_count);

    assert(recorded.all_fields().len == entry_fields_max);
}
