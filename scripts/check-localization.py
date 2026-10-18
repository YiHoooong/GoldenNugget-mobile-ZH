#!/usr/bin/env python3
"""Structural gate for the source-level Chinese localization.

Every permitted change is *inside* a Swift string literal.  This checker
compares each file against git HEAD and fails when:

  * the code skeleton (everything outside string literal contents) changed,
  * the number/order of string literals changed,
  * code inside an interpolation `\\(...)` changed (translating a *nested*
    string literal inside the interpolation is allowed),
  * a printf-style format specifier sequence changed,
  * a changed literal contains no CJK (probably forgotten / not translated),
  * the file no longer parses (optional --parse, requires swiftc).

Usage:
  python3 .translation/check_localization.py --files a.swift b.swift [...]
  python3 .translation/check_localization.py --all-changed
  python3 .translation/check_localization.py --all-changed --parse

Exit code 0 = pass, 1 = violations.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

CJK = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")
# printf-style specifiers, including positional ones and %%.
FMT = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|j|t)?[diouxXeEfgGaAcspn@%]")


@dataclass
class Literal:
    start: int          # offset of opening quote
    end: int            # offset just past closing quote
    body_start: int     # first content char (after quotes)
    body_end: int       # offset of closing quote
    kind: str           # 'single' | 'multiline'
    text: str           # raw body (escapes/interpolations intact)


def _skip_interpolation(s: str, i: int) -> int:
    """`i` is just past `\\(`; return the offset just past the matching `)`."""
    n = len(s)
    depth = 1
    while i < n:
        c = s[i]
        if c == '"':
            i = _scan_string(s, i)
            continue
        if c == "\\":
            i += 2
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def _scan_string(s: str, i: int) -> int:
    """`i` points at an opening quote; return offset just past the closing quote."""
    triple = s.startswith('"""', i)
    q = '"""' if triple else '"'
    n = len(s)
    j = i + len(q)
    while j < n:
        if s.startswith(q, j):
            return j + len(q)
        c = s[j]
        if c == "\\":
            if j + 1 < n and s[j + 1] == "(":
                j = _skip_interpolation(s, j + 2)
            else:
                j += 2
            continue
        j += 1
    return n


class SwiftLexer:
    """Extracts string literals, skipping comments, with offsets."""

    def __init__(self, src: str):
        self.src = src
        self.literals: list[Literal] = []
        self._scan()

    def _scan(self) -> None:
        s, i, n = self.src, 0, len(self.src)
        while i < n:
            c = s[i]
            if s.startswith("//", i):
                j = s.find("\n", i)
                i = n if j < 0 else j
            elif s.startswith("/*", i):
                j = s.find("*/", i + 2)
                i = n if j < 0 else j + 2
            elif s.startswith('"""', i):
                end = _scan_string(s, i)
                body_start, body_end = i + 3, end - 3
                self.literals.append(Literal(i, end, body_start, body_end,
                                             "multiline", s[body_start:body_end]))
                i = end
            elif c == '"':
                end = _scan_string(s, i)
                body_start, body_end = i + 1, end - 1
                self.literals.append(Literal(i, end, body_start, body_end,
                                             "single", s[body_start:body_end]))
                i = end
            else:
                i += 1


def skeleton(src: str, lits: list[Literal]) -> str:
    """Replace each literal body with a fixed marker, preserving delimiters."""
    out, pos = [], 0
    for lit in lits:
        out.append(src[pos:lit.body_start])
        out.append("\x00")
        pos = lit.body_end
    out.append(src[pos:])
    return "".join(out)


def interpolations(body: str) -> list[str]:
    """Top-level `\\(...)` expressions in a literal body, in order."""
    result: list[str] = []
    i, n = 0, len(body)
    while i < n:
        if body[i] == "\\":
            if i + 1 < n and body[i + 1] == "(":
                j = _skip_interpolation(body, i + 2)
                result.append(body[i:j])
                i = j
                continue
            i += 2
            continue
        i += 1
    return result


