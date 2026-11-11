#!/usr/bin/env python3
"""LAN static server for the M5 viewer check (visual-check).

Serves the embedded viewer page for ``/`` and the files of ``--root`` for
``/files/<name>``, plus a freshly generated ``/manifest.json`` that classifies
the folder by file-name convention.

    python3 serve.py [--root DIR] [--port 8765] [--bind 0.0.0.0]

Plain HTTP on a trusted LAN only: no TLS, no authentication, no Bonjour.
HEIC is sent as ``image/heic`` (Python's ``mimetypes`` does not know it) and
every response carries ``Cache-Control: no-store``. The viewer only displays;
it does not decode or rewrite the gain map.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import socket
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote, urlsplit

NAME = "visual-check"
VERSION = "0.1.0"
DEFAULT_PORT = 8765
INDEX_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html")

IMAGE_EXTENSIONS = (".heic", ".heif", ".jpg", ".jpeg", ".png")
MIME_TYPES = {
    ".heic": "image/heic",
    ".heif": "image/heic",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".json": "application/json",
    ".html": "text/html",
    ".txt": "text/plain; charset=utf-8",
    ".md": "text/markdown; charset=utf-8",
}


# ---------------------------------------------------------------------------
# Manifest


# v2 names one HDR file per output profile: {stem}-hdr-{profile}.heic with the profile spelled
# {depth}-{full|half}-{rgb|mono} (e.g. R0003777-P3-hdr-10-half-rgb.heic). The v1
# {stem}-hdr.heic single-file shape stays recognised so historical folders still render.
HDR_PROFILE_HEIC = re.compile(r"-hdr-\d+-(?:full|half)-(?:rgb|mono)\.heic$")


def classify(name: str) -> str | None:
    """Classify a file name by the delivery folder convention (case-insensitive)."""
    lowered = name.lower()
    if lowered.endswith(".report.json"):
        return "report"
    if lowered.endswith(".recipe.json"):
        return "recipe"
    if lowered.endswith("-hdr.heic") or HDR_PROFILE_HEIC.search(lowered):
        return "hdr"
    if lowered.endswith("-sdr.heic"):
        return "sdr"
    if lowered.endswith(IMAGE_EXTENSIONS):
        return "reference"
    return None


def _number(value):
    # DeliveryReport measured values are tagged unions: {"type": "number", "value": 2.5}.
    if isinstance(value, dict) and value.get("type") in ("number", "integer") and "value" in value:
        value = value["value"]
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value


def _find_key(obj, wanted: tuple[str, ...], depth: int = 0):
    """Return (key, value) for the first occurrence of a wanted key (depth-first)."""
    if depth > 8 or not isinstance(obj, (dict, list)):
        return None
    if isinstance(obj, dict):
        for key, value in obj.items():
            if key in wanted:
                return key, value
        children = obj.values()
    else:
        children = obj
    for child in children:
        found = _find_key(child, wanted, depth + 1)
        if found is not None:
            return found
    return None


def _first_number(mapping: dict, keys: tuple[str, ...]):
    for key in keys:
        number = _number(mapping.get(key))
        if number is not None:
            return number
    return None


def _fuzzy_number(mapping: dict, token: str):
    """Last resort for a report whose measured-key spelling is not fixed yet."""
    for key, candidate in mapping.items():
        if token in key.lower():
            number = _number(candidate)
            if number is not None:
                return number
    return None


def _normalise_status(check: dict) -> str:
    status = check.get("status")
    if isinstance(status, str) and status:
        normalised = status.strip().lower()
        if normalised in ("pass", "passed", "ok"):
            return "PASS"
        if normalised in ("fail", "failed", "error"):
            return "FAIL"
        if normalised in ("skip", "skipped", "not_applicable", "n/a"):
            return "SKIP"
        return status.strip().upper()
    passed = check.get("pass", check.get("passed"))
    if passed is True:
        return "PASS"
    if passed is False:
        return "FAIL"
    return "UNKNOWN"


def _normalise_checks(raw: dict) -> list[dict]:
    checks = raw.get("checks")
    out: list[dict] = []
    if isinstance(checks, dict):
        for check_name in sorted(checks):
            value = checks[check_name]
            if isinstance(value, dict):
                out.append(
                    {
                        "name": check_name,
                        "status": _normalise_status(value),
                        "detail": str(value.get("detail") or value.get("message") or ""),
                    }
                )
            elif isinstance(value, bool):
                out.append(
                    {
                        "name": check_name,
                        "status": "PASS" if value else "FAIL",
                        "detail": "",
                    }
                )
            elif isinstance(value, str):
                out.append(
                    {
                        "name": check_name,
                        "status": _normalise_status({"status": value}),
                        "detail": "",
                    }
                )
    elif isinstance(checks, list):
        for value in checks:
            if not isinstance(value, dict):
                continue
            check_name = str(value.get("name") or value.get("check") or "unnamed")
            out.append(
                {
                    "name": check_name,
                    "status": _normalise_status(value),
                    "detail": str(value.get("detail") or value.get("message") or ""),
                }
            )
    return out


def _report_verdict(raw: dict) -> tuple[str, bool | None]:
    """Return (verdict text, pass flag or None) for either report shape."""
    candidates = [
        raw.get("verdict"),
        raw.get("pass") if isinstance(raw.get("pass"), bool) else None,
        raw.get("overall", {}).get("verdict") if isinstance(raw.get("overall"), dict) else None,
        raw.get("overall", {}).get("pass") if isinstance(raw.get("overall"), dict) else None,
        raw.get("summary", {}).get("pass") if isinstance(raw.get("summary"), dict) else None,
    ]
    for value in candidates:
        if isinstance(value, bool):
            return ("PASS" if value else "FAIL"), value
        if isinstance(value, str):
            upper = value.strip().upper()
            if upper in ("PASS", "PASSED", "OK"):
                return "PASS", True
            if upper in ("FAIL", "FAILED", "ERROR"):
                return "FAIL", False
            if upper:
                return upper, None
    return "UNKNOWN", None


def _report_headroom(raw: dict) -> dict:
    value, source = None, None
    for path in (
        ("headroom",),
        ("measurements", "headroom"),
        ("hdrDecode", "contentHeadroom"),
        ("hdr", "contentHeadroom"),
        ("container", "contentHeadroom"),
    ):
        candidate = raw
        for key in path:
            candidate = candidate.get(key) if isinstance(candidate, dict) else None
        if isinstance(candidate, dict):
            for key in ("advertised", "contentHeadroom", "linear", "value"):
                number = _number(candidate.get(key))
                if number is not None:
                    value, source = number, ".".join(path + (key,))
                    break
        else:
            number = _number(candidate)
            if number is not None:
                value, source = number, ".".join(path)
        if value is not None:
            break
    if value is None:
        # DeliveryReport schema 0: the headroom check carries the advertised value in
        # `measured` (tagged number); fall back to the authored cap when it is not exposed.
        found = _find_key(raw, ("contentHeadroom", "advertisedHeadroom", "advertisedContentHeadroom"))
        if found is not None:
            number = _number(found[1])
            if number is not None:
                value, source = number, found[0]
    if value is None:
        for path in (("render", "headroomCap"), ("recipe", "headroomCap")):
            candidate = raw
            for key in path:
                candidate = candidate.get(key) if isinstance(candidate, dict) else None
            number = _number(candidate)
            if number is not None:
                value, source = number, ".".join(path)
                break
    return {"advertised": value, "source": source}


def _report_authored_peak(raw: dict):
    found = _find_key(raw, ("authoredPeak", "authoredPeakLinear", "preEncodePeak", "authored_peak"))
    return _number(found[1]) if found is not None else None


def _check_named(raw: dict, name: str) -> dict | None:
    checks = raw.get("checks")
    if isinstance(checks, dict):
        value = checks.get(name)
        return value if isinstance(value, dict) else None
    if isinstance(checks, list):
        for value in checks:
            if isinstance(value, dict) and value.get("name") == name:
                return value
    return None


def _report_base_delta_e(raw: dict) -> dict | None:
    found = _find_key(raw, ("baseDeltaE", "deltaE", "baseDeltaE2000"))
    value = found[1] if found is not None else None
    if not isinstance(value, dict):
        # DeliveryReport schema 0: the numbers live in the baseDeltaE check's `measured`.
        check = _check_named(raw, "baseDeltaE")
        if check is not None and isinstance(check.get("measured"), dict):
            value = check["measured"]
    if not isinstance(value, dict):
        # DeliveryReport schema 1: the baseDeltaE check lives inside each profile.
        for profile in raw.get("profiles") or []:
            if not isinstance(profile, dict):
                continue
            check = _check_named(profile, "baseDeltaE")
            if check is not None and isinstance(check.get("measured"), dict):
                value = check["measured"]
                break
    if isinstance(value, dict):
        mean = _first_number(value, ("mean", "meanDE", "meanDeltaE", "dE2000Mean", "meanDE2000"))
        p95 = _first_number(value, ("p95", "p95DE", "p95DeltaE", "dE2000P95", "p95DE2000"))
        if mean is None:
            mean = _fuzzy_number(value, "mean")
        if p95 is None:
            p95 = _fuzzy_number(value, "p95")
        if mean is None and p95 is None:
            return None
        return {"mean": mean, "p95": p95}
    number = _number(value)
    return {"mean": number, "p95": None} if number is not None else None


def _report_sizes(raw: dict) -> dict | None:
    # DeliveryReport schema 0: artifacts.{hdrHEIC,sdrHEIC,recipeJSON}.bytes. Schema 1 keeps the
    # same artifact shape per profile; the first profile's sizes stand for the summary (the
    # sdr/recipe artifacts are shared, and per-profile detail is in `profiles`).
    artifacts = raw.get("artifacts")
    if not isinstance(artifacts, dict):
        for profile in raw.get("profiles") or []:
            if isinstance(profile, dict) and isinstance(profile.get("artifacts"), dict):
                artifacts = profile["artifacts"]
                break
    if isinstance(artifacts, dict):
        sizes = {}
        for label, key in (("hdrBytes", "hdrHEIC"), ("sdrBytes", "sdrHEIC"), ("recipeBytes", "recipeJSON")):
            artifact = artifacts.get(key)
            if isinstance(artifact, dict):
                number = _number(artifact.get("bytes"))
                if number is not None:
                    sizes[label] = number
        if sizes:
            return sizes
    for key in ("sizes", "sizeBytes"):
        value = raw.get(key)
        if isinstance(value, dict):
            return {str(k): _number(v) if _number(v) is not None else v for k, v in value.items()}
        number = _number(value)
        if number is not None:
            return {"totalBytes": number}
    found = _find_key(raw, ("hdrBytes", "heicBytes"))
    if found is not None and _number(found[1]) is not None:
        return {found[0]: found[1]}
    return None


def _report_timings(raw: dict) -> dict | None:
    found = _find_key(raw, ("timings", "timingsSeconds"))
    if found is None or not isinstance(found[1], dict):
        return None
    timings = {}
    for key, value in found[1].items():
        number = _number(value)
        timings[str(key)] = number if number is not None else value
    return timings


def _url_for(name: str) -> str:
    return "/files/" + quote(name, safe="")


def summarise_report(path: str, name: str, raw: str) -> dict:
    """Small, stable report summary for the page; the full JSON stays linked."""
    stat = os.stat(path)
    summary = {
        "name": name,
        "url": _url_for(name),
        "bytes": stat.st_size,
        "mtime": _iso_mtime(stat.st_mtime),
        "schema": None,
        "verdict": "UNREADABLE",
        "pass": None,
        "checks": [],
        "profiles": None,
        "renderKey": None,
        "sha256": None,
        "headroom": {"advertised": None, "source": None},
        "authoredPeak": None,
        "baseDeltaE": None,
        "sizes": None,
        "timings": None,
    }
    try:
        parsed = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        summary["error"] = "report is not valid JSON"
        return summary
    if not isinstance(parsed, dict):
        summary["error"] = "report JSON is not an object"
        return summary
    verdict, passed = _report_verdict(parsed)
    summary["schema"] = parsed.get("schema")
    summary["verdict"] = verdict
    summary["pass"] = passed
    profiles = parsed.get("profiles")
    if isinstance(profiles, list) and profiles:
        # DeliveryReport schema 1: one group per output profile, each with its own checks/pass;
        # the top-level pass is the AND of every profile. The flat `checks` list keeps the page
        # working: names are prefixed with the profile when there is more than one.
        groups = []
        flat_checks = []
        for profile in profiles:
            if not isinstance(profile, dict):
                continue
            reference = profile.get("profile")
            group_name = reference.get("name") if isinstance(reference, dict) else None
            name = str(group_name) if group_name else "unnamed"
            checks = _normalise_checks(profile)
            groups.append(
                {
                    "name": name,
                    "pass": profile.get("pass") is True,
                    "failures": [str(f) for f in profile.get("failures") or []],
                    "checks": checks,
                }
            )
            for check in checks:
                flat = dict(check)
                flat["profile"] = name
                if len(profiles) > 1:
                    flat["name"] = f"{name}: {check['name']}"
                flat_checks.append(flat)
        summary["profiles"] = groups
        summary["checks"] = flat_checks
    else:
        summary["checks"] = _normalise_checks(parsed)
    render_key = _find_key(parsed, ("renderKey",))
    if render_key is not None and isinstance(render_key[1], str):
        summary["renderKey"] = render_key[1]
    sha = parsed.get("sha256")
    if not isinstance(sha, str):
        # DeliveryReport schema 0: artifacts.hdrHEIC.sha256 is the delivered HEIC's hash.
        artifacts = parsed.get("artifacts")
        hdr_artifact = artifacts.get("hdrHEIC") if isinstance(artifacts, dict) else None
        if isinstance(hdr_artifact, dict) and isinstance(hdr_artifact.get("sha256"), str):
            sha = hdr_artifact["sha256"]
    if not isinstance(sha, str):
        # DeliveryReport schema 1: the artifacts live inside each profile.
        for profile in parsed.get("profiles") or []:
            if not isinstance(profile, dict):
                continue
            artifacts = profile.get("artifacts")
            hdr_artifact = artifacts.get("hdrHEIC") if isinstance(artifacts, dict) else None
            if isinstance(hdr_artifact, dict) and isinstance(hdr_artifact.get("sha256"), str):
                sha = hdr_artifact["sha256"]
                break
    if not isinstance(sha, str):
        found = _find_key(parsed, ("sha256", "heicSha256"))
        sha = found[1] if found is not None and isinstance(found[1], str) else None
    summary["sha256"] = sha
    summary["headroom"] = _report_headroom(parsed)
    summary["authoredPeak"] = _report_authored_peak(parsed)
    summary["baseDeltaE"] = _report_base_delta_e(parsed)
    summary["sizes"] = _report_sizes(parsed)
    summary["timings"] = _report_timings(parsed)
    return summary


def _iso_mtime(timestamp: float) -> str:
    return datetime.datetime.fromtimestamp(timestamp, datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def _iso_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def build_manifest(root: str) -> dict:
    """Build the manifest for one request (never cached)."""
    entries: list[dict] = []
    report: dict | None = None
    recipe: dict | None = None

    names = sorted(
        (name for name in os.listdir(root) if not name.startswith(".")),
        key=lambda name: name.lower(),
    )
    for name in names:
        path = os.path.join(root, name)
        if not os.path.isfile(path):
            continue
        kind = classify(name)
        if kind is None:
            continue
        stat = os.stat(path)
        entry = {
            "name": name,
            "url": _url_for(name),
            "kind": kind,
            "bytes": stat.st_size,
            "mtime": _iso_mtime(stat.st_mtime),
        }
        if kind == "report":
            if report is None:
                try:
                    with open(path, "r", encoding="utf-8") as handle:
                        raw = handle.read()
                except OSError:
                    raw = ""
                report = summarise_report(path, name, raw)
        elif kind == "recipe":
            if recipe is None:
                try:
                    with open(path, "r", encoding="utf-8") as handle:
                        parsed = json.loads(handle.read())
                except (OSError, ValueError, UnicodeDecodeError):
                    parsed = None
                recipe = {
                    "name": name,
                    "url": _url_for(name),
                    "bytes": stat.st_size,
                    "mtime": _iso_mtime(stat.st_mtime),
                    "json": parsed,
                }
        else:
            entries.append(entry)

    manifest = {
        "generatedAt": _iso_now(),
        "server": {"name": NAME, "version": VERSION},
        "root": os.path.basename(os.path.abspath(root)),
        "entries": entries,
    }
    if report is not None:
        manifest["report"] = report
    if recipe is not None:
        manifest["recipe"] = recipe
    return manifest


# ---------------------------------------------------------------------------
# HTTP handler


class VisualCheckHandler(BaseHTTPRequestHandler):
    server_version = f"{NAME}/{VERSION}"
    sys_version = ""
    protocol_version = "HTTP/1.1"
    root = ""

    def version_string(self) -> str:
        return self.server_version

    # Every response, including errors, is uncached and non-sniffable.
    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        super().end_headers()

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("[visual-check] " + (fmt % args) + "\n")

    # -- routing ---------------------------------------------------------

    def do_GET(self) -> None:
        self._route(head=False)

    def do_HEAD(self) -> None:
        self._route(head=True)

    def _route(self, head: bool) -> None:
        path = urlsplit(self.path).path
        if path in ("/", "/index.html"):
            self._send_index(head)
        elif path == "/manifest.json":
            self._send_manifest(head)
        elif path.startswith("/files/"):
            self._send_file(path[len("/files/") :], head)
        else:
            self._send_text(HTTPStatus.NOT_FOUND, f"404 not found: {path}\n", head=head)

    # -- responses -------------------------------------------------------

    def _send_index(self, head: bool) -> None:
        try:
            with open(INDEX_PATH, "rb") as handle:
                body = handle.read()
        except OSError as error:
            self._send_text(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                f"500 index.html missing next to serve.py: {error}\n",
                head=head,
            )
            return
        self._send_bytes(HTTPStatus.OK, "text/html; charset=utf-8", body, head)

    def _send_manifest(self, head: bool) -> None:
        try:
            manifest = build_manifest(self.root)
        except OSError as error:
            self._send_text(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                f"500 cannot read --root {self.root}: {error}\n",
                head=head,
            )
            return
        body = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        self._send_bytes(HTTPStatus.OK, "application/json; charset=utf-8", body, head)

    def _send_file(self, raw_name: str, head: bool) -> None:
        name = unquote(raw_name)
        resolved = self._resolve(name)
        if resolved is None:
            self._send_text(
                HTTPStatus.NOT_FOUND,
                f"404 not found: {raw_name or '(empty)'} (only flat files inside --root are served)\n",
                head=head,
            )
            return
        try:
            stat = os.stat(resolved)
            handle = open(resolved, "rb")
        except OSError as error:
            self._send_text(HTTPStatus.NOT_FOUND, f"404 not found: {error}\n", head=head)
            return
        with handle:
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", mime_type_for(resolved))
            self.send_header("Content-Length", str(stat.st_size))
            self.end_headers()
            if not head:
                shutil.copyfileobj(handle, self.wfile)

    def _resolve(self, name: str):
        """Resolve a flat file name under --root; refuse traversal and hidden files."""
        if not name or name in (".", "..") or "\x00" in name:
            return None
        if name.startswith(".") or "/" in name or "\\" in name:
            return None
        if os.path.basename(name) != name:
            return None
        root_real = os.path.realpath(self.root)
        target = os.path.realpath(os.path.join(root_real, name))
        if os.path.commonpath([root_real, target]) != root_real:
            return None
        if not os.path.isfile(target):
            return None
        return target

    def _send_text(self, status, text: str, head: bool = False, allow: str | None = None) -> None:
        body = text.encode("utf-8")
        self.send_response(status)
        if allow is not None:
            self.send_header("Allow", allow)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not head:
            self.wfile.write(body)

    def _send_bytes(self, status, content_type: str, body: bytes, head: bool) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not head:
            self.wfile.write(body)

    # -- disallowed methods ---------------------------------------------

    def _method_not_allowed(self) -> None:
        self.close_connection = True
        self._send_text(
            HTTPStatus.METHOD_NOT_ALLOWED,
            "405 method not allowed: this server answers GET and HEAD only\n",
            allow="GET, HEAD",
        )

    def send_error(self, code, message=None, explain=None) -> None:
        # BaseHTTPRequestHandler answers an unknown method with 501; this server
        # rejects every non-GET/HEAD method with 405 instead.
        if code == HTTPStatus.NOT_IMPLEMENTED and message and message.startswith("Unsupported method"):
            self._method_not_allowed()
            return
        super().send_error(code, message, explain)

    do_POST = _method_not_allowed
    do_PUT = _method_not_allowed
    do_PATCH = _method_not_allowed
    do_DELETE = _method_not_allowed
    do_OPTIONS = _method_not_allowed
    do_TRACE = _method_not_allowed
    do_CONNECT = _method_not_allowed


def mime_type_for(path: str) -> str:
    return MIME_TYPES.get(os.path.splitext(path)[1].lower(), "application/octet-stream")


# ---------------------------------------------------------------------------
# Startup


def lan_ipv4_addresses() -> list[str]:
    """Non-loopback IPv4 addresses, via stdlib only (no ipconfig/getifaddr)."""
    addresses: set[str] = set()
    # connect() on a UDP socket only picks a route; it sends no packets.
    for probe in ("192.0.2.1", "198.51.100.1", "203.0.113.1"):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.connect((probe, 9))
            address = sock.getsockname()[0]
            if address and not address.startswith("127."):
                addresses.add(address)
        except OSError:
            pass
        finally:
            sock.close()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            address = info[4][0]
            if address and not address.startswith("127."):
                addresses.add(address)
    except OSError:
        pass
    # Link-local (169.254/16) is not reachable from the iPad over Wi-Fi.
    return sorted(address for address in addresses if not address.startswith("169.254."))


def print_startup(root: str, bind: str, port: int) -> None:
    print(f"{NAME} {VERSION} — serving {root}", flush=True)
    print(f"  listening on {bind}:{port}", flush=True)
    if bind in ("0.0.0.0", ""):
        addresses = lan_ipv4_addresses()
        if addresses:
            for address in addresses:
                print(f"  LAN: http://{address}:{port}/", flush=True)
            print("  (use the address on the same Wi-Fi as the iPad)", flush=True)
        else:
            print(f"  local: http://127.0.0.1:{port}/", flush=True)
    elif bind.startswith("127.") or bind == "localhost":
        print(f"  local: http://{bind}:{port}/", flush=True)
    else:
        print(f"  LAN: http://{bind}:{port}/", flush=True)
    print(
        "LAN-only viewer: plain HTTP, no authentication, no TLS — trusted networks only.",
        flush=True,
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="serve.py",
        description=(
            "LAN static server for the M5 visual check: serves the viewer page at /, "
            "the --root files at /files/<name>, and a generated /manifest.json."
        ),
        epilog=(
            "Example (from the repo root):\n"
            "  python3 tools/visual-check/serve.py --root out/\n"
            "Then open http://<mac-lan-ip>:8765/ in Safari on the iPad. "
            "Plain HTTP, no auth — trusted LAN only."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--root",
        default=".",
        help="folder to serve under /files/<name> (default: current directory)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=DEFAULT_PORT,
        help=f"TCP port (default: {DEFAULT_PORT}; 0 picks a free port)",
    )
    parser.add_argument(
        "--bind",
        default="0.0.0.0",
        help="interface to bind (default: 0.0.0.0 = all interfaces)",
    )
    args = parser.parse_args(argv)
    if not 0 <= args.port <= 65535:
        parser.error("--port must be between 0 and 65535")
    if not os.path.isdir(args.root):
        parser.error(f"--root is not a directory: {args.root}")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    VisualCheckHandler.root = os.path.realpath(args.root)
    try:
        server = ThreadingHTTPServer((args.bind, args.port), VisualCheckHandler)
    except OSError as error:
        print(f"error: cannot listen on {args.bind}:{args.port}: {error}", file=sys.stderr)
        return 1
    port = server.server_address[1]
    print_startup(VisualCheckHandler.root, args.bind, port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[visual-check] stopped", file=sys.stderr)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
