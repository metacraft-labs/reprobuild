#!/usr/bin/env python3
"""Refuse importing C's ``environ`` from ``<unistd.h>`` without a macOS branch.

WHY THIS EXISTS
===============

POSIX lets ``<unistd.h>`` declare ``extern char **environ``, and glibc does,
so on Linux

    var environ {.importc, header: "<unistd.h>".}: cstringArray

compiles. macOS's ``<unistd.h>`` does not declare it, so the generated C
dies with ``use of undeclared identifier 'environ'`` and nothing that links
the module builds there. One such declaration in the cargo plan edge
(``libs/repro_cargo_edge``) broke every macOS build of reprobuild, the
engine and ``repro-rustc-wrapper`` alike. There is no macOS host in the
Linux lint, so the compiler cannot catch it there; this scan can.

HOW TO SATISFY IT
=================

Read the environment on macOS through ``_NSGetEnviron()`` from
``<crt_externs.h>`` (Apple's documented accessor, environ(7)), as Nim's own
``std/envvars`` does, and keep the ``<unistd.h>`` declaration in a branch
that macOS does not take::

    when defined(macosx):
      proc nsGetEnviron(): ptr cstringArray {.importc: "_NSGetEnviron",
        header: "<crt_externs.h>".}
    else:
      var environ {.importc, header: "<unistd.h>".}: cstringArray

``libs/repro_cargo_edge/src/repro_cargo_edge/plan_run.nim`` is the worked
example. A declaration is accepted when any ``when`` / ``elif`` / ``else``
chain enclosing it names ``macosx`` in one of its conditions (so
``when not defined(macosx):`` passes too).

WHAT IS SCANNED, AND WHAT IS NOT
================================

Every tracked ``.nim`` file outside the third-party libraries vendored under
``libs/``. A refused line is one that imports ``environ`` (as ``var
environ`` or ``importc: "environ"``) and names ``header: "<unistd.h>"``, on
one line. A header-less ``{.importc.}`` is not refused: Nim then emits its
own ``extern`` declaration, which compiles on macOS and links in an
executable. The enclosing chain is found by indentation, so a ``when`` split
across lines is read by its first line only.

``python3 scripts/check_environ_import.py --self-test`` proves each refused
shape is caught and each accepted shape passes.
"""
import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SELF = "scripts/check_environ_import.py"

# The vendored third-party libraries, as in check_process_stream_readall.py.
VENDORED = tuple(f"libs/{name}/" for name in (
    "nim-faststreams", "nim-json-serialization", "nim-serialization",
    "nim-ssz-serialization", "nim-stew", "nim-toml-serialization",
    "nimcrypto", "results", "stint"))

# A full scan covers about 5700 files. Fewer than this means part of the tree
# is missing and the scan proves nothing.
MINIMUM_FILES = 4000

IMPORTS_ENVIRON = re.compile(
    r"\bvar\s+environ\b[^#]*\{\.[^#}]*\bimportc\b"
    r"|\bimportc\s*:\s*\"environ\"")
UNISTD_HEADER = re.compile(r"\bheader\s*:\s*\"<unistd\.h>\"")
CHAIN_HEADER = re.compile(r"(?:when|elif)\b|else\s*:")
NAMES_MACOS = re.compile(r"\bmacosx\b")


def in_scope(path: str) -> bool:
    if not path.endswith(".nim"):
        return False
    return not path.startswith(VENDORED)


def scanned_files(root: pathlib.Path) -> list[str]:
    out = subprocess.run(["git", "ls-files", "-z"], cwd=root, check=True,
                         capture_output=True, text=True).stdout
    return sorted(p for p in out.split("\0") if p and in_scope(p))


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def code_lines(text: str) -> list[tuple[int, str]]:
    """(line number, line) for every line that is not blank or a comment."""
    return [(n, line) for n, line in enumerate(text.splitlines(), start=1)
            if line.strip() and not line.lstrip().startswith("#")]


