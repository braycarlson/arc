const std = @import("std");

const assert = std.debug.assert;

pub const Field = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        binary: []const u8,
        boolean: bool,
        boolean_list: []const bool,
        duration_ns: i64,
        duration_ns_list: []const i64,
        float: f64,
        float_list: []const f64,
        integer: i64,
        integer_list: []const i64,
        namespace,
        object: []const Field,
        skip,
        string: []const u8,
        string_list: []const []const u8,
        time_ns: i64,
        time_ns_list: []const i64,
        unsigned: u64,
        unsigned_list: []const u64,
    };

    pub const skip: Field = .{ .key = "", .value = .skip };

    pub fn valid(field: *const Field) bool {
        if (field.value == .skip) return field.key.len == 0;
        if (field.key.len == 0) return false;
        if (field.key.len > key_bytes_max) return false;

        return switch (field.value) {
            .binary, .string => |text| text.len <= text_bytes_max,
            .boolean_list => |list| list.len <= list_count_max,
            .duration_ns_list, .integer_list, .time_ns_list => |list| list.len <= list_count_max,
            .float_list => |list| list.len <= list_count_max,
            .object => |fields| fields.len <= field_count_max,
            .string_list => |list| list.len <= list_count_max,
            .unsigned_list => |list| list.len <= list_count_max,
            .boolean,
            .duration_ns,
            .float,
            .integer,
            .namespace,
            .skip,
            .time_ns,
            .unsigned,
            => true,
        };
    }
};

pub const field_count_max: u32 = 32;
pub const key_bytes_max: u32 = 128;
pub const list_count_max: u32 = 64;
pub const text_bytes_max: u32 = 1 << 31;

comptime {
    assert(field_count_max > 0);
    assert(key_bytes_max > 0);
    assert(list_count_max > 0);
    assert(@sizeOf(Field) == 40);
    assert(Field.skip.valid());
}

const testing = std.testing;

test Field {
    const fields = [_]Field{
        .{ .key = "method", .value = .{ .string = "GET" } },
        .{ .key = "status", .value = .{ .integer = 200 } },
        .{ .key = "elapsed", .value = .{ .duration_ns = 1_500_000_000 } },
        .{ .key = "client", .value = .{ .object = &.{
            .{ .key = "address", .value = .{ .string = "10.0.0.1" } },
            .{ .key = "port", .value = .{ .unsigned = 443 } },
        } } },
        .skip,
    };

    for (&fields) |*field| {
        try testing.expect(field.valid());
    }

    for (fields[3].value.object) |*field| {
        try testing.expect(field.valid());
    }

    try testing.expectEqual(@as(u64, 443), fields[3].value.object[1].value.unsigned);
    try testing.expectEqualStrings("", fields[4].key);
}

test "a field is invalid with an empty or oversized key or an oversized list" {
    const key_longest: [key_bytes_max]u8 = @splat('k');
    const key_too_long: [key_bytes_max + 1]u8 = @splat('k');
    const integers: [list_count_max + 1]i64 = @splat(0);
    const children: [field_count_max + 1]Field = @splat(.skip);

    const valid_fields = [_]Field{
        .{ .key = &key_longest, .value = .namespace },
        .{ .key = "list", .value = .{ .integer_list = integers[0..list_count_max] } },
        .{ .key = "object", .value = .{ .object = children[0..field_count_max] } },
    };

    const invalid_fields = [_]Field{
        .{ .key = "", .value = .{ .boolean = true } },
        .{ .key = &key_too_long, .value = .namespace },
        .{ .key = "list", .value = .{ .integer_list = &integers } },
        .{ .key = "object", .value = .{ .object = &children } },
        .{ .key = "skip", .value = .skip },
    };

    for (&valid_fields) |*field| {
        try testing.expect(field.valid());
    }

    for (&invalid_fields) |*field| {
        try testing.expect(!field.valid());
    }
}
