const std = @import("std");

const assert = std.debug.assert;

comptime {
    _ = @import("arc.zig");
    _ = @import("base64.zig");
    _ = @import("bounded.zig");
    _ = @import("buffer.zig");
    _ = @import("console.zig");
    _ = @import("core.zig");
    _ = @import("datetime.zig");
    _ = @import("encoding.zig");
    _ = @import("field.zig");
    _ = @import("golden_tests.zig");
    _ = @import("json.zig");
    _ = @import("level.zig");
    _ = @import("logger.zig");
    _ = @import("logger_tests.zig");
    _ = @import("observer.zig");
    _ = @import("record.zig");
    _ = @import("rotating_file.zig");
    _ = @import("sampler.zig");
    _ = @import("tidy.zig");
    _ = @import("writer.zig");
}

test "every public declaration compiles" {
    const arc = @import("arc.zig");

    comptime assert(@hasDecl(arc, "Core"));
    comptime assert(@hasDecl(arc, "Logger"));

    std.testing.refAllDecls(arc);
    std.testing.refAllDecls(arc.Core);
    std.testing.refAllDecls(arc.Logger);
    std.testing.refAllDecls(arc.limits);
}
