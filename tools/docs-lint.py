#!/usr/bin/env python3
"""docs-lint / docs-index for this repository. Standard library only.

Rules (see docs/plans/p5-doc-plan.md §8):
  errors (exit 1): front-matter, resolvable links, generated index, old paths (docs and code),
                  cards > 60 lines
  warnings (exit 0): cards > 40 lines, card headings, banned headings, card code blocks

Exemptions: everything under docs/archive/, the generated docs/README.md, and any
file whose basename starts with `external-reference` or `user-note`.
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
GENERATED = DOCS / "README.md"
ARCHIVE = DOCS / "archive"
EXEMPT_PREFIXES = ("external-reference", "user-note")
# docs/ui/AGENTS.md is deliberately NOT a card: it carries design-time collaboration rules, so its
# length and headings are exempt from the card constraints above.
CARDS = [ROOT / p / "AGENTS.md" for p in ("contract", "server", "client", "apps/ios", "tools")]
CARD_SECTIONS = {"布局", "命令", "不许破坏", "环境", "去哪看"}
CARD_LINE_WARN = 40
CARD_LINE_ERROR = 60
BANNED_HEADING = re.compile(r"概述|简介|背景|特性|设计思路|未来工作|未来计划|TODO|Changelog|变更记录")
# Live docs must not link back to plans that are now archived under docs/archive/stage-1/.
# docs/plans itself is not scanned: those files are historical records.
OLD_PATHS = re.compile(
    r"(samples/|app/README|ipad/README|docs/0[0-9]-|08-technical-reference"
    r"|plans/stage-2-handoff\.md|plans/design-01-|plans/design-02-"
    r"|plans/p5-ref-doc-refactor-guide\.md"
    r"|(?:server|contract|client)/README\.md)"
)
LIVE_DOCS = [
    ROOT / "README.md",
    ROOT / "AGENTS.md",
    GENERATED,
    DOCS / "status.md",
]
CODE_ROOTS = [ROOT / p for p in ("server", "client", "contract", "apps", "tools")]
CODE_SUFFIXES = {".swift", ".py", ".sh"}
# Removed doc names that must not survive in code comments/strings. `samples/` is deliberately
# excluded: test provenance paths are opaque fixture strings, not doc references.
CODE_OLD_PATHS = re.compile(
    r"(?:server|contract|client)/README\.md|\bAGENT\.md|docs/0[0-9]-|08-technical-reference"
)
TYPE_VALUES = {"reference", "agent", "decision", "record", "status"}
LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
FENCE_RE = re.compile(r"^\s*```")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*$")


def is_exempt(path: Path) -> bool:
    if ARCHIVE in path.parents or path == ARCHIVE:
        return True
    return path.name.startswith(EXEMPT_PREFIXES)


def docs_files():
    return sorted(p for p in DOCS.rglob("*.md") if not is_exempt(p))


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def front_matter(path: Path):
    text = read(path)
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---\n", 4)
    if end < 0:
        return None
    data = {}
    for line in text[4:end].splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            data[key.strip()] = value.strip()
    return data


def h1(path: Path) -> str:
    in_fence = False
    for line in read(path).splitlines():
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m = HEADING_RE.match(line)
        if m and len(m.group(1)) == 1:
            return m.group(2)
    return path.stem


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


# ---------------------------------------------------------------- checks

def check_front_matter():
    errors, warnings = [], []
    targets = list(docs_files())
    if GENERATED not in targets:
        targets = [p for p in targets if p != GENERATED]
    targets += [p for p in CARDS if p.exists()]
    for path in targets:
        if path == GENERATED:
            continue
        fm = front_matter(path)
        if fm is None:
            errors.append(f"{rel(path)}: missing front-matter (type/owner/updated)")
            continue
        missing = [k for k in ("type", "owner", "updated") if k not in fm]
        if missing:
            errors.append(f"{rel(path)}: front-matter missing {', '.join(missing)}")
        elif fm["type"] not in TYPE_VALUES:
            errors.append(f"{rel(path)}: bad front-matter type {fm['type']!r}")
    return errors, warnings


def link_targets(path: Path):
    """Yield (line_no, target) for markdown links outside fenced blocks."""
    in_fence = False
    for no, line in enumerate(read(path).splitlines(), 1):
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for raw in LINK_RE.findall(line):
            target = raw.strip()
            if target.startswith("<") and target.endswith(">"):
                target = target[1:-1].strip()
            if not target or "://" in target or target.startswith(("mailto:", "#")):
                continue
            yield no, target


def check_links():
    errors, warnings = [], []
    targets = [p for p in docs_files() if p != GENERATED] + LIVE_DOCS + [p for p in CARDS if p.exists()]
    seen = set()
    for path in targets:
        if path in seen or not path.exists():
            continue
        seen.add(path)
        for no, target in link_targets(path):
            candidate = target.split("#", 1)[0]
            if not candidate:
                continue
            resolved = (path.parent / candidate).resolve()
            if not resolved.exists():
                # allow a link that carries a title after a space, or URL-encoded spaces
                if " " in candidate:
                    first = candidate.split(" ", 1)[0]
                    if (path.parent / first).resolve().exists():
                        continue
                errors.append(f"{rel(path)}:{no}: broken link -> {target}")
    return errors, warnings


def check_old_paths():
    errors, warnings = [], []
    files = list(LIVE_DOCS)
    files += [p for p in (DOCS / "reference").rglob("*.md")]
    files += [p for p in (DOCS / "ui").rglob("*.md")] if (DOCS / "ui").exists() else []
    files += [p for p in CARDS if p.exists()]
    seen = set()
    for path in files:
        if path in seen or not path.exists() or is_exempt(path):
            continue
        seen.add(path)
        for no, line in enumerate(read(path).splitlines(), 1):
            m = OLD_PATHS.search(line)
            if m:
                errors.append(f"{rel(path)}:{no}: old path {m.group(0)!r}")
    return errors, warnings


def code_files():
    me = Path(__file__).resolve()
    files = []
    for root in CODE_ROOTS:
        for path in root.rglob("*"):
            if not path.is_file() or path.suffix not in CODE_SUFFIXES:
                continue
            parts = path.relative_to(ROOT).parts
            # build/cache dirs and the untracked external encoder clone are out of scope
            if any(part.startswith(".") for part in parts) or "toGainMapHDR" in parts:
                continue
            if path.resolve() == me:
                continue
            files.append(path)
    return files


def check_code_paths():
    errors, warnings = [], []
    for path in code_files():
        for no, line in enumerate(read(path).splitlines(), 1):
            m = CODE_OLD_PATHS.search(line)
            if m:
                errors.append(f"{rel(path)}:{no}: old doc path {m.group(0)!r} in code")
    return errors, warnings


def check_cards():
    errors, warnings = [], []
    references = [p for p in (DOCS / "reference").rglob("*.md") if not is_exempt(p)]
    for path in [p for p in CARDS if p.exists()] + references:
        text = read(path)
        lines = text.splitlines()
        in_fence = False
        code_len = 0
        max_code = 0
        for line in lines:
            if FENCE_RE.match(line):
                if in_fence:
                    max_code = max(max_code, code_len)
                    code_len = 0
                in_fence = not in_fence
                continue
            if in_fence:
                code_len += 1
        if path in CARDS:
            if len(lines) > CARD_LINE_ERROR:
                errors.append(f"{rel(path)}: {len(lines)} lines (> {CARD_LINE_ERROR})")
            elif len(lines) > CARD_LINE_WARN:
                warnings.append(f"{rel(path)}: {len(lines)} lines (> {CARD_LINE_WARN})")
            for no, line in enumerate(lines, 1):
                m = HEADING_RE.match(line)
                if m and len(m.group(1)) >= 2:
                    title = m.group(2).split("—", 1)[0].strip()
                    if title not in CARD_SECTIONS:
                        warnings.append(f"{rel(path)}:{no}: heading {title!r} not in card whitelist")
            if max_code > 4:
                warnings.append(f"{rel(path)}: code block of {max_code} lines (> 4)")
        for no, line in enumerate(lines, 1):
            m = HEADING_RE.match(line)
            if m and BANNED_HEADING.search(m.group(2)):
                warnings.append(f"{rel(path)}:{no}: banned heading {m.group(2)!r}")
    return errors, warnings


# ---------------------------------------------------------------- index

GROUP_TITLES = {
    "status": "状态",
    "reference": "reference",
    "plans": "plans",
    "decisions": "decisions",
    "ui": "ui",
}


def build_index() -> str:
    groups = {key: [] for key in GROUP_TITLES}
    for path in sorted(DOCS.rglob("*.md")):
        if path == GENERATED or is_exempt(path):
            continue
        parts = path.relative_to(DOCS).parts
        if len(parts) == 1:
            key = "status" if path.name == "status.md" else None
        else:
            key = parts[0]
        if key in groups:
            groups[key].append(path)

    out = [
        "<!-- generated by make docs-index, do not edit -->",
        "",
        "# 文档索引",
        "",
        "> 按目录分组。精确事实在 `reference/`，易变状态在 `status.md`，计划与设计在 `plans/`，决策在 `decisions/`，历史在 `archive/`（冻结，不索引）。",
        "> `✔` = stage-1 实测，证据在 `archive/`；归档非必要不读。",
        "> 按任务查：见根 [AGENTS.md](../AGENTS.md) 的「文档路由」表。",
        "",
        "如果文档之间、或文档与你的 AGENTS.md 矛盾，很可能是由用户手改文档导致的。不要自己猜测，向用户报告并请用户做决策。",
    ]
    for key, title in GROUP_TITLES.items():
        items = groups.get(key) or []
        if not items:
            continue
        out += ["", f"## {title}", ""]
        for path in items:
            out.append(f"- [{path.name}]({path.relative_to(DOCS).as_posix()}) — {h1(path)}")
    return "\n".join(out) + "\n"


def check_index():
    errors, warnings = [], []
    expected = build_index()
    actual = read(GENERATED) if GENERATED.exists() else ""
    if expected != actual:
        errors.append("docs/README.md is out of date; run `make docs-index`")
    return errors, warnings


# ---------------------------------------------------------------- entry

def main() -> int:
    ap = argparse.ArgumentParser(description="docs structure lint / index generator")
    ap.add_argument("--write", action="store_true", help="(re)generate docs/README.md")
    ap.add_argument("--check", action="store_true", help="check only (default)")
    args = ap.parse_args()

    if args.write:
        GENERATED.write_text(build_index(), encoding="utf-8")
        print(f"wrote {rel(GENERATED)}")
        return 0

    errors, warnings = [], []
    for check in (
        check_front_matter,
        check_links,
        check_old_paths,
        check_code_paths,
        check_cards,
        check_index,
    ):
        e, w = check()
        errors += e
        warnings += w

    for w in warnings:
        print(f"warning: {w}")
    for e in errors:
        print(f"error: {e}")
    print(f"docs-lint: {len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
