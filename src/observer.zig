const std = @import("std");
const entry_mod = @import("core/entry.zig");
const field_mod = @import("core/field.zig");
const level_mod = @import("core/level.zig");

const Entry = entry_mod.Entry;
const Field = field_mod.Field;
const Level = level_mod.Level;

pub const entries_max: u32 = 128;
pub const entry_fields_max: u32 = 32;
pub const entry_message_max: u32 = 512;
pub const entry_name_max: u32 = 128;
pub const entry_field_bytes_max: u32 = 2048;

pub const ObservedEntry = struct {
    at_level: Level,
    message_buffer: [entry_message_max]u8,
    message_length: u32,
    name_buffer: [entry_name_max]u8,
    name_length: u32,
    fields: [entry_fields_max]Field,
    fields_count: u32,
    field_bytes: [entry_field_bytes_max]u8,
    field_bytes_length: u32,
    timestamp_s: i64,

    pub fn message(self: *const ObservedEntry) []const u8 {
        std.debug.assert(self.message_length <= entry_message_max);

        return self.message_buffer[0..self.message_length];
    }

    pub fn logger_name(self: *const ObservedEntry) []const u8 {
        std.debug.assert(self.name_length <= entry_name_max);

        return self.name_buffer[0..self.name_length];
    }

    pub fn all_fields(self: *const ObservedEntry) []const Field {
        std.debug.assert(self.fields_count <= entry_fields_max);

        return self.fields[0..self.fields_count];
    }

    pub fn has_field(self: *const ObservedEntry, key: []const u8) bool {
        std.debug.assert(key.len > 0);
        std.debug.assert(self.fields_count <= entry_fields_max);

        const active = self.fields[0..self.fields_count];

        for (active) |field| {
            if (std.mem.eql(u8, field.key, key)) {
                return true;
            }
        }

        return false;
    }

    pub fn field_by_key(self: *const ObservedEntry, key: []const u8) ?Field {
        std.debug.assert(key.len > 0);
        std.debug.assert(self.fields_count <= entry_fields_max);

        const active = self.fields[0..self.fields_count];

        for (active) |field| {
            if (std.mem.eql(u8, field.key, key)) {
                return field;
            }
        }

        return null;
    }
};

pub const Observer = struct {
    entries: [entries_max]ObservedEntry,
    entries_count: u32,
    minimum_level: Level,

    pub fn init(at_minimum_level: Level) Observer {
        var observer: Observer = undefined;
        observer.entries_count = 0;
        observer.minimum_level = at_minimum_level;

        return observer;
    }

    pub fn record(
        self: *Observer,
        entry: *const Entry,
        context_fields: []const Field,
        call_fields: []const Field,
    ) void {
        std.debug.assert(context_fields.len <= field_mod.fields_max);
        std.debug.assert(call_fields.len <= field_mod.fields_max);

        if (!self.minimum_level.enabled(entry.level)) {
            return;
        }

        if (self.entries_count >= entries_max) {
            return;
        }

        const slot = &self.entries[self.entries_count];
        slot.at_level = entry.level;
        slot.timestamp_s = entry.timestamp_s;

        const message_length: u32 = @intCast(@min(entry.message.len, entry_message_max));
        @memcpy(slot.message_buffer[0..message_length], entry.message[0..message_length]);
        slot.message_length = message_length;

        const name_length: u32 = @intCast(@min(entry.logger_name.len, entry_name_max));
        @memcpy(slot.name_buffer[0..name_length], entry.logger_name[0..name_length]);
        slot.name_length = name_length;

        slot.field_bytes_length = 0;
        slot.fields_count = 0;

        for (context_fields) |*field| {
            observe_field(slot, field);
        }

        for (call_fields) |*field| {
            observe_field(slot, field);
        }

        self.entries_count += 1;

        std.debug.assert(self.entries_count <= entries_max);
    }

    pub fn enabled(self: *const Observer, at_level: Level) bool {
        return self.minimum_level.enabled(at_level);
    }

    pub fn all(self: *const Observer) []const ObservedEntry {
        std.debug.assert(self.entries_count <= entries_max);

        return self.entries[0..self.entries_count];
    }

    pub fn len(self: *const Observer) u32 {
        return self.entries_count;
    }

    pub fn is_empty(self: *const Observer) bool {
        return self.entries_count == 0;
    }

    pub fn reset(self: *Observer) void {
        self.entries_count = 0;
    }

    pub fn count_by_level(self: *const Observer, at_level: Level) u32 {
        std.debug.assert(self.entries_count <= entries_max);

        var count: u32 = 0;
        const active = self.entries[0..self.entries_count];

        for (active) |*observed_entry| {
            if (observed_entry.at_level == at_level) {
                count += 1;
            }
        }

        return count;
    }

    pub fn count_by_message(self: *const Observer, target_message: []const u8) u32 {
        std.debug.assert(self.entries_count <= entries_max);
        std.debug.assert(target_message.len > 0);

        var count: u32 = 0;
        const active = self.entries[0..self.entries_count];

        for (active) |*observed_entry| {
            if (std.mem.eql(u8, observed_entry.message(), target_message)) {
                count += 1;
            }
        }

        return count;
    }

    pub fn filter_by_level(
        self: *const Observer,
        at_level: Level,
        result: *[entries_max]u32,
    ) u32 {
        std.debug.assert(self.entries_count <= entries_max);

        var count: u32 = 0;
        const active = self.entries[0..self.entries_count];

        for (active, 0..) |*observed_entry, index| {
            if (observed_entry.at_level == at_level) {
                result[count] = @intCast(index);
                count += 1;
            }
        }

        return count;
    }

    pub fn filter_by_message(
        self: *const Observer,
        target_message: []const u8,
        result: *[entries_max]u32,
    ) u32 {
        std.debug.assert(self.entries_count <= entries_max);
        std.debug.assert(target_message.len > 0);

        var count: u32 = 0;
        const active = self.entries[0..self.entries_count];

        for (active, 0..) |*observed_entry, index| {
            if (std.mem.eql(u8, observed_entry.message(), target_message)) {
                result[count] = @intCast(index);
                count += 1;
            }
        }

        return count;
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

fn observe_intern(slot: *ObservedEntry, data: []const u8) []const u8 {
    std.debug.assert(slot.field_bytes_length <= entry_field_bytes_max);

    const available: u32 = entry_field_bytes_max - slot.field_bytes_length;
    const copy_length: u32 = @intCast(@min(data.len, available));
    const start = slot.field_bytes_length;

    @memcpy(slot.field_bytes[start..][0..copy_length], data[0..copy_length]);
    slot.field_bytes_length += copy_length;

    std.debug.assert(slot.field_bytes_length <= entry_field_bytes_max);
    return slot.field_bytes[start..][0..copy_length];
}

fn observe_field(slot: *ObservedEntry, field: *const Field) void {
    std.debug.assert(slot.fields_count <= entry_fields_max);

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
