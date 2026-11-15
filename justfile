set shell := ["sh", "-c"]
set windows-shell := ["powershell.exe", "-c"]

[doc('Run the benchmark suite')]
bench:
    zig build bench --release=fast

[doc('Compile every artifact for Linux, macOS, and Windows')]
check:
    zig build check

[doc('Run the continuous integration pipeline')]
ci:
    zig build ci
    zig build test:unit -Doptimize=safe

[doc('Build and run the example')]
example:
    zig build example

[doc('Format the benchmarks, build.zig, the examples, and every source file')]
fmt:
    zig fmt benchmarks build.zig examples src

[doc('Run a fuzzer: just fuzz <fuzzer> [seed] [events]')]
fuzz *arguments:
    zig build fuzz -- {{ arguments }}

[doc('Lint the benchmarks, build.zig, the examples, and every source file with tigerstyle-lsp')]
lint:
    tigerstyle-lsp check benchmarks build.zig examples src --format concise

[default]
[doc('List every recipe')]
list:
    @just --list

[doc('Run the multi-threaded soak')]
soak:
    zig build soak --release=safe

[doc('Run every test suite and the format check')]
test:
    zig build test

[doc('Run every test suite under ThreadSanitizer')]
test-tsan:
    zig build test -Dtsan=true --release=safe

[doc('Run the unit tests and the tidy check: just test-unit [filter]')]
test-unit filter="":
    zig build test:unit {{ if filter == "" { "" } else { "-Dtest-filter=" + filter } }}
