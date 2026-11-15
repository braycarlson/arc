const std = @import("std");

const arc = @import("arc");

const assert = std.debug.assert;

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len > 0);

    var core: arc.Core = undefined;

    core.init(init.io, &.production);

    core.logger.information(
        "server starting",
        &.{
            .{ .key = "address", .value = .{ .string = "0.0.0.0:8080" } },
            .{ .key = "workers", .value = .{ .integer = 4 } },
        },
        &@src(),
    );

    var http: arc.Logger = undefined;

    core.logger.child(&http, &.{
        .fields = &.{.{ .key = "route", .value = .{ .string = "/health" } }},
        .name = "http",
    });

    http.warn(
        "slow response",
        &.{
            .{ .key = "elapsed", .value = .{ .duration_ns = 1_500_000_000 } },
            .{ .key = "status", .value = .{ .integer = 200 } },
        },
        &@src(),
    );

    try core.flush();

    assert(core.failed_count.load(.monotonic) == 0);
}
