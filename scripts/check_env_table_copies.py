#!/usr/bin/env python3
"""Refuse a case-sensitive copy of the inherited environment in a file that
names the search path ``PATH``.

WHY THIS EXISTS
===============

Windows environment variable names are case-insensitive, and the inherited
search path is spelled ``Path``
(https://learn.microsoft.com/en-us/windows/win32/procthread/environment-variables).
A copy of ``envPairs()`` kept in a case-SENSITIVE ``strtabs`` table, followed
by ``env["PATH"] = …``, holds two entries for one variable. The child's
environment block carries both, and which one the child reads depends on
the order the block was written in, so the value the caller set can be
dropped without an error. In ``tests/e2e/m83/profile_compile_edge_harness.nim`` that kept a
``PATH`` spy off the compile's search path: every spawn count read 0 and
the checks that counted compiler launches were red or passed without
measuring anything. A read has the mirror defect: ``getOrDefault("PATH")``
on such a copy finds no ``Path`` and returns ``""``.

HOW TO SATISFY IT
=================

Build the table with ``repro_core/process_env``, which gives it the host's
name semantics::

    var env = inheritedEnvTable()        # a copy of this process's environment
    env.prependPathEntry(toolDir)        # extends the inherited Path in place
    env["PATH"] = onlyThisDir            # replaces it; still one entry

    result = newEnvTable()               # a filtered copy
    for name, value in inheritedEnvTable():
      if keep(name): result[name] = value

A table that must stay case-sensitive on every host (it is not an
environment, or the test is about the case-sensitive result) declares the
waiver on the constructor's line, or in a whole-line comment directly above
it::

    var raw = newStringTable(modeCaseSensitive) # env-case-ok: <reason>

The reason is mandatory.

WHAT IS SCANNED
===============

Every tracked ``.nim`` file outside vendored third-party libraries and
outside ``repro_core/process_env.nim`` itself, product and test code alike.
A line is refused when all three hold:

* it calls ``newStringTable(`` and neither that line nor the next names an
  insensitive mode or ``envNameMode`` (so ``newStringTable()``,
  ``newStringTable(modeCaseSensitive)``, ``mode = modeCaseSensitive`` and a
  mode held in a variable all count as case-sensitive);
* that line, or one of the next ``COPY_WINDOW`` code lines (blank and
  comment lines are not counted), reads the inherited environment with
  ``envPairs`` or ``inheritedEnvTable``, with no other table constructor in
  between;
* the file names the search path anywhere outside a whole-line comment:
  ``["PATH"]``, ``("PATH"``, ``(name: "PATH"``, ``"PATH" in``,
  ``getOrDefault`` / ``hasKey`` / ``contains`` / ``del`` with ``"PATH"``
  (or ``"Path"``), or a call of ``prependPathEntry``.

The third condition is per file, not per table: the scan does not follow a
table through procs. It keeps the gate on the shape that was measured to
break; a case-sensitive copy in a file that never names ``PATH`` is not
refused here.

WHAT IT DOES NOT SEE
====================

* A copy made in one file and given its ``PATH`` in another (a fixture
  module whose callers set it). Build exported environment tables with
  ``process_env`` whether or not the module itself names ``PATH``.
* ``PATH`` named through a constant or a variable.
* A copy whose loop starts more than ``COPY_WINDOW`` code lines after the
  constructor, or a ``Table[string, string]`` used as an environment.

It can also refuse a file that is not defective: the ``PATH`` condition
matches a string ``contains("PATH")`` and text in a trailing comment or a
string literal. Building the table with ``process_env`` is right there
too, and the waiver is available.

``python3 scripts/check_env_table_copies.py --self-test`` proves each shape
listed above as refused is caught and each allowed shape passes.
"""
import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
NAME = "check_env_table_copies"

# Vendored third-party libraries under libs/ that are not Metacraft code.
VENDORED = ("libs/nim-stew/",)
# The one module that may spell the table's mode out.
HELPER = "libs/repro_core/src/repro_core/process_env.nim"

# How many lines after a constructor the ``envPairs`` loop may start on.
COPY_WINDOW = 8

