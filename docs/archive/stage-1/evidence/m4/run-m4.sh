#!/usr/bin/env bash
#
# M4.5 acceptance run — docs/07 §6 M4.5, §1 M4 acceptance, §10 result.
#
# Reproduces, from the repo root, the evidence that M4 is done:
#   1. release build of the CLI
#   2. the M3-posted recipe applied at full resolution by `photon deliver`
#   3. the exact four files in --out, the report verdict and its measured checks
#   4. the independent ImageIO cross-check (`tools/verify-heic`) on the delivered HEIC
#   5. the SDR base is the M1 bit-exact pass-through (same sdr.tif hash as M1)
#   6. two deliveries of the same recipe are byte-identical (HEIC, fallback copy, recipe echo)
#   7. the `<id>` CLI form resolves the same item as `--source`
#   8. the SDR fallback copy is map-stripped and matches the base
#
# Everything lands in work/m4/ (gitignored). Run from anywhere; it cd's to the repo root.
set -euo pipefail

cd "$(dirname "$0")/../.."
REPO="$PWD"
EVID="$REPO/work/m4"
PHOTON="$REPO/app/.build-release/release/photon"
VERIFY="$REPO/tools/verify-heic/bin/verify-heic"
SRC="$REPO/samples/sources/R0003777-P3.tif"

# The M3-posted recipe (docs/07 §2 "Acceptance image"): start .1971 / lift 2.0151 / transition 1.0 / cap 2.5.
M3_SHA="bd486ca6e0a26734feba094190aec098d77c9a0e23a66c0cc641086f03916116"
RECIPE="$REPO/work/m3/server/$M3_SHA/recipe.json"
M1_SDR_SHA="5378900171aaa2f42fb698ecfe43b841d5032958cffb2bda84efc20d72c40604"

mkdir -p "$EVID"
echo "== M4.5 acceptance run $(date -Iseconds)"
echo "   repo    $REPO"
echo "   source  $SRC"
echo "   recipe  $RECIPE"

test -f "$SRC"    || { echo "missing $SRC (samples/ is gitignored)"; exit 1; }
test -f "$RECIPE" || { echo "missing $RECIPE (the M3 server work folder)"; exit 1; }
test -x "$PHOTON" || { echo "missing $PHOTON — run 'cd app && make release'"; exit 1; }
test -x "$VERIFY" || { echo "missing $VERIFY — run tools/verify-heic/build.sh"; exit 1; }

echo
echo "== 1. release build"
( cd "$REPO/app" && make release >"$EVID/build.log" 2>&1 )
echo "   ok ($(grep -c . "$EVID/build.log") log lines)"

echo
echo "== 2. the SDR base stays the M1 bit-exact pass-through"
rm -rf "$EVID/base-check"
"$PHOTON" prep "$SRC" --recipe "$RECIPE" --out "$EVID/base-check" >"$EVID/base-check.log" 2>&1
SDR_SHA="$(shasum -a 256 "$EVID/base-check/sdr.tif" | cut -d' ' -f1)"
echo "   sdr.tif sha256 $SDR_SHA"
if [[ "$SDR_SHA" != "$M1_SDR_SHA" ]]; then
    echo "   FAIL: sdr.tif is not the M1 base (expected $M1_SDR_SHA)" >&2
    exit 1
fi
echo "   PASS: identical to the M1-recorded base"

echo
echo "== 3. two deliveries of the same recipe (determinism)"
rm -rf "$EVID/run1" "$EVID/run2"
cp -R "$REPO/out" "$EVID/out-before" 2>/dev/null || true
(for i in 1 2; do
    /usr/bin/time -l "$PHOTON" deliver \
        --source "$SRC" --recipe "$RECIPE" --work "$REPO/work/m3/server" --out "$REPO/out" \
        >"$EVID/deliver-run$i.log" 2>"$EVID/deliver-run$i.time" || { echo "deliver run $i failed"; exit 1; }
    mkdir -p "$EVID/run$i"
    cp "$REPO"/out/R0003777-P3-hdr.heic "$REPO"/out/R0003777-P3-sdr.heic \
       "$REPO"/out/R0003777-P3.recipe.json "$REPO"/out/R0003777-P3.report.json "$EVID/run$i/"
done)
echo "   run1: $(grep -E 'result|timings' "$EVID/deliver-run1.log" | sed 's/^ *//' | tr '\n' ' ')"
echo "   run2: $(grep -E 'result|timings' "$EVID/deliver-run2.log" | sed 's/^ *//' | tr '\n' ' ')"

