set shell := ["cmd", "/c"]

clear := if os() == "windows" { "cls" } else { "clear" }

# Default recipe
default:
    @just --list

# Build the application (mode: debug, release-safe, release-fast, release-small)
build mode="debug":
    {{clear}} && just clean && zig build {{ if mode == "debug" { "" } else if mode == "release-safe" { "-Doptimize=ReleaseSafe" } else if mode == "release-fast" { "-Doptimize=ReleaseFast" } else if mode == "release-small" { "-Doptimize=ReleaseSmall" } else { "" } }} && zig-out\bin\arc.exe

# Clean build artifacts
clean:
    {{clear}}
    if exist zig-out rd /s /q zig-out
    if exist .zig-cache rd /s /q .zig-cache

# Build in release mode (ReleaseSafe)
release:
    {{clear}} && just clean && zig build -Doptimize=ReleaseSafe

# Run all tests
test:
    {{clear}} && zig build test --summary all

# Run all tests (clean build)
test-clean:
    {{clear}} && just clean && zig build test --summary all

# Run all tests in ReleaseSafe mode
test-safe:
    {{clear}} && zig build test -Doptimize=ReleaseSafe --summary all

# Run benchmarks (ReleaseFast is set in build.zig)
bench:
    {{clear}} && zig build bench
