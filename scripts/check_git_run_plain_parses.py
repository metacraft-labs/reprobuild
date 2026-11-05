#!/usr/bin/env python3
"""Refuse a ``gitRunPlain`` result whose ``.output`` is PARSED.

WHY THIS EXISTS
===============

``gitRunPlain`` (``libs/repro_cli_support``) runs git with its stderr merged
into its stdout. That is the right shape for a command whose exit status is
the answer, or whose text is only ever quoted back in an error message. It is
the wrong shape for a command whose stdout is the answer: git writes warnings
to stderr while still exiting 0 with the right answer on stdout, and the
merged stream then carries the warning in front of the answer.

The warning that made this concrete is ``warning: unable to find all
commit-graph files``, which git prints in a checkout whose split commit-graph
chain names a pruned graph file (a state a checkout borrowing objects through
``objects/info/alternates`` can re-enter at any time). ``rev-parse``,
``rev-list``, ``merge-base``, ``for-each-ref``, ``log`` and ``status`` all
print it. A caller that ``strip()``s the merged text and takes it as an object
id, a ref name, a count or a "dirty" verdict then reads the warning as the
answer.

``gitRunPlainQuery`` is the reader for an answer: ``output`` is stdout alone
and ``diagnostic`` is the merged text, for the error message. This gate keeps
the parse sites on it, so the class cannot grow back one site at a time.

WHAT IS REFUSED
===============

For every ``gitRunPlain(...)`` call in a ``.nim`` source:

* bound to a name (``let r = gitRunPlain(...)``, ``var r = ...``, or a
  reassignment of a ``var`` declared earlier), any use of ``r.output`` in the
  name's block that is not an ALLOWED use below;
* used inline, ``gitRunPlain(...).output``.

ALLOWED uses of a ``gitRunPlain`` result's ``.output`` -- the ones that read
the merged text BECAUSE it is diagnostic:

* concatenated into a message: the use directly follows ``&``
  (``"git add failed: " & addRes.output.strip()``), on its line or as the
  first token of a continuation line after a line ending in ``&``;
* passed to a function that classifies git's diagnostic text, named in
  ``DIAGNOSTIC_CONSUMERS``;
* annotated on its line with ``# git-merged-text: <reason>``, for a site that
  deliberately parses the merged stream. The reason is mandatory.

HOW TO SATISFY IT
=================

Read the answer with ``gitRunPlainQuery`` and quote ``.diagnostic`` (not
``.output``) in the error message, so a failure still shows git's stderr.

``python3 scripts/check_git_run_plain_parses.py --self-test`` proves the scan
still catches each refused shape and still passes each allowed one.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCAN_DIRS = ("libs", "apps", "tools", "tests")

#: Functions whose job is to classify git's DIAGNOSTIC text, so the merged
#: stream is exactly what they should be given.
DIAGNOSTIC_CONSUMERS = ("isTransientGitLockContention",)

ANNOTATION = re.compile(r"#\s*git-merged-text:\s*\S")
CALL = re.compile(r"\bgitRunPlain\(")
DECL = re.compile(r"^\s*proc\s+gitRunPlain\b")
BIND = re.compile(r"(?<![.\w])(?:(let|var)\s+)?(\w+)\s*(?::[^=]*)?=\s*gitRunPlain\($")


@dataclass(frozen=True)
class Hit:
    path: str
    line: int
    text: str
    why: str


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def call_end(lines: list[str], row: int, col: int) -> tuple[int, int]:
    """Row and column just past the ``)`` closing the call opened at
    ``lines[row][col]`` (``col`` indexes the ``(``)."""
    depth = 0
    r, c = row, col
    while r < len(lines):
        text = lines[r]
        while c < len(text):
            ch = text[c]
            if ch == "#":
                break
            if ch == "(" or ch == "[":
                depth += 1
            elif ch == ")" or ch == "]":
                depth -= 1
                if depth == 0:
                    return r, c + 1
            c += 1
        r += 1
        c = 0
    return row, len(lines[row])


def block_end(lines: list[str], row: int) -> int:
    """Index of the first line after the block that contains ``lines[row]``:
    the first later non-blank, non-comment line indented less than it."""
    base = indent_of(lines[row])
    for r in range(row + 1, len(lines)):
        stripped = lines[r].strip()
        if not stripped or stripped.startswith("#"):
            continue
        if indent_of(lines[r]) < base:
            return r
    return len(lines)


def declaration_row(lines: list[str], row: int, name: str) -> int:
    """The row declaring ``name`` that a bare reassignment at ``row`` refers
    to: the nearest earlier ``var name`` at an indentation no deeper."""
    pattern = re.compile(rf"^\s*var\s+{re.escape(name)}\b")
    for r in range(row - 1, -1, -1):
        if pattern.match(lines[r]) and indent_of(lines[r]) <= indent_of(lines[row]):
            return r
    return row


def use_is_allowed(lines: list[str], row: int, col: int) -> bool:
    line = lines[row]
    if ANNOTATION.search(line):
        return True
    before = line[:col].rstrip()
    if before.endswith("&"):
        return True
    if not before:
        for r in range(row - 1, -1, -1):
            prev = lines[r].split("#", 1)[0].rstrip()
            if prev:
                return prev.endswith("&")
        return False
    for consumer in DIAGNOSTIC_CONSUMERS:
        if before.endswith(consumer + "("):
            return True
    return False


def scan_text(path: str, text: str) -> list[Hit]:
    lines = text.split("\n")
    hits: list[Hit] = []
    seen_scopes: set[tuple[str, int]] = set()
    for row, line in enumerate(lines):
        code = line.split("#", 1)[0]
        if DECL.match(code):
            continue
        for match in CALL.finditer(code):
            open_col = match.end() - 1
            end_row, end_col = call_end(lines, row, open_col)
            tail = lines[end_row][end_col:]
            if tail.startswith(".output") and not ANNOTATION.search(lines[end_row]):
                hits.append(Hit(path, end_row + 1, lines[end_row].strip(),
                                "inline gitRunPlain(...).output"))
                continue
            bound = BIND.search(code[: match.end()])
            if not bound:
                continue
            keyword, name = bound.group(1), bound.group(2)
            start = row if keyword else declaration_row(lines, row, name)
            if (name, start) in seen_scopes:
                continue
            seen_scopes.add((name, start))
            stop = block_end(lines, start)
            rebind = re.compile(rf"\b(?:let|var)\s+{re.escape(name)}\b")
            use = re.compile(rf"\b{re.escape(name)}\.output\b")
            for r in range(start + 1, stop):
                body = lines[r].split("#", 1)[0]
                if rebind.search(body):
                    break
                for u in use.finditer(body):
                    if not use_is_allowed(lines, r, u.start()):
                        hits.append(Hit(path, r + 1, lines[r].strip(),
                                        f"{name}.output parsed (bound at line "
                                        f"{start + 1})"))
    return hits


SELF_TESTS: list[tuple[str, str, int]] = [
    ("caught_strip_as_answer", """
proc f() =
  let head = gitRunPlain(identity, ["rev-parse", "HEAD"])
  if head.code == 0:
    result = head.output.strip()
""", 1),
    ("caught_continuation_args", """
proc f() =
  let res = gitRunPlain(identity,
    ["-C", dir, "rev-list", "--count", "HEAD"])
  let n = parseInt(res.output.strip())
""", 1),
    ("caught_split_lines", """
proc f() =
  let r = gitRunPlain(identity, ["remote"])
  for line in r.output.splitLines():
    echo line
""", 1),
    ("caught_inline_output", """
proc f(): string =
  gitRunPlain(identity, ["rev-parse", "HEAD"]).output.strip()
""", 1),
    ("caught_reassigned_var", """
proc f() =
  var fetched: tuple[code: int; output: string]
  for attempt in 0 .. 3:
    fetched = gitRunPlain(identity, ["log", "--format=%H"])
  for sha in fetched.output.splitLines():
    echo sha
""", 1),
    ("caught_emptiness_verdict", """
proc f() =
  let status = gitRunPlain(identity, ["status", "--porcelain"])
  result.dirty = status.output.strip().len > 0
""", 1),
    ("caught_unannotated_beside_message", """
proc f() =
  let r = gitRunPlain(identity, ["merge-base", a, b])
  if r.code != 0: return "failed: " & r.output.strip()
  return r.output.strip()
""", 1),
    ("allowed_message_concat", """
proc f() =
  let addRes = gitRunPlain(identity, ["add", "--", rel])
  if addRes.code != 0:
    return failed("git add failed: " & addRes.output.strip())
""", 0),
    ("allowed_continuation_concat", """
proc f() =
  let co = gitRunPlain(identity, ["checkout", branch])
  if co.code != 0:
    return (false, "checkout failed: " &
      co.output.strip())
""", 0),
    ("allowed_diagnostic_consumer", """
proc f() =
  let fetched = gitRunPlain(identity, ["fetch"])
  if not isTransientGitLockContention(fetched.output):
    discard
""", 0),
    ("allowed_annotated", """
proc f() =
  let r = gitRunPlain(identity, ["fetch"])
  let joined = r.output.splitLines().join(" | ")  # git-merged-text: quoted in a finding
""", 0),
    ("allowed_exit_status_only", """
proc f(): bool =
  gitRunPlain(identity, ["merge-base", "--is-ancestor", a, b]).code == 0
""", 0),
    ("allowed_query_reader", """
proc f() =
  let head = gitRunPlainQuery(identity, ["rev-parse", "HEAD"])
  result = head.output.strip()
""", 0),
    ("allowed_out_of_scope_name", """
proc f() =
  if cond:
    let r = gitRunPlain(identity, ["add", "--", rel])
    discard r.code
  let r = gitRunPlainQuery(identity, ["rev-parse", "HEAD"])
  result = r.output.strip()
""", 0),
    ("annotation_needs_reason", """
proc f() =
  let r = gitRunPlain(identity, ["fetch"])
  let joined = r.output.strip()  # git-merged-text:
""", 1),
]


def self_test() -> int:
    failures = 0
    for name, body, expected in SELF_TESTS:
        hits = scan_text(f"<self-test:{name}>", body.lstrip("\n"))
        if len(hits) != expected:
            failures += 1
            print(f"check_git_run_plain_parses --self-test FAILED: {name}: "
                  f"expected {expected} finding(s), got {len(hits)}")
            for hit in hits:
                print(f"    {hit.line}: {hit.why}: {hit.text}")
    if failures:
        print(f"\ncheck_git_run_plain_parses: self-test FAILED "
              f"({failures} of {len(SELF_TESTS)} probes)")
        return 1
    print(f"check_git_run_plain_parses: self-test ok "
          f"({len(SELF_TESTS)} probes)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--self-test", action="store_true",
                    help="prove the scan catches each refused shape")
    ap.add_argument("paths", nargs="*", help="files to scan (default: tree)")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.paths:
        files = [Path(p) for p in args.paths]
    else:
        files = sorted(p for d in SCAN_DIRS for p in (ROOT / d).rglob("*.nim"))
    hits: list[Hit] = []
    for path in files:
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as err:
            print(f"check_git_run_plain_parses: cannot read {path}: {err}")
            return 2
        if "gitRunPlain(" not in text:
            continue
        try:
            shown = str(path.resolve().relative_to(ROOT))
        except ValueError:
            shown = str(path)
        hits.extend(scan_text(shown, text))
    for hit in hits:
        print(f"{hit.path}:{hit.line}: {hit.why}: {hit.text}")
    if hits:
        print(f"\ncheck_git_run_plain_parses: FAIL: {len(hits)} parse(s) of "
              "gitRunPlain's merged stdout+stderr. Read the answer with "
              "gitRunPlainQuery and quote .diagnostic in the error message.")
        return 1
    print(f"check_git_run_plain_parses: ok ({len(files)} files scanned)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