def has_macos_branch(lines: list[tuple[int, str]], index: int) -> bool:
    """Whether a ``when`` chain enclosing ``lines[index]`` names macOS."""
    level = indent_of(lines[index][1])
    i = index - 1
    while i >= 0 and level > 0:
        line = lines[i][1]
        indent = indent_of(line)
        if indent >= level:
            i -= 1
            continue
        # The block header that opens this level. If it is part of a
        # when/elif/else chain, read the whole chain upward to its `when`.
        level = indent
        stripped = line.strip()
        while CHAIN_HEADER.match(stripped):
            if NAMES_MACOS.search(stripped):
                return True
            if stripped.startswith("when"):
                break
            i -= 1
            while i >= 0 and indent_of(lines[i][1]) > level:
                i -= 1
            if i < 0 or indent_of(lines[i][1]) != level:
                break
            stripped = lines[i][1].strip()
        i -= 1
    return False


def scan(text: str) -> list[tuple[int, str]]:
    """Every refused line of ``text``: (line number, the line)."""
    lines = code_lines(text)
    found = []
    for index, (number, line) in enumerate(lines):
        if IMPORTS_ENVIRON.search(line) and UNISTD_HEADER.search(line):
            if not has_macos_branch(lines, index):
                found.append((number, line.strip()))
    return found


SELF_TEST_SOURCE = """\
var environ {.importc, header: "<unistd.h>".}: cstringArray
when defined(posix):
  var environ {.importc, header: "<unistd.h>".}: cstringArray
when defined(posix):
  when defined(macosx):
    proc nsGetEnviron(): ptr cstringArray {.importc: "_NSGetEnviron",
      header: "<crt_externs.h>".}
  else:
    var environ {.importc, header: "<unistd.h>".}: cstringArray
when not defined(macosx):
  var environ {.importc, header: "<unistd.h>".}: cstringArray
var environ {.importc.}: cstringArray
# var environ {.importc, header: "<unistd.h>".}: cstringArray
var env {.importc: "environ", header: "<unistd.h>".}: cstringArray
when defined(linux):
  discard
elif defined(macosx):
  discard
elif defined(posix):
  var environ {.importc, header: "<unistd.h>".}: cstringArray
when defined(windows):
  discard
else:
  proc f() =
    var environ {.importc, header: "<unistd.h>".}: cstringArray
var other {.importc, header: "<unistd.h>".}: cint
"""
SELF_TEST_EXPECTED = {1, 3, 14, 25}

SELF_TEST_SCOPE = {
    "libs/repro_cargo_edge/src/repro_cargo_edge/plan_run.nim": True,
    "libs/repro_cargo_edge/tests/t_x.nim": True,
    "apps/repro/repro.nim": True,
    "tests/integration/t_x.nim": True,
    "recipes/x/repro.nim": True,
    "libs/nim-stew/src/stew/io2.nim": False,
    "scripts/x.py": False,
    SELF: False,
}


def self_test() -> list[str]:
    problems = []
    got = {n for n, _ in scan(SELF_TEST_SOURCE)}
    if got != SELF_TEST_EXPECTED:
        problems.append(f"flagged lines {sorted(got)}, expected "
                        f"{sorted(SELF_TEST_EXPECTED)}")
    for path, expected in SELF_TEST_SCOPE.items():
        if in_scope(path) != expected:
            problems.append(f"{path}: in scope = {in_scope(path)}, expected "
                            f"{expected}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--self-test", action="store_true",
                        help="only prove the scanner's power, scan nothing")
    parser.add_argument("--paths", nargs="*",
                        help="scan these files instead of every scanned file")
    args = parser.parse_args()
    problems = self_test()
    if problems:
        for problem in problems:
            print(f"check_environ_import: SELF-TEST FAILED: {problem}",
                  file=sys.stderr)
        return 2
    if args.self_test:
        print("check_environ_import: self-test OK")
        return 0
    paths = args.paths if args.paths else scanned_files(ROOT)
    if not args.paths and len(paths) < MINIMUM_FILES:
        print(f"error: only {len(paths)} files in scope; the scan is too small "
              "to trust", file=sys.stderr)
        return 2
    failures = []
    for path in paths:
        text = (ROOT / path).read_text(encoding="utf-8", errors="replace")
        for number, line in scan(text):
            failures.append(f"{path}:{number}: {line}")
    if failures:
        print("error: `environ` imported from <unistd.h> without a macOS "
              "branch; macOS's <unistd.h> does not declare it.",
              file=sys.stderr)
        print("  Read it through _NSGetEnviron() on macOS. See "
              "scripts/check_environ_import.py.", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print(f"check_environ_import: OK ({len(paths)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
