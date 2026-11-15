# arc

A library for structured, leveled logging. The library is a Zig port of [uber-go/zap](https://github.com/uber-go/zap), with typed fields, named child loggers, and JSON and console output. A logger can write to several sinks at once, including a rotating file, and a sampler keeps a repeated message from flooding the output. An in-memory observer captures entries so a test can assert on what was logged.