for file in R0003777-P3-hdr.heic R0003777-P3-sdr.heic R0003777-P3.recipe.json; do
    a="$(shasum -a 256 "$EVID/run1/$file" | cut -d' ' -f1)"
    b="$(shasum -a 256 "$EVID/run2/$file" | cut -d' ' -f1)"
    if [[ "$a" != "$b" ]]; then
        echo "   FAIL: $file differs between runs ($a vs $b)" >&2
        exit 1
    fi
    echo "   byte-identical $file  $a"
done
if cmp -s "$EVID/run1/R0003777-P3.report.json" "$EVID/run2/R0003777-P3.report.json"; then
    echo "   note: report.json is byte-identical too (unexpected: it carries timings)"
else
    echo "   report.json differs between runs (timings only, as documented)"
fi

echo
echo "== 4. report verdict and measured checks"
python3 - "$EVID/run1/R0003777-P3.report.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
print(f"   pass={report['pass']}  failures={report['failures']}")
print(f"   hdr.heic {report['artifacts']['hdrHEIC']['bytes']} B  sha256 {report['artifacts']['hdrHEIC']['sha256']}")
print(f"   sdr.heic {report['artifacts']['sdrHEIC']['bytes']} B  sha256 {report['artifacts']['sdrHEIC']['sha256']}")
print(f"   render   authoredPeak {report['render']['authoredPeak']} ({report['render']['authoredPeakStops']:.6f} stops), "
      f"fractionAboveOne {report['render']['fractionAboveOne']:.4f}, fractionAtCap {report['render']['fractionAtCap']:.4f}, capEngaged {report['render']['capEngaged']}")
for check in report['checks']:
    print(f"   {check['status']:4s} {check['name']:17s} {check['detail']}")
print(f"   timings  {report['timings']}")
PY

echo
echo "== 5. independent ImageIO cross-check (tools/verify-heic, never sips)"
"$VERIFY" "$REPO/out/R0003777-P3-hdr.heic" \
    --base "$EVID/base-check/sdr.tif" --expect-headroom 2.5 \
    --out "$EVID/verify-heic-hdr.json" | tee "$EVID/verify-heic-hdr.log"
echo "   (also on the SDR fallback copy, where the ISO aux must be absent)"
"$VERIFY" "$REPO/out/R0003777-P3-sdr.heic" \
    --base "$EVID/base-check/sdr.tif" \
    --out "$EVID/verify-heic-sdr.json" >"$EVID/verify-heic-sdr.log" 2>&1 || true
python3 - "$EVID/verify-heic-sdr.json" "$EVID/verify-heic-hdr.json" <<'PY'
import json, sys
sdr, hdr = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
print(f"   HDR report: pass={hdr['overall']['pass']}  checks={ {k: v['pass'] for k, v in hdr['checks'].items()} }")
print(f"   SDR copy:   isoSuxPresent={sdr['aux']['isoAuxPresent']} noAlpha={sdr['checks']['noAlpha']['pass']} "
      f"dimsMatch={sdr['checks']['dimsMatch']['pass']} basePreserved={sdr['checks']['basePreserved']['pass']}")
PY

echo
echo "== 6. the <id> CLI form resolves the same item"
"$PHOTON" deliver "$M3_SHA" --batch "$REPO/samples/sources" --recipe "$RECIPE" \
    --work "$REPO/work/m3/server" --out "$REPO/out" >"$EVID/deliver-by-id.log" 2>&1
grep -E "source|result" "$EVID/deliver-by-id.log" | sed 's/^/   /'

echo
echo "== 7. result files"
shasum -a 256 "$REPO"/out/R0003777-P3-* "$REPO"/out/R0003777-P3.recipe.json > "$EVID/out-sha256.txt"
cat "$EVID/out-sha256.txt"
echo
echo "M4.5 evidence in $EVID"
