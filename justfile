set windows-shell := ["cmd.exe", "/c"]

default:
    @just --list

ci:
    zig build ci --summary all

check:
    zig build check --summary all

build:
    zig build --summary all

test:
    zig build test --summary all

test-safe:
    zig build test --release=safe --summary all

test-tsan:
    zig build test -Dtsan=true --release=safe --summary all

unit filter="":
    zig build test:unit --summary all {{ if filter == "" { "" } else { "-Dtest-filter=" + filter } }}

integration filter="":
    zig build test:integration --summary all {{ if filter == "" { "" } else { "-Dtest-filter=" + filter } }}

tidy:
    zig build test:unit -Dtest-filter=tidy

fmt:
    zig build test:fmt

format:
    zig fmt build.zig benchmarks examples src

run:
    zig build run

bench:
    zig build bench --release=fast --summary all

soak:
    zig build soak --release=safe --summary all

fuzz-build:
    zig build fuzz:build --summary all

smoke:
    zig build fuzz:smoke --summary all

fuzz-buffer seed="" events="":
    zig build fuzz -- buffer {{seed}} {{events}}

fuzz-datetime seed="" events="":
    zig build fuzz -- datetime {{seed}} {{events}}

fuzz-json seed="" events="":
    zig build fuzz -- json {{seed}} {{events}}

fuzz-level seed="" events="":
    zig build fuzz -- level {{seed}} {{events}}

fuzz-canary seed="" events="":
    zig build fuzz -- canary {{seed}} {{events}}

fuzz name="smoke" seed="" events="":
    zig build fuzz -- {{name}} {{seed}} {{events}}

reproduce name seed:
    zig build fuzz -- {{name}} {{seed}}

fuzz-all seed="" events="":
    just fuzz-buffer {{seed}} {{events}}
    just fuzz-datetime {{seed}} {{events}}
    just fuzz-json {{seed}} {{events}}
    just fuzz-level {{seed}} {{events}}

release:
    zig build --release=safe

[unix]
clean:
    rm -rf zig-out .zig-cache

[windows]
clean:
    if exist zig-out rmdir /s /q zig-out
    if exist .zig-cache rmdir /s /q .zig-cache
