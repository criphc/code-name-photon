#!/usr/bin/env bash
#
# Self-test for tools/verify-heic (M0-B).
#
# Builds the verifier, generates plain-SDR negative controls, runs the
# verifier across positive controls (Apple legacy HEIC, this repo's synthetic
# encoder runs), negative controls and failure paths, then asserts the reports
# with validate.py. Reports + stdout logs land in work/m0/verify/reports/.
#
# Usage: bash work/m0/verify/self-test.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
TOOL="$ROOT/tools/verify-heic/bin/verify-heic"
OUT="$HERE/out"
REPORTS="$HERE/reports"
mkdir -p "$OUT" "$REPORTS"
rm -f "$REPORTS"/*.json "$REPORTS"/*.stdout.txt "$REPORTS"/*.exit

echo "== build =="
"$ROOT/tools/verify-heic/build.sh" || { echo "BUILD FAILED"; exit 1; }
"$TOOL" --version

echo
echo "== negative-control fixtures =="
export TMPDIR="$HERE/.tmp"
mkdir -p "$TMPDIR" "$HERE/.mc"
swiftc -module-cache-path "$HERE/.mc" -O "$HERE/make-controls.swift" -o "$HERE/make-controls" \
    || { echo "CONTROL BUILD FAILED"; exit 1; }
"$HERE/make-controls" "$OUT" || { echo "CONTROL GENERATION FAILED"; exit 1; }

run() {
    local name="$1"
    shift
    local report="$REPORTS/$name.json"
    "$TOOL" "$@" --out "$report" > "$REPORTS/$name.stdout.txt" 2>&1
    local code=$?
    echo "$code" > "$REPORTS/$name.exit"
    printf '%-26s exit=%s\n' "$name" "$code"
}

echo
echo "== verifier runs =="
# positive control: Apple legacy gain-map HEIC (samples/ is gitignored but present on this machine)
run positive-img7097 "$ROOT/samples/reference/IMG_7097.HEIC"

# lead smoke file (read-only reference; tmap HEIC written by Core Image)
if [[ -f "$ROOT/work/lead-smoke/out/hdr.heic" ]]; then
    run lead-smoke "$ROOT/work/lead-smoke/out/hdr.heic"
fi

# synthetic encoder matrix (task-1 output)
SYNTH_BASE="$ROOT/work/m0/synthetic/base.tif"
if [[ -f "$ROOT/work/m0/synthetic/out-b-r25/hdr.heic" ]]; then
    run synth-out-b-r25 "$ROOT/work/m0/synthetic/out-b-r25/hdr.heic" --base "$SYNTH_BASE" --expect-headroom 4.0
    run synth-out-b-r15 "$ROOT/work/m0/synthetic/out-b-r15/hdr.heic" --base "$SYNTH_BASE" --expect-headroom 4.0
    run synth-out-b-r6  "$ROOT/work/m0/synthetic/out-b-r6/hdr.heic"  --base "$SYNTH_BASE" --expect-headroom 4.0
    run synth-out-b-r25-H "$ROOT/work/m0/synthetic/out-b-r25-H/hdr.heic" --base "$SYNTH_BASE"
    run synth-out-nob-r25 "$ROOT/work/m0/synthetic/out-nob-r25/hdr.heic"
else
    echo "  (synthetic encoder outputs not present, skipping)"
fi

# real pair (task-3 output) — included when present, never required.
# task-3 writes into work/m0/real/out/ while we run, so snapshot the files first
# and only use a snapshot whose bytes did not change while copying. That keeps
# each report internally consistent even if the teammate re-encodes later.
REAL_OUT="$ROOT/work/m0/real/out"
REAL_BASE="$ROOT/work/m0/real/sdr.tif"
REAL_SNAP="$HERE/real-snapshot"
if compgen -G "$REAL_OUT/*.heic" > /dev/null; then
    snapshot_ok=0
    for attempt in 1 2; do
        rm -rf "$REAL_SNAP"
        mkdir -p "$REAL_SNAP"
        snapshot_ok=1
        for source in "$REAL_OUT"/*.heic; do
            [[ -f "$source" ]] || continue
            target="$REAL_SNAP/$(basename "$source")"
            if ! cp -p "$source" "$target" 2>/dev/null; then snapshot_ok=0; break; fi
            if [[ "$(shasum -a 256 "$source" 2>/dev/null | cut -d' ' -f1)" != "$(shasum -a 256 "$target" 2>/dev/null | cut -d' ' -f1)" ]]; then
                snapshot_ok=0
                break
            fi
        done
        if [[ $snapshot_ok -eq 1 && -f "$REAL_BASE" ]]; then
            cp -p "$REAL_BASE" "$REAL_SNAP/sdr.tif" 2>/dev/null || snapshot_ok=0
            if [[ $snapshot_ok -eq 1 && "$(shasum -a 256 "$REAL_BASE" | cut -d' ' -f1)" != "$(shasum -a 256 "$REAL_SNAP/sdr.tif" | cut -d' ' -f1)" ]]; then
                snapshot_ok=0
            fi
        fi
        [[ $snapshot_ok -eq 1 ]] && break
        sleep 2
    done
    if [[ $snapshot_ok -ne 1 ]]; then
        echo "  (real-pair files changed while snapshotting — skipping real-pair runs)"
        rm -rf "$REAL_SNAP"
    else
        SNAP_BASE="$REAL_SNAP/sdr.tif"
        for heic in "$REAL_SNAP"/*-2560.heic; do
            [[ -f "$heic" ]] || continue
            run "real-$(basename "$heic" .heic)" "$heic" --expect-headroom 2.5
        done
        for heic in "$REAL_SNAP"/*-sdr.heic; do
            [[ -f "$heic" ]] || continue
            if [[ -f "$SNAP_BASE" ]]; then
                run "real-$(basename "$heic" .heic)" "$heic" --base "$SNAP_BASE"
            else
                run "real-$(basename "$heic" .heic)" "$heic"
            fi
        done
        for heic in "$REAL_SNAP"/*.heic; do
            [[ -f "$heic" ]] || continue
            case "$heic" in
                *-2560.heic|*-sdr.heic) continue ;;
            esac
            name="real-$(basename "$heic" .heic)"
            if [[ -f "$SNAP_BASE" ]]; then
                run "$name" "$heic" --base "$SNAP_BASE" --expect-headroom 2.5
            else
                run "$name" "$heic" --expect-headroom 2.5
            fi
            sdr_reference="${heic%.heic}-sdr.heic"
            if [[ -f "$sdr_reference" ]]; then
                run "$name-vs-sdrheic" "$heic" --base "$sdr_reference"
            fi
            break
        done
    fi
else
    echo "  (real-pair outputs not present, skipping)"
fi

# required M0 deliverable: the real full-resolution file against the 16-bit base
DELIVERABLE="$ROOT/work/m0/deliverable/R0003777-M0.heic"
if [[ -f "$DELIVERABLE" && -f "$ROOT/work/m0/real/sdr.tif" ]]; then
    run real-full-final "$DELIVERABLE" --base "$ROOT/work/m0/real/sdr.tif" --expect-headroom 2.5
else
    echo "  (work/m0/deliverable/R0003777-M0.heic not present, skipping real-full-final)"
fi

# negative controls
run negative-sdr-p3 "$OUT/sdr-p3.heic"
run negative-sdr-p3-base "$OUT/sdr-p3.heic" --base "$OUT/checker-base.tif"
run negative-uniform-base "$OUT/uniform-sdr.heic" --base "$OUT/uniform-base.tif"
run alpha-diff "$OUT/sdr-p3-alpha.heic" --base "$OUT/sdr-p3.heic"

# non-HEIF input (the repo's JPEG look reference carries an Apple JPEG gain map;
# verify-heic must reject it as a HEIC deliverable, not crash)
if [[ -f "$ROOT/samples/reference/IMG_7473.JPG" ]]; then
    run non-heif-jpeg "$ROOT/samples/reference/IMG_7473.JPG"
fi

# headroom threshold failure path
if [[ -f "$ROOT/work/m0/synthetic/out-b-r25/hdr.heic" ]]; then
    run headroom-mismatch "$ROOT/work/m0/synthetic/out-b-r25/hdr.heic" --base "$SYNTH_BASE" --expect-headroom 2.5
fi

# CLI failure path
"$TOOL" "$OUT/does-not-exist.heic" > "$REPORTS/missing-file.stdout.txt" 2>&1
echo $? > "$REPORTS/missing-file.exit"
echo "missing-file                exit=$(cat "$REPORTS/missing-file.exit")"
"$TOOL" > "$REPORTS/no-args.stdout.txt" 2>&1
echo $? > "$REPORTS/no-args.exit"
echo "no-args                     exit=$(cat "$REPORTS/no-args.exit")"

echo
echo "== assertions =="
python3 "$HERE/validate.py" "$REPORTS"
RESULT=$?
echo
if [[ $RESULT -eq 0 ]]; then
    echo "SELF-TEST: PASS"
else
    echo "SELF-TEST: FAIL"
fi
exit $RESULT
