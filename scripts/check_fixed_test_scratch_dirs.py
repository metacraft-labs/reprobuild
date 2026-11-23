#!/usr/bin/env python3
"""Refuse a test source that bakes a FIXED scratch path in at module level.

WHY THIS EXISTS
===============

The production test runner executes every test CASE as its own process
(``<binary> --run "<suite>::<test>"``), and it runs the cases of one binary
CONCURRENTLY with each other and with every other binary in the suite. A
scratch directory written as a module-level constant::

    const TmpDir = "build/test-tmp/m69-home-add-versioned"

is therefore shared mutable state between processes. The ``removeDir`` reset
one case performs at its start deletes the files a sibling case is part-way
through using; a fixture compiled to a fixed ``--out:`` path is overwritten
while a sibling is executing it (``Text file busy``). Every such failure
passes when the binary is run alone, which is why each one was found
separately, one red full run at a time (``t_partition_plan_json_round_trip``,
``t_n48_tool_profiles_tar_operands``, ``t_cmake_actions_declare_their_path``,
``test_m69_home_add_versioned``, ``test_m69_apply_end_to_end``,
``t_e2e_repro_profile_compile``, ...).

This check refuses the SHAPE, so the next one is not found that way.

WHAT IT FLAGS
=============

A module-level ``const`` / ``let`` / ``var`` declaration -- a single one, or an
entry of a module-level section -- in a test source whose initializer names a
FIXED path under the repository's ``build/`` tree or under ``getTempDir()``:

  * anything under ``build/test-tmp`` (``"build/test-tmp/x"``, or the
    components ``"build" / "test-tmp" / ...``);
  * any other ``build/`` path (``"build/m9r21_1_tmp"``, ``"build" / "x"``)
    whose NAME the file then uses as a directory -- as a path base
    (``Name / "f"``, ``Name & "/f"``) or in ``removeDir``/``createDir``/
    ``writeFile``/... -- because tests also spell identifiers that merely
    look like paths that way (``BinApp = "build/app"`` in a lock-file
    recipe) and those are not scratch;
  * ``getTempDir() / "<fixed name>"``;

and which carries none of the per-process markers:

  * ``testCaseScratchSlug()`` / ``testScratchSlug()`` (repro_test_support:
    private to the process running one case, bounded, stable across runs);
  * ``getCurrentProcessId()``;
  * ``createTempDir(...)``.

NOT flagged, because they are INPUTS a test reads rather than scratch it
writes: paths under ``build/bin`` and a direct file under ``build/test-bin``
(the binaries the build graph produced, e.g. ``ServerBinary``). A
subdirectory of ``build/test-bin`` IS flagged: that is where fixture
compiles put their output.

There is no allowlist. Converting the tree left zero sites; a new one is
fixed by appending the per-case slug, e.g.::

    let TmpDir = "build/test-tmp/m69-home-add-versioned" / testCaseScratchSlug()

KNOWN LIMIT
===========

It reads module-level declarations only. A fixed path built INSIDE a proc
that several cases call (``proc workDir(): string = "build" / "x"``) is the
same defect and is not seen here; the scan would need data flow to tell such a
proc from one that builds a read-only input path, and a check that cries wolf
gets switched off. Fix those by review, with the same helper.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

PER_PROCESS_MARKERS = (
    "testCaseScratchSlug",
    "testScratchSlug",
    "getCurrentProcessId",
    "createTempDir",
)

# A fixed path literal rooted at the repository's build/ tree, or a fixed
# name under the system temp directory.
BUILD_LITERAL = re.compile(r'"build/([^"]*)"')
BUILD_COMPONENTS = re.compile(r'"build"\s*/\s*"([^"]+)"(?:\s*/\s*"([^"]+)")?')
TEMP_LITERAL = re.compile(r'getTempDir\(\)\s*/\s*\(?\s*"')

DECL_START = re.compile(r"^(const|let|var)\b(.*)$")
ENTRY = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\*?\s*(:[^=]*)?=")
SINGLE = re.compile(r"^(?:const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)")


def is_input_path(first: str, rest: str | None) -> bool:
    """``build/bin/...`` and a direct file of ``build/test-bin`` are inputs."""
    if first == "bin" or first.startswith("bin/"):
        return True
    if first == "test-bin":
        return rest is None
    if first.startswith("test-bin/"):
        return "/" not in first[len("test-bin/"):]
    return False


def blank_strings_and_comments(text: str) -> str:
    """Blank triple-quoted string BODIES and comments, keep line structure.

    Ordinary ``"..."`` literals are kept intact: they are what is matched.
    """
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end < 0 else end + 3
            out.append("".join("\n" if c == "\n" else " " for c in text[i:end]))
            i = end
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] != '"' and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text[i] == "'" and i + 2 < n and text[i + 2] == "'":
            out.append(text[i:i + 3])
            i += 3
        elif text.startswith("#[", i):
            end = text.find("]#", i + 2)
            end = n if end < 0 else end + 2
            out.append("".join("\n" if c == "\n" else " " for c in text[i:end]))
            i = end
        elif text[i] == "#":
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def module_declarations(text: str):
    """Yield ``(line_number, statement_text)`` for every module-level decl."""
    lines = blank_strings_and_comments(text).split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        m = DECL_START.match(line)
        if not m:
            i += 1
            continue
        if m.group(2).strip():
            # Single declaration: it runs on while lines are indented deeper.
            start = i
            i += 1
            while i < len(lines) and (not lines[i].strip() or indent_of(lines[i]) > 0):
                i += 1
            name = SINGLE.match(lines[start])
            yield start + 1, (name.group(1) if name else ""), "\n".join(lines[start:i])
            continue
        # A section: entries at the section's own indent, each running on
        # while lines are indented deeper than the entry.
        i += 1
        entry_indent = None
        start = None
        while i < len(lines):
            cur = lines[i]
            if not cur.strip():
                i += 1
                continue
            ind = indent_of(cur)
            if ind == 0:
                break
            if entry_indent is None:
                entry_indent = ind
            if ind == entry_indent and ENTRY.match(cur):
                if start is not None:
                    yield start + 1, ENTRY.match(lines[start]).group(1), "\n".join(lines[start:i])
                start = i
            i += 1
        if start is not None:
            yield start + 1, ENTRY.match(lines[start]).group(1), "\n".join(lines[start:i])


def used_as_directory(name: str, code: str) -> bool:
    """Whether ``name`` is used as a directory the test writes under.

    A ``build/...`` literal outside ``build/test-tmp`` is also how tests spell
    IDENTIFIERS that merely look like paths (``BinApp = "build/app"`` in a
    lock-file recipe). Those are not scratch, so such a literal is flagged
    only when its name is a path BASE (``Name / "x"``, ``Name & "/x"``) or is
    handed to a directory operation.
    """
    if not name:
        return False
    base = re.compile(r"\b" + re.escape(name) + r'\s*(/|&\s*"/)')
    op = re.compile(r"\b(removeDir|createDir|existsOrCreateDir|removeFile|writeFile|"
                    r"copyFile|moveFile|copyDir|moveDir)\(\s*" + re.escape(name) + r"\b")
    return bool(base.search(code) or op.search(code))


def fixed_scratch(name: str, statement: str, code: str) -> str | None:
    """The offending path text, or None when the declaration is fine."""
    if any(marker in statement for marker in PER_PROCESS_MARKERS):
        return None
    for m in BUILD_LITERAL.finditer(statement):
        first = m.group(1)
        if first.startswith("test-tmp") or (
                not is_input_path(first, None) and used_as_directory(name, code)):
            return m.group(0)
    for m in BUILD_COMPONENTS.finditer(statement):
        first = m.group(1)
        if first == "test-tmp" or (
                not is_input_path(first, m.group(2)) and used_as_directory(name, code)):
            return m.group(0)
    m = TEMP_LITERAL.search(statement)
    if m:
        return statement[m.start():].split("\n", 1)[0].strip()
    return None


def scan(text: str) -> list[tuple[int, str]]:
    found = []
    code = blank_strings_and_comments(text)
    for line_number, name, statement in module_declarations(text):
        hit = fixed_scratch(name, statement, code)
        if hit is not None:
            found.append((line_number, hit))
    return found


def test_sources(root: pathlib.Path) -> list[str]:
    tracked = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--", "*.nim"],
        check=True, capture_output=True, text=True).stdout.split("\0")
    result = []
    for path in tracked:
        if not path:
            continue
        in_tests = path.startswith("tests/") or "/tests/" in path
        if not in_tests or path.startswith("tests/fixtures/") or "/fixtures/" in path:
            continue
        result.append(path)
    return result


SELF_TEST_SOURCE = '''
import std/os
const TmpDir = "build/test-tmp/fixed"
const
  Fine = "build/test-tmp/x" & "y"
  OutDir = currentSourcePath.parentDir /
    "build" / "test-bin" / "m83"
let Tmp2 = getTempDir() / "fixed-name"
let Ok1 = "build/test-tmp/a" / testCaseScratchSlug()
let Ok2 = "build/test-tmp/b" /
  $getCurrentProcessId()
const ServerBinary = "build/test-bin" / addFileExt("srv", ExeExt)
const Repro = "build/bin/repro"
const Src = """
let inner = "build/test-tmp/inside-a-fixture-string"
"""
# const Commented = "build/test-tmp/comment"
const BinApp = "build/app"
const WorkRoot = "build/m9_work"
proc p() =
  let local = "build/test-tmp/local"
  let out = OutDir / "x.exe"
  createDir(WorkRoot)
'''

SELF_TEST_EXPECTED = {3, 5, 6, 8, 19}


def self_test() -> None:
    got = {line for line, _ in scan(SELF_TEST_SOURCE)}
    if got != SELF_TEST_EXPECTED:
        print("check_fixed_test_scratch_dirs: SELF-TEST FAILED: flagged lines "
              f"{sorted(got)}, expected {sorted(SELF_TEST_EXPECTED)}",
              file=sys.stderr)
        sys.exit(2)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--paths", nargs="*",
                        help="scan these files instead of every test source")
    args = parser.parse_args()
    self_test()
    paths = args.paths if args.paths else test_sources(ROOT)
    if not args.paths and len(paths) < 500:
        print(f"error: only {len(paths)} test sources found; the corpus scan is "
              "too small to trust", file=sys.stderr)
        return 2
    failures = []
    for path in paths:
        text = (ROOT / path).read_text(encoding="utf-8", errors="replace")
        for line_number, hit in scan(text):
            failures.append(f"{path}:{line_number}: {hit}")
    if failures:
        print("error: test sources declare a FIXED scratch path at module level.",
              file=sys.stderr)
        print("  The runner executes each test case as its own process, in "
              "parallel with the", file=sys.stderr)
        print("  binary's other cases, so a fixed directory is shared between "
              "them: one case's", file=sys.stderr)
        print("  reset deletes the files a sibling is still using, and a fixture "
              "compiled to a", file=sys.stderr)
        print("  fixed output is overwritten while a sibling executes it. Make "
              "the path private", file=sys.stderr)
        print("  to the process, e.g. `\"build/test-tmp/<name>\" / "
              "testCaseScratchSlug()`", file=sys.stderr)
        print("  (repro_test_support). See scripts/check_fixed_test_scratch_dirs.py.",
              file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print(f"check_fixed_test_scratch_dirs: OK ({len(paths)} test sources, no "
          "module-level fixed scratch path)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