ANNOTATION = re.compile(r"env-case-ok:\s*\S")
ANY_CONSTRUCTOR = re.compile(r"\bnew(StringTable|EnvTable)\b|"
                             r"\b(inheritedEnvTable|envTableFrom)\b")
STRTABS_CONSTRUCTOR = re.compile(r"\bnewStringTable\s*\(")
HOST_SEMANTICS = re.compile(r"Insensitive|\benvNameMode\b")
COPY = re.compile(r"\b(envPairs|inheritedEnvTable)\b")
PATH_NAME = r"\"(PATH|Path)\""
PATH_KEY = re.compile(
    r"\[\s*" + PATH_NAME + r"\s*\]|"
    r"\(\s*" + PATH_NAME + r"\s*,|"
    r"\(\s*name\s*:\s*" + PATH_NAME + r"\s*,|"
    + PATH_NAME + r"\s+(in|notin)\b|"
    r"\b(getOrDefault|hasKey|contains|del)\s*\(\s*" + PATH_NAME + r"|"
    r"\bprependPathEntry\b")


def in_scope(path: str) -> bool:
    if not path.endswith(".nim"):
        return False
    if path.startswith(VENDORED):
        return False
    return path != HELPER


def scanned_files(root: pathlib.Path) -> list[str]:
    out = subprocess.run(["git", "ls-files", "-z"], cwd=root, check=True,
                         capture_output=True, text=True).stdout
    return sorted(p for p in out.split("\0") if p and in_scope(p))


def is_comment(line: str) -> bool:
    return line.lstrip().startswith("#")


def scan(text: str) -> list[tuple[int, str]]:
    """Every refused line of ``text``: (line number, the line)."""
    lines = text.splitlines()
    code = [("" if is_comment(line) else line) for line in lines]
    if not any(PATH_KEY.search(line) for line in code):
        return []
    found = []
    for index, line in enumerate(code):
        if not STRTABS_CONSTRUCTOR.search(line):
            continue
        following = code[index + 1] if index + 1 < len(code) else ""
        if HOST_SEMANTICS.search(line) or (
                line.count("(") > line.count(")") and
                HOST_SEMANTICS.search(following)):
            continue
        if ANNOTATION.search(lines[index]):
            continue
        if index > 0 and is_comment(lines[index - 1]) and \
                ANNOTATION.search(lines[index - 1]):
            continue
        if COPY.search(line):
            found.append((index + 1, lines[index].strip()))
            continue
        later_code = [text for text in code[index + 1:] if text.strip()]
        for later in later_code[:COPY_WINDOW]:
            if COPY.search(later):
                found.append((index + 1, lines[index].strip()))
                break
            if ANY_CONSTRUCTOR.search(later):
                break
    return found


SELF_TEST_REFUSED = """\
var a = newStringTable(modeCaseSensitive)
for k, v in envPairs():
  a[k] = v
a["PATH"] = dir
var b = newStringTable()
for k, v in envPairs(): b[k] = v
proc c(): StringTableRef =
  result = newStringTable( modeCaseSensitive )
  # a comment between the constructor and the loop
  for key, value in envPairs():
    if key != "X": result[key] = value
var d = inheritedEnvTable()
var e = newEnvTable()
for k, v in envPairs(): e[k] = v
var f = newStringTable(modeCaseInsensitive)
for k, v in envPairs(): f[k] = v
var g = newStringTable(modeCaseSensitive)
g["ONLY"] = "set by name, not a copy"
var h = newStringTable(modeCaseSensitive)
var i = newEnvTable()
for k, v in envPairs(): i[k] = v
var j = newStringTable(modeCaseSensitive) # env-case-ok: the case under test
for k, v in envPairs(): j[k] = v
# env-case-ok: the case under test
var k = newStringTable(modeCaseSensitive)
for name, value in envPairs(): k[name] = value
# env-case-ok:
var l = newStringTable(modeCaseSensitive)
for name, value in envPairs(): l[name] = value
# var m = newStringTable(modeCaseSensitive)
# for name, value in envPairs(): m[name] = value
var n = newStringTable(
  modeCaseSensitive)
for name, value in envPairs(): n[name] = value
var o = newStringTable(mode = modeCaseSensitive)
for name, value in envPairs(): o[name] = value
var p = newStringTable(strtabs.modeCaseSensitive)
for name, value in envPairs(): p[name] = value
var q = newStringTable(
  when defined(windows): modeCaseInsensitive else: modeCaseSensitive)
for name, value in envPairs(): q[name] = value
var r = newStringTable(modeCaseSensitive)
for name, value in inheritedEnvTable(): r[name] = value
var s = newStringTable(modeCaseSensitive)
# one

# two

# three

# four

# five
for name, value in envPairs(): s[name] = value
var t = newStringTable(envNameMode())
for name, value in envPairs(): t[name] = value
var u = newStringTable(modeCaseSensitive)
u["A"] = "1"
u["B"] = "2"
u["C"] = "3"
u["D"] = "4"
u["E"] = "5"
u["F"] = "6"
u["G"] = "7"
u["H"] = "8"
for name, value in envPairs(): u[name] = value
"""
SELF_TEST_EXPECTED = {1, 5, 8, 28, 32, 35, 37, 42, 44}

