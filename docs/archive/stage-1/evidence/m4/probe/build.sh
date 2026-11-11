#!/usr/bin/env bash
#
# Builds the M4.3 calibration probe.
#
# It links the *real* PhotonCore sources (compiled with -O here, because the probe also records
# M4 timings) rather than a copy of the maths, so the measured distributions come from exactly the
# code `photon deliver` runs. All scratch state (TMPDIR / module cache / dylibs / binary) lives
# inside work/m4/probe/ (gitignored), per the DSH sandbox rules in app/README.md.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

mkdir -p "$HERE/bin" "$HERE/.tmp" "$HERE/.mc" "$HERE/.build" "$HERE/out"
export TMPDIR="$HERE/.tmp"

# 1) The shared contract package as a module + dylib (PhotonCore imports it).
swiftc -O \
    -module-cache-path "$HERE/.mc" \
    -emit-module -emit-library \
    -module-name PhotonContract \
    -emit-module-path "$HERE/.build/PhotonContract.swiftmodule" \
    -o "$HERE/.build/libPhotonContract.dylib" \
    "$REPO"/contract/Sources/PhotonContract/*.swift

# 2) The probe + every PhotonCore source in one module. `-parse-as-library` lets calibrate.swift
#    provide its `@main` entry point instead of a `main.swift` top-level file.
swiftc -O \
    -module-cache-path "$HERE/.mc" \
    -parse-as-library \
    -I "$HERE/.build" \
    -L "$HERE/.build" \
    -lPhotonContract \
    -Xlinker -rpath -Xlinker @loader_path/../.build \
    -o "$HERE/bin/calibrate" \
    "$HERE/calibrate.swift" \
    "$REPO"/app/Sources/PhotonCore/*.swift

echo "built $HERE/bin/calibrate"
