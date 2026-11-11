#!/usr/bin/env python3
"""Repair relative markdown links broken by manual docs moves and renames.

`make docs-lint` treats every unresolvable relative link as an error.  Moving or
renaming a doc by hand (Finder, `mv`, a rename commit) breaks all links that
pointed at it, and updating them manually is noisy.  This tool finds those dead
links and rewrites them to the target's current location.

Resolution order for one dead target (repo-relative path):

  1. the working-tree delta vs HEAD: a deleted path whose content is now at a
     new path (exact git blob id first, then high-ratio text similarity);
  2. rename history from `git log --diff-filter=R`;
  3. the longest unique path suffix (a moved file keeps its trailing components);
  4. a unique basename, then a unique basename with a numeric/date prefix
     stripped (``00-foo.md`` is still ``foo.md``);
  5. a very conservative fuzzy basename match.

The tool never guesses.  If a target maps to zero or more than one candidate,
it reports the problem, leaves the link untouched, and exits non-zero.  Links
inside fenced code, external links, and fragment-only links are ignored.  The
generated ``docs/README.md`` is skipped; use ``make docs-fix`` to regenerate it
after repairing links.  Everything under ``docs/archive/`` is frozen: live docs
are never rewired to point into it.

Usage:
  python3 tools/docs-fix-links.py            # dry run, print planned edits
  python3 tools/docs-fix-links.py --write    # rewrite dead links in place
  make docs-fix                              # write links + regenerate index
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import os
import posixpath
import re
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from difflib import SequenceMatcher
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent
ARCHIVE_PREFIX = "docs/archive/"
TEXT_SUFFIXES = {".md", ".markdown", ".txt"}
MAX_SIMILARITY_BYTES = 1_000_000
SIMILARITY_THRESHOLD = 0.85
SIMILARITY_MARGIN = 0.10
FUZZY_THRESHOLD = 0.90
FUZZY_MARGIN = 0.12
FUZZY_MIN_NAME = 10
NUMERIC_PREFIX = re.compile(r"^(?:\d{4}[-_])?\d+[-_]+")
TITLE_SUFFIX_RE = re.compile(r'^(.*?)(\s+(?:"[^"]*"|\'[^\']*\'|\([^)]*\)))?$', re.S)


def load_docs_lint():
    """Import docs-lint.py (hyphen in the filename) so the scan scope is shared."""
    path = Path(__file__).resolve().with_name("docs-lint.py")
    spec = importlib.util.spec_from_file_location("_photon_docs_lint", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"error: cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DOCS_LINT = load_docs_lint()


@dataclass
class Resolution:
    new: str | None = None
    candidates: list[str] = field(default_factory=list)
    reason: str = ""


@dataclass
class Fix:
    source: Path
    line: int
    start: int
    end: int
    old: str
    new: str
    label_start: int | None = None
    label_end: int | None = None
    label_new: str | None = None


@dataclass
class Problem:
    source: Path
    line: int
    old: str
    reason: str
    candidates: list[str] = field(default_factory=list)


# ---------------------------------------------------------------- git / files

def run_git(args: list[str], *, text: bool = True):
    try:
        return subprocess.run(
            ["git", *args],
            cwd=ROOT,
            capture_output=True,
            text=text,
        )
    except (OSError, subprocess.SubprocessError):
        return None


def head_blobs() -> dict[str, str]:
    """Map HEAD paths to blob ids.  Empty when HEAD is missing (unborn branch)."""
    proc = run_git(["-c", "core.quotePath=false", "ls-tree", "-r", "-z", "--full-tree", "HEAD"])
    if proc is None or proc.returncode != 0:
        return {}
    blobs = {}
    for record in proc.stdout.split("\0"):
        if not record:
            continue
        meta, sep, path = record.partition("\t")
        if not sep:
            continue
        parts = meta.split()
        if len(parts) >= 3 and parts[1] == "blob":
            blobs[path] = parts[2]
    return blobs


def current_files() -> set[str]:
    """Tracked + untracked non-ignored files that still exist on disk."""
    proc = run_git(
        ["-c", "core.quotePath=false", "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
    )
    paths: set[str] = set()
    if proc is not None and proc.returncode == 0:
        for path in proc.stdout.split("\0"):
            if path and (ROOT / path).is_file():
                paths.add(path)
        return paths

    # Not a git checkout (or git unavailable): walk the tree, skipping local
    # build/scratch directories that are not link targets anyway.
    skip = {".git", "work", "out", "cache", "inbox"}
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [
            d for d in dirnames
            if d not in skip and not d.startswith((".build", ".tmp", ".mc", ".dd", "."))
        ]
        for name in filenames:
            paths.add((Path(dirpath) / name).relative_to(ROOT).as_posix())
    return paths


def blob_oid(path: Path) -> str | None:
    try:
        data = path.read_bytes()
    except OSError:
        return None
    digest = hashlib.sha1()
    digest.update(f"blob {len(data)}\0".encode())
    digest.update(data)
    return digest.hexdigest()


def blob_bytes(oid: str) -> bytes | None:
    proc = run_git(["cat-file", "blob", oid], text=False)
    if proc is None or proc.returncode != 0:
        return None
    return proc.stdout


def text_of(data: bytes) -> str | None:
    if len(data) > MAX_SIMILARITY_BYTES or b"\0" in data:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


# ---------------------------------------------------------------- rename maps

def preferred_match(old: str, candidates: list[str]) -> str | None:
    """Pick one candidate for an exact-content mapping, or None when ambiguous."""
    candidates = sorted(set(candidates))
    if len(candidates) == 1:
        return candidates[0]
    old_base = posixpath.basename(old)
    same_base = [c for c in candidates if posixpath.basename(c) == old_base]
    if len(same_base) == 1:
        return same_base[0]
    if same_base:
        candidates = same_base
    old_parts = old.split("/")
    for n in range(len(old_parts), 0, -1):
        suffix = old_parts[-n:]
        matches = [c for c in candidates if c.split("/")[-n:] == suffix]
        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1:
            candidates = matches
    return None


def delta_map(head: dict[str, str], current: set[str], current_oids: dict[str, str]):
    """Map deleted HEAD paths to current paths with identical content."""
    by_oid: dict[str, list[str]] = defaultdict(list)
    for path, oid in current_oids.items():
        by_oid[oid].append(path)

    mapping: dict[str, str] = {}
    ambiguous: dict[str, list[str]] = {}
    for old, oid in head.items():
        if old in current or (ROOT / old).exists():
            continue
        candidates = by_oid.get(oid, [])
        if not candidates:
            continue
        pick = preferred_match(old, candidates)
        if pick:
            mapping[old] = pick
        else:
            ambiguous[old] = sorted(set(candidates))
    return mapping, ambiguous


def similarity_map(
    head: dict[str, str],
    current: set[str],
    known: dict[str, str],
) -> dict[str, str]:
    """Fallback for a move that also edited the file: high-ratio text match."""
    current_text: dict[str, str] = {}
    for path in current:
        suffix = Path(path).suffix.lower()
        if suffix not in TEXT_SUFFIXES:
            continue
        try:
            if (ROOT / path).stat().st_size > MAX_SIMILARITY_BYTES:
                continue
        except OSError:
            continue
        data = (ROOT / path).read_bytes()
        text = text_of(data)
        if text is not None:
            current_text[path] = text

    mapping: dict[str, str] = {}
    for old, oid in head.items():
        if old in known or old in current or (ROOT / old).exists():
            continue
        if Path(old).suffix.lower() not in TEXT_SUFFIXES:
            continue
        old_text = text_of(blob_bytes(oid) or b"")
        if old_text is None or len(old_text) < 200:
            continue
        scored: list[tuple[float, str]] = []
        for path, new_text in current_text.items():
            if Path(path).suffix.lower() != Path(old).suffix.lower():
                continue
            matcher = SequenceMatcher(None, old_text, new_text, autojunk=False)
            if matcher.real_quick_ratio() < SIMILARITY_THRESHOLD:
                continue
            if matcher.quick_ratio() < SIMILARITY_THRESHOLD:
                continue
            ratio = matcher.ratio()
            if ratio >= SIMILARITY_THRESHOLD:
                scored.append((ratio, path))
        if not scored:
            continue
        scored.sort(reverse=True)
        best = scored[0]
        second = scored[1][0] if len(scored) > 1 else 0.0
        if best[0] - second >= SIMILARITY_MARGIN:
            mapping[old] = best[1]
    return mapping


def history_map() -> dict[str, str]:
    """old path -> new path from every detected rename in git history."""
    proc = run_git(
        [
            "-c", "core.quotePath=false",
            "log", "--all", "--diff-filter=R", "-M", "--name-status", "--pretty=format:",
        ]
    )
    if proc is None or proc.returncode != 0:
        return {}
    mapping: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if not line.startswith("R"):
            continue
        parts = line.split("\t")
        if len(parts) >= 3:
            old, new = parts[-2], parts[-1]
            # Newest commits are read first; keep the first edge seen for a path,
            # then follow the chain to the current location.
            mapping.setdefault(old, new)
    return mapping


def follow(path: str, *mappings: dict[str, str]) -> str | None:
    current = path
    seen: set[str] = set()
    while True:
        if current in seen:
            return None
        seen.add(current)
        nxt = None
        for mapping in mappings:
            if current in mapping:
                nxt = mapping[current]
                break
        if nxt is None:
            return current
        current = nxt


def dir_pool(files: set[str]) -> set[str]:
    dirs: set[str] = set()
    for path in files:
        parent = posixpath.dirname(path)
        while parent and parent not in dirs:
            dirs.add(parent)
            parent = posixpath.dirname(parent)
    return dirs


def build_dir_map(file_map: dict[str, str]) -> dict[str, str]:
    """old directory -> new directory, only when every moved file agrees."""
    votes: dict[str, set[str]] = defaultdict(set)
    for old, new in file_map.items():
        old_dir = posixpath.dirname(old)
        new_dir = posixpath.dirname(new)
        if old_dir != new_dir:
            votes[old_dir].add(new_dir)
    return {old_dir: next(iter(new_dirs)) for old_dir, new_dirs in votes.items() if len(new_dirs) == 1}


# ---------------------------------------------------------------- resolution

def unique_suffix(path: str, candidates: set[str]) -> Resolution:
    parts = path.split("/")
    for n in range(len(parts), 0, -1):
        suffix = parts[-n:]
        matches = sorted(c for c in candidates if c.split("/")[-n:] == suffix)
        if len(matches) == 1:
            return Resolution(new=matches[0])
        if len(matches) > 1:
            return Resolution(candidates=matches, reason="ambiguous path suffix")
    return Resolution(reason="no path suffix match")


def normalized_name(name: str) -> str:
    return NUMERIC_PREFIX.sub("", name)


def unique_basename(path: str, candidates: set[str]) -> Resolution:
    base = posixpath.basename(path)
    matches = sorted(c for c in candidates if posixpath.basename(c) == base)
    if len(matches) == 1:
        return Resolution(new=matches[0])
    if len(matches) > 1:
        return Resolution(candidates=matches, reason="ambiguous basename")
    return Resolution(reason="no basename match")


def unique_normalized_basename(path: str, candidates: set[str]) -> Resolution:
    target = normalized_name(posixpath.basename(path))
    if not target or target == posixpath.basename(path):
        return Resolution(reason="no numeric-prefix variant")
    matches = sorted(
        c for c in candidates if normalized_name(posixpath.basename(c)) == target
    )
    if len(matches) == 1:
        return Resolution(new=matches[0])
    if len(matches) > 1:
        return Resolution(candidates=matches, reason="ambiguous normalized basename")
    return Resolution(reason="no normalized basename match")


def fuzzy_basename(path: str, candidates: set[str]) -> Resolution:
    old_base = posixpath.basename(path)
    if len(old_base) < FUZZY_MIN_NAME:
        return Resolution(reason="no fuzzy match (name too short)")
    suffix = Path(old_base).suffix.lower()
    scored: list[tuple[float, str]] = []
    for candidate in candidates:
        new_base = posixpath.basename(candidate)
        if Path(new_base).suffix.lower() != suffix:
            continue
        ratio = SequenceMatcher(None, old_base.lower(), new_base.lower()).ratio()
        if ratio >= FUZZY_THRESHOLD:
            scored.append((ratio, candidate))
    if not scored:
        return Resolution(reason="no fuzzy match")
    scored.sort(reverse=True)
    best_ratio, best = scored[0]
    second = scored[1][0] if len(scored) > 1 else 0.0
    if best_ratio - second < FUZZY_MARGIN:
        return Resolution(
            candidates=sorted(c for _, c in scored), reason="ambiguous fuzzy match"
        )
    return Resolution(new=best)


def resolve_target(
    old_rel: str,
    *,
    files: set[str],
    dirs: set[str],
    head_paths: set[str],
    history: dict[str, str],
    file_map: dict[str, str],
    dir_map: dict[str, str],
    is_dir_hint: bool,
) -> Resolution:
    old_is_dir = is_dir_hint or old_rel in dirs or any(p.startswith(old_rel + "/") for p in head_paths)
    pool = dirs if old_is_dir else files

    # 1. working-tree delta, then rename history (chains resolve to the newest name).
    candidates = []
    if old_is_dir and old_rel in dir_map:
        candidates.append(dir_map[old_rel])
    if old_rel in file_map:
        candidates.append(file_map[old_rel])
    followed = follow(old_rel, file_map, dir_map, history)
    if followed:
        candidates.append(followed)
    candidates = [c for c in candidates if c in pool]
    if len(set(candidates)) == 1:
        return Resolution(new=candidates[0])

    # 2. longest unique suffix (works for same-name moves), then basename variants.
    for resolver in (
        lambda p: unique_suffix(p, pool),
        lambda p: unique_basename(p, pool),
        lambda p: unique_normalized_basename(p, pool),
        lambda p: fuzzy_basename(p, pool),
    ):
        result = resolver(old_rel)
        if result.new is not None:
            return result
        if result.candidates:
            return result

    # A path with no known extension/directory hint may still be a directory.
    if not old_is_dir:
        for resolver in (
            lambda p: unique_suffix(p, dirs),
            lambda p: unique_basename(p, dirs),
        ):
            result = resolver(old_rel)
            if result.new is not None:
                return result
            if result.candidates:
                return result

    return Resolution(reason="no current target found")


# ---------------------------------------------------------------- link parsing

def repo_rel(source: Path, link_path: str) -> str | None:
    if not link_path:
        return None
    if link_path.startswith("/"):
        probe = Path(link_path)
    else:
        probe = Path(os.path.normpath(str(source.parent / link_path)))
    try:
        return probe.relative_to(ROOT).as_posix()
    except ValueError:
        return None


def split_destination(raw: str) -> tuple[str, str]:
    """Split a markdown destination into (path, trailing title text)."""
    stripped = raw.strip()
    if stripped.startswith("<"):
        end = stripped.find(">")
        if end != -1:
            return stripped[1:end], stripped[end + 1:].strip()
    match = TITLE_SUFFIX_RE.match(stripped)
    if match:
        return match.group(1), (match.group(2) or "").strip()
    return stripped, ""


def candidate_paths(source: Path, path_text: str) -> list[str]:
    rel = repo_rel(source, path_text)
    return [rel] if rel else []


def link_exists(source: Path, path_text: str) -> bool:
    return any((ROOT / rel).exists() for rel in candidate_paths(source, path_text))


def iter_links(path: Path):
    """Yield (line_no, line, match) for markdown links outside fenced blocks."""
    in_fence = False
    for line_no, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True), 1):
        if DOCS_LINT.FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for match in DOCS_LINT.LINK_RE.finditer(line):
            target = match.group(1).strip()
            if target.startswith("<") and target.endswith(">"):
                target = target[1:-1].strip()
            if not target or "://" in target or target.startswith(("mailto:", "#")):
                continue
            yield line_no, line, match


def source_files() -> list[Path]:
    files = {p for p in DOCS_LINT.docs_files() if p != DOCS_LINT.GENERATED and p.exists()}
    files |= {p for p in DOCS_LINT.LIVE_DOCS if p != DOCS_LINT.GENERATED and p.exists()}
    files |= {p for p in DOCS_LINT.CARDS if p.exists()}
    return sorted(files)


def relative_for_link(source: Path, target_rel: str) -> str:
    source_rel = source.relative_to(ROOT).as_posix()
    return posixpath.relpath(target_rel, start=posixpath.dirname(source_rel))


def make_destination(stem: str, fragment: str, title: str) -> str:
    path = stem
    if any(char in path for char in "()<>#"):
        raise ValueError(f"path contains characters markdown links cannot carry: {path}")
    if " " in path:
        path = f"<{path}>"
    destination = path + fragment
    if title:
        destination += " " + title
    return destination


def label_edit(line: str, match, path_text: str, old_rel: str, stem: str, target_rel: str):
    """When the visible label is just the old path, update it too.

    Prose labels are left alone: only labels that literally name the old target
    (optionally wrapped in backticks) are rewritten.
    """
    full = match.group(0)
    open_index = full.find("[")
    close_index = full.rfind("](")
    if open_index == -1 or close_index <= open_index:
        return None
    label_start = match.start() + open_index + 1
    label_end = match.start() + close_index
    label = line[label_start:label_end]
    core = label.strip()
    wrapped = len(core) >= 2 and core.startswith("`") and core.endswith("`")
    if wrapped:
        core = core[1:-1].strip()
    if core == path_text:
        new_core = stem
    elif core == old_rel:
        new_core = target_rel
    else:
        return None
    if core == new_core:
        return None
    if wrapped:
        new_core = f"`{new_core}`"
    return label_start, label_end, new_core


# ---------------------------------------------------------------- main

def main() -> int:
    parser = argparse.ArgumentParser(description="repair broken relative markdown links")
    parser.add_argument("--write", action="store_true", help="apply fixes (default: dry run)")
    parser.add_argument("--verbose", action="store_true", help="print scan counts")
    args = parser.parse_args()

    files = current_files()
    head = head_blobs()
    current_oids = {}
    for path in files:
        oid = blob_oid(ROOT / path)
        if oid:
            current_oids[path] = oid
    file_map, ambiguous_delta = delta_map(head, files, current_oids)
    similar = similarity_map(head, files, file_map)
    history = history_map()
    maps = dict(history)
    maps.update(similar)
    maps.update(file_map)
    dirs = dir_pool(files)
    dir_map = build_dir_map(maps)
    head_paths = set(head)

    fixes: list[Fix] = []
    problems: list[Problem] = []
    for source in source_files():
        for line_no, line, match in iter_links(source):
            raw = match.group(1)
            path_text, title = split_destination(raw)
            fragment = ""
            if "#" in path_text:
                path_text, fragment = path_text.split("#", 1)
                fragment = "#" + fragment
            if not path_text:
                continue
            if link_exists(source, path_text):
                continue

            # docs-lint also accepts `path title` when the leading token resolves.
            title_for_output = title
            if " " in path_text and not title:
                first, rest = path_text.split(" ", 1)
                if link_exists(source, first):
                    continue
                if link_exists(source, path_text):
                    continue
                path_text = first
                title_for_output = rest

            old_rel = repo_rel(source, path_text)
            if old_rel is None:
                problems.append(
                    Problem(source, line_no, raw.strip(), "target is outside the repository")
                )
                continue
            # A percent-encoded path is broken for docs-lint even when the decoded
            # file exists; treat the decoded path as the target to be repaired.
            if not (ROOT / old_rel).exists():
                decoded = repo_rel(source, unquote(path_text))
                if decoded and (ROOT / decoded).exists():
                    old_rel = decoded

            resolution = resolve_target(
                old_rel,
                files=files,
                dirs=dirs,
                head_paths=head_paths,
                history=history,
                file_map=file_map,
                dir_map=dir_map,
                is_dir_hint=path_text.endswith("/"),
            )
            if resolution.new is None:
                reason = resolution.reason
                if old_rel in ambiguous_delta:
                    resolution = Resolution(
                        candidates=ambiguous_delta[old_rel], reason="ambiguous content match"
                    )
                problems.append(
                    Problem(source, line_no, raw.strip(), reason, resolution.candidates)
                )
                continue
            if resolution.new.startswith(ARCHIVE_PREFIX):
                problems.append(
                    Problem(
                        source,
                        line_no,
                        raw.strip(),
                        "target now lives in frozen docs/archive/; decide manually",
                        [resolution.new],
                    )
                )
                continue

            stem = relative_for_link(source, resolution.new)
            if path_text.endswith("/") and not stem.endswith("/"):
                stem += "/"
            try:
                destination = make_destination(stem, fragment, title_for_output)
            except ValueError as error:
                problems.append(Problem(source, line_no, raw.strip(), str(error)))
                continue

            old_destination = raw.strip()
            if destination == old_destination:
                continue
            annotation = label_edit(
                line,
                match,
                path_text,
                old_rel,
                stem,
                resolution.new,
            )
            fixes.append(
                Fix(
                    source,
                    line_no,
                    match.start(1),
                    match.end(1),
                    raw.strip(),
                    destination,
                    *annotation if annotation else (None, None, None),
                )
            )

    grouped: dict[Path, list[Fix]] = defaultdict(list)
    for fix in fixes:
        grouped[fix.source].append(fix)

    for fix in fixes:
        prefix = "fixed" if args.write else "would fix"
        print(f"{prefix}: {fix.source.relative_to(ROOT)}:{fix.line}: {fix.old} -> {fix.new}")
    for problem in problems:
        print(
            f"error: {problem.source.relative_to(ROOT)}:{problem.line}: "
            f"cannot resolve {problem.old!r}: {problem.reason}"
        )
        if problem.candidates:
            shown = ", ".join(problem.candidates[:8])
            more = "" if len(problem.candidates) <= 8 else " ..."
            print(f"       candidates: {shown}{more}")

    if args.write:
        for source, source_fixes in grouped.items():
            text = source.read_text(encoding="utf-8")
            lines = text.splitlines(keepends=True)
            for fix in sorted(source_fixes, key=lambda item: (item.line, item.start), reverse=True):
                line = lines[fix.line - 1]
                edits = [(fix.start, fix.end, fix.new)]
                if fix.label_start is not None:
                    edits.append((fix.label_start, fix.label_end, fix.label_new))
                for start, end, replacement in sorted(edits, reverse=True):
                    line = line[:start] + replacement + line[end:]
                lines[fix.line - 1] = line
            with source.open("w", encoding="utf-8", newline="") as handle:
                handle.write("".join(lines))

    if args.verbose:
        print(
            f"scanned {len(source_files())} files, "
            f"{len(files)} current paths, {len(head)} HEAD paths"
        )
    mode = "wrote" if args.write else "dry run"
    print(
        f"docs-fix-links: {len(fixes)} fix(es), {len(problems)} unresolved "
        f"({mode}; {'re-run with --write' if not args.write else 'index not rewritten'})"
    )
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
