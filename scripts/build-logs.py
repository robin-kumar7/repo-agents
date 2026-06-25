#!/usr/bin/env python3
"""build-logs.py — deterministic log-to-code mapping builder.

Scans the repository for logger call sites and emits a JSON file mapping each
literal log message to its file:line. Used by AI agents to answer questions
like "where is this log line emitted?" without a broad text search.

Schema: see docs/index-formats.md (agent-index/logs v1).

Limitations (intentional, v1):
  - Only the first argument is captured.
  - Only literal string arguments are captured (literal=true).
    Calls with template strings, concatenation, or variable args are
    recorded with message="" and literal=false.
  - Single-line patterns only — multi-line log calls are partially captured.
  - Comment-leading lines are skipped (best-effort).

Usage:
    build-logs.py [--output PATH] [--root DIR]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

# -------------------------------------------------------------------- patterns

# Each language pattern must capture:
#   group 1: level (raw, normalized later)
#   group 2: first argument as it appears in source (optional)
LANG_PATTERNS: dict[str, dict[str, object]] = {
    "Go": {
        "extensions": (".go",),
        "regex": re.compile(
            r"\b(?:log|logger|zlog|zlogger|slog|logr|klog|sugar|l)\w*"
            r"(?:\.\w+\(\))?"
            r"(?:\.[A-Z]\w+)*"
            r"\.(Info|Warn|Warning|Error|Debug|Fatal|Panic|Print|Trace)"
            r"(?:f|w|S|ln)?\s*\(\s*"
            r"(\"(?:[^\"\\]|\\.)*\"|`[^`]*`)?"
        ),
    },
    "Java": {
        "extensions": (".java",),
        "regex": re.compile(
            r"\b(?:log|logger|LOG|LOGGER)\w*"
            r"\.(info|warn|warning|error|debug|trace|fatal)\s*\(\s*"
            r"(\"(?:[^\"\\]|\\.)*\")?"
        ),
    },
    "Python": {
        "extensions": (".py",),
        "regex": re.compile(
            r"\b(?:log|logger|logging|_log|_logger)\w*"
            r"\.(info|warning|warn|error|debug|critical|exception)\s*\(\s*"
            r"([rfbRFB]{0,2}\"(?:[^\"\\]|\\.)*\"|[rfbRFB]{0,2}'(?:[^'\\]|\\.)*')?"
        ),
    },
    "TypeScript": {
        "extensions": (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"),
        "regex": re.compile(
            r"\b(?:console|log|logger)\w*"
            r"\.(log|info|warn|warning|error|debug|trace)\s*\(\s*"
            r"(\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'|`[^`]*`)?"
        ),
    },
}

EXCLUDE_DIRS = frozenset({
    "vendor", "node_modules", ".git", ".bootstrap", ".agent-index",
    "dist", "build", "target", "__pycache__", ".venv", "venv",
    ".tox", ".mypy_cache", ".pytest_cache", ".gradle", ".idea",
    "out",
})

EXCLUDE_FILE_SUFFIXES = (
    ".pb.go", ".pb.validate.go",
    "_pb2.py", "_pb2_grpc.py",
    ".min.js", ".bundle.js",
)

# Best-effort comment-leading detection.
COMMENT_PREFIXES = ("//", "#", "/*", "*", "--")

# Map every observed level to a canonical name. Keys must be lowercase.
LEVEL_NORMALIZE = {
    "trace": "trace",
    "debug": "debug",
    "info": "info",
    "log": "info",
    "print": "info",
    "warn": "warn",
    "warning": "warn",
    "error": "error",
    "exception": "error",
    "fatal": "fatal",
    "critical": "fatal",
    "panic": "fatal",
}


# ---------------------------------------------------------------------- helpers


def iter_source_files(root: Path, extensions: tuple[str, ...]) -> Iterable[Path]:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in EXCLUDE_DIRS]
        for fname in filenames:
            if not fname.endswith(extensions):
                continue
            if fname.endswith(EXCLUDE_FILE_SUFFIXES):
                continue
            yield Path(dirpath) / fname


def strip_literal(raw: str) -> str:
    """Strip language-specific prefixes (r,f,b,R,F,B) and surrounding quotes."""
    s = re.sub(r"^[rfbRFB]{1,2}", "", raw)
    if len(s) >= 2 and s[0] in ('"', "'", "`") and s[-1] == s[0]:
        return s[1:-1]
    return s


def extract_from_file(path: Path, lang: str, regex: re.Pattern) -> list[dict]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []

    out: list[dict] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        stripped = line.lstrip()
        if stripped.startswith(COMMENT_PREFIXES):
            continue
        for m in regex.finditer(line):
            level_raw = m.group(1).lower()
            level = LEVEL_NORMALIZE.get(level_raw, level_raw)
            arg_raw = m.group(2) or ""
            literal = bool(arg_raw)
            message = strip_literal(arg_raw) if literal else ""
            out.append({
                "level": level,
                "message": message,
                "literal": literal,
                "file": "",  # filled in by caller (relative to root)
                "line": lineno,
                "language": lang,
            })
    return out


def git_commit(root: Path) -> str:
    try:
        out = subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            text=True, stderr=subprocess.DEVNULL,
        )
        return out.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "unknown"


# ----------------------------------------------------------------------- main


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--output", "-o", default=".agent-index/logs.json",
                    help="Output JSON file path (default: .agent-index/logs.json)")
    ap.add_argument("--root", "-r", default=".",
                    help="Repository root to scan (default: .)")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    if not root.is_dir():
        print(f"build-logs: root {root} is not a directory", file=sys.stderr)
        return 2

    all_logs: list[dict] = []
    seen_langs: set[str] = set()

    for lang, cfg in LANG_PATTERNS.items():
        extensions = cfg["extensions"]  # type: ignore[index]
        regex = cfg["regex"]            # type: ignore[index]
        files = list(iter_source_files(root, extensions))
        if not files:
            continue
        seen_langs.add(lang)
        for f in files:
            rel = f.relative_to(root)
            for entry in extract_from_file(f, lang, regex):
                entry["file"] = str(rel).replace(os.sep, "/")
                all_logs.append(entry)

    # Deterministic order: by file, then by line.
    all_logs.sort(key=lambda e: (e["file"], e["line"]))

    output = {
        "schema": "agent-index/logs",
        "version": 1,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "generator": "build-logs.py v1",
        "repo": {"commit": git_commit(root)},
        "languages": sorted(seen_langs),
        "logs": all_logs,
    }

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(output, indent=2, ensure_ascii=False) + "\n",
                        encoding="utf-8")

    print(
        f"build-logs: {len(all_logs)} entries "
        f"({len(seen_langs)} languages: {','.join(sorted(seen_langs)) or 'none'}) "
        f"→ {out_path}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
