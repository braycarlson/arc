#!/usr/bin/env bash
# Reproduce the CI Linux checks locally in a container: formatting, the full
# test suite, the same suite under ThreadSanitizer, and the multi-threaded soak.
# Useful from a Windows host, where -fsanitize-thread cannot be built natively.
#
# Usage (from anywhere): ./.script/test-docker.sh
set -euo pipefail

zig_version="0.16.0"
image="ubuntu:24.04"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# MSYS_NO_PATHCONV stops Git Bash on Windows from rewriting the container paths.
MSYS_NO_PATHCONV=1 docker run --rm \
    -v "${repo_root}:/work:ro" \
    -e ZIG_VERSION="${zig_version}" \
    "${image}" bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq curl xz-utils ca-certificates >/dev/null

cd /tmp
echo "=== downloading zig ${ZIG_VERSION} ==="
curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" -o zig.tar.xz \
  || curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" -o zig.tar.xz
tar xf zig.tar.xz
zig_bin="$(find /tmp -maxdepth 2 -type f -name zig | head -1)"
"${zig_bin}" version

# Build from a writable copy so host artifacts and cache are never touched.
cp -r /work /build
rm -rf /build/.zig-cache /build/zig-out
cd /build

echo "=== zig fmt --check ==="
"${zig_bin}" fmt --check build.zig src examples benchmarks tests
echo "=== zig build test ==="
"${zig_bin}" build test
echo "=== zig build test -Dtsan=true ==="
"${zig_bin}" build test -Dtsan=true
echo "=== zig build soak ==="
"${zig_bin}" build soak
echo "=== zig build fuzz ==="
"${zig_bin}" build fuzz
echo "ALL CHECKS PASSED"
'