def interp_skeleton(expr: str) -> str:
    """Normalize an interpolation expression: nested string *contents* become
    markers, everything else (identifiers/operators/calls) is preserved."""
    out: list[str] = []
    i, n = 0, len(expr)
    while i < n:
        if expr.startswith('"""', i) or expr[i] == '"':
            end = _scan_string(expr, i)
            q = '"""' if expr.startswith('"""', i) else '"'
            out.append(q + "\x00" + q)
            i = end
            continue
        out.append(expr[i])
        i += 1
    return "".join(out)


def formats(body: str) -> list[str]:
    return FMT.findall(body)


def git_show(path: str) -> str | None:
    try:
        return subprocess.run(["git", "show", f"HEAD:{path}"], capture_output=True,
                              text=True, check=True).stdout
    except subprocess.CalledProcessError:
        return None


def check_file(path: str) -> list[str]:
    errs: list[str] = []
    p = Path(path)
    if not p.exists():
        return [f"{path}: file missing"]
    new = p.read_text(encoding="utf-8")
    old = git_show(path)
    if old is None:
        return errs  # new file: no baseline

    old_lex, new_lex = SwiftLexer(old), SwiftLexer(new)
    if skeleton(old, old_lex.literals) != skeleton(new, new_lex.literals):
        old_sk = skeleton(old, old_lex.literals).splitlines()
        new_sk = skeleton(new, new_lex.literals).splitlines()
        line = next((i + 1 for i, (a, b) in enumerate(zip(old_sk, new_sk)) if a != b),
                    min(len(old_sk), len(new_sk)) + 1)
        errs.append(f"{path}:{line}: CODE SKELETON CHANGED outside string literals "
                    "(only literal contents may change)")

    if len(old_lex.literals) != len(new_lex.literals):
        errs.append(f"{path}: literal count changed {len(old_lex.literals)} -> "
                    f"{len(new_lex.literals)}")
        return errs

    for n, (a, b) in enumerate(zip(old_lex.literals, new_lex.literals), 1):
        old_interp = [interp_skeleton(e) for e in interpolations(a.text)]
        new_interp = [interp_skeleton(e) for e in interpolations(b.text)]
        if old_interp != new_interp:
            errs.append(f"{path}: literal #{n} interpolation code changed: "
                        f"{interpolations(a.text)} -> {interpolations(b.text)}")
        if formats(a.text) != formats(b.text):
            errs.append(f"{path}: literal #{n} format specifiers changed: "
                        f"{formats(a.text)} -> {formats(b.text)}")
        # A literal whose content changed but has no CJK anywhere is suspicious --
        # unless it is an outer literal that only changed inside a nested string.
        if a.text != b.text and not CJK.search(b.text):
            line = new.count("\n", 0, b.start) + 1
            errs.append(f"{path}:{line}: changed literal has no CJK text: "
                        f"{b.text[:70]!r}")
    return errs


def parse_check(path: str) -> list[str]:
    try:
        r = subprocess.run(["swiftc", "-frontend", "-parse", path],
                           capture_output=True, text=True)
    except FileNotFoundError:
        return [f"{path}: swiftc not found (cannot parse-check)"]
    if r.returncode != 0:
        return [f"{path}: PARSE FAILED\n{r.stderr.strip()[:2000]}"]
    return []


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--files", nargs="+", default=[])
    ap.add_argument("--all-changed", action="store_true")
    ap.add_argument("--parse", action="store_true")
    args = ap.parse_args()

    files = list(args.files)
    if args.all_changed:
        out = subprocess.run(["git", "diff", "--name-only", "HEAD", "--", "*.swift"],
                             capture_output=True, text=True, check=True).stdout
        files += [f for f in out.splitlines() if f]

    files = sorted(dict.fromkeys(f for f in files if f.endswith(".swift")))
    if not files:
        print("no Swift files to check")
        return 0

    errors: list[str] = []
    for f in files:
        errors.extend(check_file(f))
        if args.parse:
            errors.extend(parse_check(f))

    if errors:
        print(f"FAIL — {len(errors)} violation(s) across {len(files)} file(s):")
        for e in errors:
            print("  -", e)
        return 1
    print(f"OK — {len(files)} file(s): structure intact, only string contents changed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
