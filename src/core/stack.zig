const std = @import("std");
const buffer_mod = @import("../io/buffer.zig");

const Buffer = buffer_mod.Buffer;

pub const frames_max: u32 = 64;

pub const StackTrace = struct {
    addresses: [frames_max]usize,
    frames_count: u32,

    pub fn capture(return_address: usize) StackTrace {
        std.debug.assert(return_address != 0);

        var trace: StackTrace = undefined;
        trace.frames_count = 0;

        const captured = std.debug.captureCurrentStackTrace(
            .{ .first_address = return_address },
            &trace.addresses,
        );

        trace.frames_count = @intCast(captured.return_addresses.len);

        if (trace.frames_count == 0) {
            trace.addresses[0] = return_address;
            trace.frames_count = 1;
        }

        std.debug.assert(trace.frames_count > 0);
        std.debug.assert(trace.frames_count <= frames_max);
        return trace;
    }

    pub fn format_to_buffer(self: *const StackTrace, buffer: *Buffer) void {
        std.debug.assert(self.frames_count <= frames_max);

        const active = self.addresses[0..self.frames_count];

        for (active, 0..) |address, index| {
            if (index > 0) {
                buffer.append_byte('\n');
            }

            var scratch: [16]u8 = undefined;

            buffer.append_slice("0x");
            buffer.append_slice(buffer_mod.format_hex(&scratch, @intCast(address)));
        }
    }

    pub fn is_empty(self: *const StackTrace) bool {
        return self.frames_count == 0;
    }

    pub fn count(self: *const StackTrace) u32 {
        return self.frames_count;
    }
};
