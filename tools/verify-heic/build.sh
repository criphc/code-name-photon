#!/usr/bin/env bash
#
# Reproducible build for tools/verify-heic/verify-heic.swift.
#
# Works from a clean checkout of tools/verify-heic/ alone: all scratch state
# (Swift module cache / TMPDIR) lives inside this directory and is created on
# demand. The only external requirement is the Xcode command-line toolchain
# (swiftc) with the macOS SDK.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

mkdir -p bin .tmp .mc

# Swift in sandboxed/non-interactive environments needs a writable TMPDIR and
# module cache; without these swiftc fails with a clang module cache error.
export TMPDIR="$HERE/.tmp"

swiftc \
    -module-cache-path "$HERE/.mc" \
    -O \
    -o "$HERE/bin/verify-heic" \
    "$HERE/verify-heic.swift"

echo "built $HERE/bin/verify-heic"
