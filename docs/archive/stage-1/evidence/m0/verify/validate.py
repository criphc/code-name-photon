#!/usr/bin/env python3
"""Self-test assertions for tools/verify-heic (M0-B).

Reads the JSON reports + recorded exit codes produced by self-test.sh and
asserts the facts that matter. Prints PASS/FAIL per assertion and exits 1 if
any assertion fails (or if a required report is missing).
"""

import glob
import json
import os
import sys

REPORTS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "reports")
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))

failures = []
checks = 0


def load(name):
    path = os.path.join(REPORTS, name + ".json")
    if not os.path.exists(path):
        return None
    try:
        with open(path) as handle:
            return json.load(handle)
    except Exception as exc:  # noqa: BLE001
        check(name + ".json parses", False, str(exc))
        return None


def exit_code(name):
    path = os.path.join(REPORTS, name + ".exit")
    if not os.path.exists(path):
        return None
    try:
        return int(open(path).read().strip())
    except Exception:  # noqa: BLE001
        return None


def check(description, condition, detail=""):
    global checks
    checks += 1
    if condition:
        print(f"  PASS  {description}")
    else:
        print(f"  FAIL  {description}" + (f"  [{detail}]" if detail else ""))
        failures.append(description)


def approx(value, target, rel=0.05):
    try:
        return abs(float(value) / float(target) - 1.0) <= rel
    except Exception:  # noqa: BLE001
        return False


def get(report, *path):
    current = report
    for key in path:
        if not isinstance(current, dict) or key not in current:
            return None
        current = current[key]
    return current


def check_common_schema(name, report, required_checks):
    check(f"{name}: overall present", isinstance(report.get("overall"), dict))
    check(f"{name}: file.sha256 is 64 hex chars",
          isinstance(get(report, "file", "sha256"), str) and len(get(report, "file", "sha256")) == 64)
    check(f"{name}: file.sizeBytes > 0", (get(report, "file", "sizeBytes") or 0) > 0)
    check(f"{name}: container has ftyp brands",
          isinstance(get(report, "container", "ftyp", "compatibleBrands"), list))
    check(f"{name}: container itemCount parsed", get(report, "container", "itemCount") is not None)
    primary = report.get("primaryImage", {})
    for key in ("width", "height", "bitsPerComponent", "bitsPerPixel", "alphaInfo",
                "hasAlpha", "profileName", "isFloat", "isFloatDecoded", "orientation"):
        check(f"{name}: primaryImage.{key}", key in primary, str(primary.keys()))
    sdr = report.get("sdrDecode", {})
    check(f"{name}: sdrDecode.contentHeadroom", "contentHeadroom" in sdr)
    check(f"{name}: sdrDecode.calculatedContentHeadroom", "calculatedContentHeadroom" in sdr)
    hdr = report.get("hdrDecode", {})
    for key in ("success", "contentHeadroom"):
        check(f"{name}: hdrDecode.{key}", key in hdr)
    measured = hdr.get("measured") or {}
    for key in ("peak", "mean", "fractionAboveOne"):
        check(f"{name}: hdrDecode.measured.{key}", key in measured)
    present_checks = set(report.get("checks", {}).keys())
    for required in required_checks:
        check(f"{name}: checks.{required} present", required in present_checks, str(sorted(present_checks)))
    overall = report.get("overall", {})
    check(f"{name}: overall.failures is a list", isinstance(overall.get("failures"), list))
    tool_version = get(report, "tool", "version")
    check(f"{name}: tool.version recorded", isinstance(tool_version, str) and tool_version != "")


