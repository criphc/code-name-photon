#!/bin/bash
# M1 integration: the real photograph through the new PhotonCore pipeline, twice, then verify.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
BIN=${BIN:-app/.build/debug/photon}
SRC=samples/sources/R0003777-P3.tif
OUT=work/m1-integration
[ -x "$BIN" ] || { echo "build first: cd app && make build" >&2; exit 1; }
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }
rm -rf "$OUT/run1" "$OUT/run2"
mkdir -p "$OUT/run1" "$OUT/run2"

echo "########## run 1 (timed) ##########"
/usr/bin/time -l "$BIN" prep "$SRC" --out "$OUT/run1" --encoder tools/toGainMapHDR/bin/toGainMapHDR 2>"$OUT/run1.time.txt"
grep -E "maximum resident set size|real|user|sys" "$OUT/run1.time.txt" || true

echo "########## run 2 ##########"
"$BIN" prep "$SRC" --out "$OUT/run2" --encoder tools/toGainMapHDR/bin/toGainMapHDR

echo "########## determinism ##########"
for f in sdr.tif hdr.tif preview.heic; do
  a=$(shasum -a 256 "$OUT/run1/$f" | cut -d' ' -f1)
  b=$(shasum -a 256 "$OUT/run2/$f" | cut -d' ' -f1)
  if [ "$a" = "$b" ]; then echo "IDENTICAL $f $a"; else echo "DIFF $f $a $b"; fi
done
echo "recipe renderKey: $(python3 -c "import json;print(json.load(open('$OUT/run1/meta.json'))['recipe']['versions']['encoder'])")"

echo "########## container ##########"
ls -la "$OUT/run1"
tools/verify-heic/bin/verify-heic "$OUT/run1/preview.heic" --expect-headroom 2.5 --out "$OUT/preview-verify.json" | tail -12

echo "########## base identity (sdr.tif vs source) ##########"
magick compare -metric RMSE "$SRC" "$OUT/run1/sdr.tif" null: 2>&1 || true
echo
magick compare -metric AE "$SRC" "$OUT/run1/sdr.tif" null: 2>&1 || true
echo

echo "########## hdr.tif readback ##########"
magick "$OUT/run1/hdr.tif" -format "max=%[fx:maxima] mean=%[fx:mean] depth=%[depth] colorspace=%[colorspace]\n" info: 2>&1 || true