# The same copy, in files that do and do not use ``"PATH"`` as a key.
SELF_TEST_COPY = """\
var env = newStringTable()
for k, v in envPairs():
  env[k] = v
"""
SELF_TEST_PATH_USES = {
    'env["PATH"] = dir\n': True,
    'env[ "PATH" ] = dir\n': True,
    'let old = env.getOrDefault("PATH")\n': True,
    'if env.hasKey("PATH"): discard\n': True,
    'env.del("PATH")\n': True,
    'if env.contains("PATH"): discard\n': True,
    'for (k, v) in [("PATH", dir)]: env[k] = v\n': True,
    'for (k, v) in @[(name: "PATH", value: dir)]: env[k] = v\n': True,
    'for (k, v) in @[(name: "HOME", value: dir)]: env[k] = v\n': False,
    'if "PATH" in env: discard\n': True,
    'env["Path"] = dir\n': True,
    'env.prependPathEntry(dir)\n': True,
    'env["HOME"] = dir\n': False,
    'let old = getEnv("PATH")\n': False,
    '# env["PATH"] = dir\n': False,
    'env["LD_LIBRARY_PATH"] = dir\n': False,
}

SELF_TEST_SCOPE = {
    "libs/repro_core/src/repro_core/process_streams.nim": True,
    "libs/repro_core/tests/t_x.nim": True,
    "tests/unit/t_x.nim": True,
    "tools/test-runner/repro_test_runner.nim": True,
    "repro.nim": True,
    HELPER: False,
    "libs/nim-stew/src/stew/io2.nim": False,
    "scripts/x.py": False,
}


def self_test() -> list[str]:
    problems = []
    got = {n for n, _ in scan(SELF_TEST_REFUSED)}
    if got != SELF_TEST_EXPECTED:
        problems.append(f"flagged lines {sorted(got)}, expected "
                        f"{sorted(SELF_TEST_EXPECTED)}")
    for use, expected in SELF_TEST_PATH_USES.items():
        flagged = bool(scan(SELF_TEST_COPY + use))
        if flagged != expected:
            problems.append(f"copy followed by {use.strip()!r}: flagged = "
                            f"{flagged}, expected {expected}")
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
            print(f"{NAME}: SELF-TEST FAILED: {problem}", file=sys.stderr)
        return 2
    if args.self_test:
        print(f"{NAME}: self-test OK")
        return 0
    paths = args.paths if args.paths else scanned_files(ROOT)
    if not args.paths and len(paths) < 500:
        print(f"error: only {len(paths)} files in scope; the scan is too small "
              "to trust", file=sys.stderr)
        return 2
    failures = []
    for path in paths:
        text = (ROOT / path).read_text(encoding="utf-8", errors="replace")
        for number, line in scan(text):
            failures.append(f"{path}:{number}: {line}")
    if failures:
        print("error: a case-sensitive copy of the environment in a file that "
              "names PATH gives a Windows child both Path and PATH.",
              file=sys.stderr)
        print("  Build it with inheritedEnvTable() / newEnvTable() from "
              "repro_core/process_env. See scripts/check_env_table_copies.py.",
              file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print(f"{NAME}: OK ({len(paths)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