def main():
    print(f"verifying reports in {REPORTS}")

    # ------------------------------------------------------------------ positive control
    name = "positive-img7097"
    report = load(name)
    check("positive control report exists", report is not None)
    if report:
        check_common_schema(name, report, ["heifContainer", "isoAuxPresent", "dimsMatch", "noAlpha",
                                           "hdrDecodeSucceeded", "sdrFallbackPresent"])
        iso_present = get(report, "aux", "isoGainMap", "present")
        hdr_aux_present = get(report, "aux", "hdrGainMap", "present")
        check(f"{name}: ISO gain-map aux present in this file (observed reality; task brief expected absent)",
              iso_present is True, f"iso={iso_present}")
        check(f"{name}: Apple HDRGainMap aux present", hdr_aux_present is True, f"hdrGainMap={hdr_aux_present}")
        check(f"{name}: DecodeToHDR succeeded", get(report, "hdrDecode", "success") is True)
        check(f"{name}: HDR decode is 10bpc", get(report, "hdrDecode", "bitsPerComponent") == 10)
        check(f"{name}: HDR contentHeadroom ~5.5356x",
              approx(get(report, "hdrDecode", "contentHeadroom"), 5.5356, 0.01),
              str(get(report, "hdrDecode", "contentHeadroom")))
        check(f"{name}: measured peak > 5.0",
              (get(report, "hdrDecode", "measured", "peak") or 0) > 5.0,
              str(get(report, "hdrDecode", "measured", "peak")))
        check(f"{name}: no alpha in the SDR base", get(report, "sdrDecode", "hasAlpha") is False)
        check(f"{name}: dimensions 4032x3024",
              (get(report, "sdrDecode", "width"), get(report, "sdrDecode", "height")) == (4032, 3024))
        check(f"{name}: container item count > 1 (hybrid: tiles + tmap + aux items)",
              (get(report, "container", "itemCount") or 0) > 1)
        check(f"{name}: overall pass (all applicable checks pass)", get(report, "overall", "pass") is True,
              str(get(report, "overall", "failures")))
        check(f"{name}: exit code 0", exit_code(name) == 0, str(exit_code(name)))
        check(f"{name}: ISO gain-map metadata tags parsed",
              isinstance(get(report, "aux", "isoGainMap", "metadata", "tags"), list)
              and len(get(report, "aux", "isoGainMap", "metadata", "tags")) > 0)
        check(f"{name}: ISO gain-map AlternateHeadroom metadata",
              approx(get(report, "aux", "isoGainMap", "metadata", "gainMap", "alternateHeadroomLinear"),
                     get(report, "hdrDecode", "contentHeadroom"), 0.01))

    # ------------------------------------------------------------------ synthetic tmap (main M0 run)
    name = "synth-out-b-r25"
    report = load(name)
    check("synthetic main report exists", report is not None)
    if report:
        required = ["heifContainer", "isoAuxPresent", "dimsMatch", "noAlpha", "hdrDecodeSucceeded",
                    "headroomWithin5pct", "basePreserved", "sdrFallbackPresent"]
        check_common_schema(name, report, required)
        check(f"{name}: overall pass", get(report, "overall", "pass") is True,
              str(get(report, "overall", "failures")))
        check(f"{name}: exit code 0", exit_code(name) == 0, str(exit_code(name)))
        check(f"{name}: HEIF container detected", get(report, "checks", "heifContainer", "pass") is True)
        check(f"{name}: ISO aux present", get(report, "aux", "isoGainMap", "present") is True)
        check(f"{name}: tmap item present", get(report, "container", "tmapItemPresent") is True)
        check(f"{name}: tmap brand present", get(report, "container", "tmapBrandPresent") is True)
        check(f"{name}: tmap dialect total items 12", get(report, "container", "itemCount") == 12,
              str(get(report, "container", "itemCount")))
        check(f"{name}: ISO aux map is full resolution 1024x768",
              (get(report, "aux", "isoGainMap", "auxWidth"), get(report, "aux", "isoGainMap", "auxHeight")) == (1024, 768))
        check(f"{name}: ISO aux pixel format is 420f",
              get(report, "aux", "isoGainMap", "pixelFormat", "fourCC") == "420f")
        check(f"{name}: ISO aux raw data omitted by ImageIO (observed 420f quirk)",
              "dataOmittedByImageIO" in (get(report, "aux", "isoGainMap") or {}))
        gain_map = get(report, "aux", "isoGainMap", "metadata", "gainMap") or {}
        check(f"{name}: ISO 3-channel gain map (ISO RGB map)", gain_map.get("channelCount") == 3)
        check(f"{name}: ISO GainMapMax present", gain_map.get("gainMapMax") is not None)
        check(f"{name}: ISO GainMapMin present", gain_map.get("gainMapMin") is not None)
        check(f"{name}: ISO Gamma present", gain_map.get("gamma") is not None)
        check(f"{name}: ISO BaseColorIsWorkingColor present", "BaseColorIsWorkingColor" in gain_map)
        check(f"{name}: AlternateHeadroom linear ~4.0",
              approx(gain_map.get("alternateHeadroomLinear"), 4.0, 0.05),
              str(gain_map.get("alternateHeadroomLinear")))
        check(f"{name}: hdrDecode succeeded", get(report, "hdrDecode", "success") is True)
        check(f"{name}: hdrDecode 10bpc", get(report, "hdrDecode", "bitsPerComponent") == 10)
        check(f"{name}: hdrDecode contentHeadroom ~4.0",
              approx(get(report, "hdrDecode", "contentHeadroom"), 4.0, 0.05),
              str(get(report, "hdrDecode", "contentHeadroom")))
        check(f"{name}: measured peak ~4.0",
              approx(get(report, "hdrDecode", "measured", "peak"), 4.0, 0.05),
              str(get(report, "hdrDecode", "measured", "peak")))
        check(f"{name}: fractionAboveOne > 0.70",
              (get(report, "hdrDecode", "measured", "fractionAboveOne") or 0) > 0.70,
              str(get(report, "hdrDecode", "measured", "fractionAboveOne")))
        check(f"{name}: headroomWithin5pct passed", get(report, "checks", "headroomWithin5pct", "pass") is True)
        check(f"{name}: no alpha (sdr + hdr)",
              get(report, "sdrDecode", "hasAlpha") is False and get(report, "hdrDecode", "hasAlpha") is False)
        base_check = report.get("baseCheck", {})
        per_channel = base_check.get("perChannel") or {}
        for channel in ("r", "g", "b"):
            for key in ("meanAbsDiff", "maxAbsDiff", "fractionNonZero"):
                check(f"{name}: baseCheck.perChannel.{channel}.{key}", key in (per_channel.get(channel) or {}))
        check(f"{name}: baseCheck available", base_check.get("available") is True)
        check(f"{name}: baseMode is uniform", base_check.get("baseMode") == "uniform")
        check(f"{name}: baseThresholds.baseMode is uniform",
              get(report, "checks", "basePreserved", "baseThresholds", "baseMode") == "uniform")
        check(f"{name}: baseCheck.percentiles reported",
              all(key in (base_check.get("percentiles") or {}) for key in ("p50", "p90", "p99", "p99_9", "max")))
        check(f"{name}: uniform base p99 == 0", (base_check.get("percentiles") or {}).get("p99") == 0)
        check(f"{name}: uniform base preserved: decoded variance == 0",
              base_check.get("decodedBaseVariance", {}).get("overall") == 0,
              str(base_check.get("decodedBaseVariance", {}).get("overall")))
        check(f"{name}: baseCheck meanAbsDiff == 0", base_check.get("meanAbsDiff") == 0,
              str(base_check.get("meanAbsDiff")))
        check(f"{name}: baseCheck maxAbsDiff == 0", base_check.get("maxAbsDiff") == 0,
              str(base_check.get("maxAbsDiff")))
        check(f"{name}: basePreserved passed", get(report, "checks", "basePreserved", "pass") is True)

    # ------------------------------------------------------------------ other synthetic encoder runs
    for name, expects_headroom in (("synth-out-b-r15", None),
                                   ("synth-out-b-r6", None),
                                   ("synth-out-b-r25-H", None),
                                   ("synth-out-nob-r25", None)):
        report = load(name)
        if report is None:
            print(f"  SKIP  {name} (report not produced)")
            continue
        check(f"{name}: ISO aux present", get(report, "aux", "isoGainMap", "present") is True)
        check(f"{name}: DecodeToHDR succeeded", get(report, "hdrDecode", "success") is True)
        check(f"{name}: report written", True)
        headroom = get(report, "aux", "isoGainMap", "metadata", "gainMap", "alternateHeadroomLinear")
        print(f"        {name}: aux map {get(report,'aux','isoGainMap','auxWidth')}x{get(report,'aux','isoGainMap','auxHeight')}, "
              f"linear headroom {headroom}, hdr bpc {get(report,'hdrDecode','bitsPerComponent')}, "
              f"alpha {get(report,'sdrDecode','hasAlpha')}, exit {exit_code(name)}")

    # ------------------------------------------------------------------ negative: plain SDR HEIC
    name = "negative-sdr-p3"
    report = load(name)
    check("negative plain-SDR report exists", report is not None)
    if report:
        check_common_schema(name, report, ["isoAuxPresent", "noAlpha", "sdrFallbackPresent"])
        check(f"{name}: ISO aux absent", get(report, "aux", "isoGainMap", "present") is False)
        check(f"{name}: HDRGainMap aux absent", get(report, "aux", "hdrGainMap", "present") is False)
        check(f"{name}: HEIF container detected", get(report, "checks", "heifContainer", "pass") is True)
        check(f"{name}: sdrFallbackPresent passed", get(report, "checks", "sdrFallbackPresent", "pass") is True)
        check(f"{name}: noAlpha passed", get(report, "checks", "noAlpha", "pass") is True)
        check(f"{name}: isoAuxPresent failed", get(report, "checks", "isoAuxPresent", "pass") is False)
        check(f"{name}: overall fails", get(report, "overall", "pass") is False)
        check(f"{name}: exit code 1", exit_code(name) == 1, str(exit_code(name)))
        check(f"{name}: failures list names isoAuxPresent",
              any("isoAuxPresent" in failure for failure in get(report, "overall", "failures") or []))
        check(f"{name}: DecodeToHDR on SDR-only file returns SDR content",
              get(report, "hdrDecode", "isHDRContent") is False,
              str(get(report, "hdrDecode", "isHDRContent")))

    # ------------------------------------------------------------------ negative: uniform base, baseCheck path
    name = "negative-uniform-base"
    report = load(name)
    check("uniform-base report exists", report is not None)
    if report:
        base_check = report.get("baseCheck", {})
        check(f"{name}: baseCheck available", base_check.get("available") is True)
        check(f"{name}: supplied base detected as uniform", base_check.get("baseUniform") is True)
        check(f"{name}: baseMode is uniform", base_check.get("baseMode") == "uniform")
        check(f"{name}: uniform rule is strict: decoded variance == 0",
              base_check.get("decodedBaseVariance", {}).get("overall") == 0,
              str(base_check.get("decodedBaseVariance", {}).get("overall")))
        check(f"{name}: uniform rule is strict: meanAbsDiff == 0", base_check.get("meanAbsDiff") == 0,
              str(base_check.get("meanAbsDiff")))
        check(f"{name}: uniform rule is strict: maxAbsDiff == 0", base_check.get("maxAbsDiff") == 0,
              str(base_check.get("maxAbsDiff")))
        check(f"{name}: uniform pass rule recorded",
              "== 0" in get(report, "checks", "basePreserved", "baseThresholds", "passRule"),
              str(get(report, "checks", "basePreserved", "baseThresholds", "passRule")))
        check(f"{name}: basePreserved passed", get(report, "checks", "basePreserved", "pass") is True)
        check(f"{name}: overall still fails (no gain map)", get(report, "overall", "pass") is False)
        check(f"{name}: exit code 1", exit_code(name) == 1, str(exit_code(name)))

    # ------------------------------------------------------------------ negative: non-uniform base comparison (lossy HEIC)
    name = "negative-sdr-p3-base"
    report = load(name)
    if report:
        base_check = report.get("baseCheck", {})
        check(f"{name}: non-uniform baseCheck available", base_check.get("available") is True)
        check(f"{name}: baseMode is photo", base_check.get("baseMode") == "photo")
        check(f"{name}: photo pass rule recorded",
              get(report, "checks", "basePreserved", "baseThresholds", "baseMode") == "photo")
        check(f"{name}: meanAbsDiff <= 1 for same-source lossy HEIC",
              (base_check.get("meanAbsDiff") or 1) <= 1.0,
              str(base_check.get("meanAbsDiff")))
        check(f"{name}: diffHistogram recorded",
              isinstance(base_check.get("diffHistogram"), dict))
        print(f"        {name}: meanAbsDiff={base_check.get('meanAbsDiff')} "
              f"maxAbsDiff={base_check.get('maxAbsDiff')} "
              f"fractionAboveTwo={base_check.get('fractionAboveTwo')} (lossy HEVC chroma subsampling)")

    # ------------------------------------------------------------------ alpha differences
    name = "alpha-diff"
    report = load(name)
    check("alpha-diff report exists (verifier did not crash on alpha)", report is not None)
    if report:
        check(f"{name}: SDR decode has alpha=true", get(report, "sdrDecode", "hasAlpha") is True)
        check(f"{name}: noAlpha check failed (as expected)", get(report, "checks", "noAlpha", "pass") is False)
        base_check = report.get("baseCheck", {})
        check(f"{name}: baseCheck still ran with mixed alpha", base_check.get("available") is True)
        check(f"{name}: baseMode is photo", base_check.get("baseMode") == "photo")
        check(f"{name}: alpha difference reported, not fatal",
              isinstance(base_check.get("alphaNote"), str) and "alpha differs" in base_check.get("alphaNote", ""),
              str(base_check.get("alphaNote")))
        check(f"{name}: report JSON is valid", True)

    # ------------------------------------------------------------------ headroom mismatch (threshold path)
    name = "headroom-mismatch"
    report = load(name)
    check("headroom-mismatch report exists", report is not None)
    if report:
        check(f"{name}: headroomWithin5pct failed for expected 2.5 vs actual ~4.0",
              get(report, "checks", "headroomWithin5pct", "pass") is False)
        check(f"{name}: relativeError > 0.05",
              (get(report, "checks", "headroomWithin5pct", "relativeError") or 0) > 0.05)
        check(f"{name}: overall fails", get(report, "overall", "pass") is False)
        check(f"{name}: exit code 1", exit_code(name) == 1, str(exit_code(name)))

    # ------------------------------------------------------------------ non-HEIF input rejection
    name = "non-heif-jpeg"
    report = load(name)
    if report is None:
        print("  SKIP  non-heif-jpeg (samples/reference/IMG_7473.JPG not available)")
    else:
        check(f"{name}: not treated as an ISO BMFF container",
              get(report, "container", "isISOBaseMedia") is False)
        check(f"{name}: heifContainer check failed", get(report, "checks", "heifContainer", "pass") is False)
        check(f"{name}: overall fails for a non-HEIC input", get(report, "overall", "pass") is False)
        check(f"{name}: exit code 1", exit_code(name) == 1, str(exit_code(name)))
        print(f"        {name}: ImageIO reports isoAux={get(report,'aux','isoGainMap','present')}, "
              f"hdrDecode={get(report,'hdrDecode','success')}, "
              f"contentHeadroom={get(report,'hdrDecode','contentHeadroom')} "
              f"(JPEG gain-map files are rejected by the HEIF check)")

    # ------------------------------------------------------------------ CLI failure paths
    check("missing-file exit code 1", exit_code("missing-file") == 1, str(exit_code("missing-file")))
    check("no-args exit code 1 (usage error)", exit_code("no-args") == 1, str(exit_code("no-args")))

    # ------------------------------------------------------------------ real pair (only if that teammate has produced output)
    real_reports = sorted(glob.glob(os.path.join(REPORTS, "real-*.json")))
    if not real_reports:
        print("  SKIP  real-pair outputs not available yet")
    for path in real_reports:
        with open(path) as handle:
            report = json.load(handle)
        name = os.path.basename(path)[:-5]
        base_check = report.get("baseCheck") or {}
        print(f"  INFO  {name}: iso={get(report,'aux','isoGainMap','present')} "
              f"headroom={get(report,'hdrDecode','contentHeadroom')} "
              f"peak={get(report,'hdrDecode','measured','peak')} "
              f"alpha={get(report,'sdrDecode','hasAlpha')} "
              f"overall={get(report,'overall','pass')}")
        if base_check.get("available"):
            percentiles = base_check.get("percentiles") or {}
            print(f"        {name}: base mode={base_check.get('baseMode')} "
                  f"meanAbsDiff={base_check.get('meanAbsDiff')} "
                  f"meanSignedDiff={base_check.get('meanSignedDiff')} "
                  f"p99={percentiles.get('p99')} p99.9={percentiles.get('p99_9')} "
                  f"maxAbsDiff={base_check.get('maxAbsDiff')} "
                  f"decodedVariance={get(base_check,'decodedBaseVariance','overall')} "
                  f"uniform={base_check.get('baseUniform')}")
            mode = base_check.get("baseMode")
            check(f"{name}: baseMode recorded", mode in ("uniform", "photo"), str(mode))
            check(f"{name}: percentiles reported",
                  all(key in percentiles for key in ("p50", "p90", "p99", "p99_9", "max")))
            check(f"{name}: check.baseMode matches baseCheck.baseMode",
                  get(report, "checks", "basePreserved", "baseMode") == mode)
            if mode == "photo":
                check(f"{name}: photo rule p99 <= 16", (percentiles.get("p99") or 99) <= 16,
                      str(percentiles.get("p99")))
                check(f"{name}: photo rule |meanSignedDiff| <= 0.5",
                      abs(base_check.get("meanSignedDiff") or 0) <= 0.5,
                      str(base_check.get("meanSignedDiff")))
                check(f"{name}: photo rule meanAbsDiff <= 2.5",
                      (base_check.get("meanAbsDiff") or 99) <= 2.5,
                      str(base_check.get("meanAbsDiff")))
            check(f"{name}: basePreserved passed", get(report, "checks", "basePreserved", "pass") is True)
            print(f"        {name}: basePreserved={get(report, 'checks', 'basePreserved', 'pass')} "
                  f"baseThresholds={json.dumps(get(report, 'checks', 'basePreserved', 'baseThresholds'))}")
        check(f"{name}: HEIF container detected", get(report, "checks", "heifContainer", "pass") is True)
        check(f"{name}: HDR decode request succeeded", get(report, "hdrDecode", "success") is True)
        if "-vs-sdrheic" in name:
            check(f"{name}: ISO aux present", get(report, "aux", "isoGainMap", "present") is True)
            check(f"{name}: overall pass (main base matches SDR reference within codec loss)",
                  get(report, "overall", "pass") is True, str(get(report, "overall", "failures")))
            mean_abs = base_check.get("meanAbsDiff")
            check(f"{name}: main HEIC SDR decode is close to the SDR-only HEIC (meanAbsDiff <= 2)",
                  isinstance(mean_abs, (int, float)) and mean_abs <= 2.0,
                  str(mean_abs))
            check(f"{name}: no re-tone-map bias (|meanSignedDiff| <= 0.5)",
                  abs(base_check.get("meanSignedDiff") or 0) <= 0.5,
                  str(base_check.get("meanSignedDiff")))
        elif "-sdr" in name:
            check(f"{name}: map-stripped SDR reference has no gain map",
                  get(report, "aux", "isoGainMap", "present") is False)
            check(f"{name}: map-stripped SDR reference plain decode works",
                  get(report, "checks", "sdrFallbackPresent", "pass") is True)
            check(f"{name}: map-stripped SDR reference overall fails (negative control)",
                  get(report, "overall", "pass") is False)
        else:
            check(f"{name}: ISO aux present", get(report, "aux", "isoGainMap", "present") is True)
            check(f"{name}: no alpha", get(report, "checks", "noAlpha", "pass") is True)
            check(f"{name}: overall pass", get(report, "overall", "pass") is True,
                  str(get(report, "overall", "failures")))
            if "-full-final" in name:
                check(f"{name}: exit code 0", exit_code(name) == 0, str(exit_code(name)))
                check(f"{name}: expected headroomWithin5pct passed",
                      get(report, "checks", "headroomWithin5pct", "pass") is True)

    print()
    if failures:
        print(f"RESULT: FAIL ({len(failures)}/{checks} assertions failed)")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print(f"RESULT: PASS ({checks} assertions)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
