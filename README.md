<p align="center">
    <picture>
        <source media="(prefers-color-scheme: dark)" srcset="assets/arc-wordmark-on-dark.svg">
        <source media="(prefers-color-scheme: light)" srcset="assets/arc-wordmark-on-light.svg">
        <img alt="arc" src="assets/arc-wordmark-on-light.svg" width="200">
    </picture>
</p>

&nbsp;

<p align="center">
    A library for structured, leveled logging. A Zig port of <a href="https://github.com/uber-go/zap">uber-go/zap</a>.
</p>

<p align="center">
    <a href="https://github.com/braycarlson/arc/actions/workflows/ci.yml"><img alt="ci" src="https://img.shields.io/github/actions/workflow/status/braycarlson/arc/ci.yml?branch=main&amp;style=flat-square&amp;label=ci"></a>
    <a href="https://ziglang.org"><img alt="zig" src="https://img.shields.io/badge/zig-0.16.0-orange.svg?style=flat-square"></a>
    <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square"></a>
</p>

## Overview

A log call takes a message and a slice of typed fields, which the encoder writes without
reflection or formatting at the call site. The API takes no allocator, so a call cannot
fail on memory and returns nothing to check.

## Features

- **Two encoders**: The JSON encoder writes one object per line, and the console encoder
  writes a coloured, tab-separated line for a terminal.
- **Typed fields**: There are 42 constructors, from `string` and `int` to `duration_ns`,
  `namespace`, and `err`, and an entry carries up to 32 of them.
- **Sinks**: A writer is stderr, stdout, a file descriptor, a buffer, a tee, a mutex, a
  buffered wrapper, or a rotating file.
- **Sampling**: The production preset keeps the first 100 entries of a message each tick
  and then every hundredth, so a hot loop cannot flood the sink.
- **Runtime level**: An `AtomicLevel` moves the threshold while the program runs, and
  `check` lets a caller skip the work behind an entry that would be dropped.
- **Printf**: A `SugaredLogger` takes a format string instead of a slice of fields.
- **Test support**: An `Observer` records entries in memory, so a test asserts on the
  entry rather than on a formatted string.
- **Dependencies**: There are none outside the Zig toolchain.

## Install

The library ships as a Zig package holding one module, also named `arc`. Fetch it into
your own project and import the module in your `build.zig`.

```
zig fetch --save git+https://github.com/braycarlson/arc
```

```zig
const arc = b.dependency("arc", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("arc", arc.module("arc"));
```

arc requires Zig 0.16.0.

## Usage

A logger is a value the caller owns, and `arc.global` holds one for code that cannot take
it as a parameter. Pass `@src()` so the entry carries its caller, and call `sync` before
the process exits.

```zig
const std = @import("std");

const arc = @import("arc");

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();

    var logger = arc.Logger.init_production(threaded.io());

    logger.info("server starting", &.{
        arc.string("addr", "0.0.0.0:8080"),
        arc.int("workers", 4),
    }, @src());

    var request = logger.named("http").with(&.{
        arc.string("route", "/health"),
    });

    request.warn("slow response", &.{
        arc.duration_ns("elapsed", 1_500_000_000),
        arc.int("status", 200),
    }, @src());

    try logger.sync();
}
```

```console
{"level":"info","ts":1786858249.652941717,"caller":"main.zig:14","msg":"server starting","addr":"0.0.0.0:8080","workers":4}
{"level":"warn","ts":1786858249.652967845,"logger":"http","caller":"main.zig:23","msg":"slow response","route":"/health","elapsed":1.5,"status":200}
```

The `named` call adds a scope and `with` binds fields to every entry that follows, so a
subsystem logger states its context once rather than at each call.

## Configuration

A `Config` is a plain struct, and each builder method returns a copy, so a preset composes
into the shape a program wants without touching the original.

| Preset | What it sets |
|---|---|
| `Config.production()` | The JSON encoder at `info`, with sampling and locking on. |
| `Config.development()` | The console encoder at `debug`, with sampling and locking off. |
| `Config.nop()` | The nop writer at `fatal`, so nothing is encoded or written. |

```zig
pub fn build_logger(io: std.Io) arc.Logger {
    return arc.Logger.init_with_config(io, arc.Config.production()
        .with_level(.debug)
        .with_encoding(.console)
        .without_sampling());
}
```

## Development

The recipes below wrap `zig build`, and a bare `just` lists them all. The tidy law is a
test rather than a separate linter, so the mechanical rules run with everything else.

| Command | What it runs |
|---|---|
| `just ci` | The formatting check, compilation, and each test suite. |
| `just test` | Each test suite and the formatting check. |
| `just tidy` | The tidy law on its own. |
| `just test-tsan` | The test suites under the thread sanitizer. |
| `just fuzz <name> [seed] [events]` | The named fuzzer: `buffer`, `datetime`, `json`, `level`, `canary`, or `smoke`. |
| `just bench` | The benchmark suite in `ReleaseFast`. |
| `just soak` | The long-running soak test in `ReleaseSafe`. |

## Licence

MIT. See [LICENSE](LICENSE). The port carries zap's own copyright notice in
[NOTICE](NOTICE).
