#!/usr/bin/env python3
"""Compile, syntax only, the C that Nim generated for a Windows target.

    check_windows_generated_c.py NIMCACHE CC

NIMCACHE is a nimcache written by `nim c --compileOnly --genScript:on
--os:windows <entry>.nim` (scripts/check_portable_engine_closure.sh makes
one). Its `<entry>.json` lists every C file of the image with the exact
command Nim would have run on Windows. CC is a MinGW-w64 gcc for the same
target (the dev shell's REPRO_WINDOWS_CC). Each command is rerun with CC in
place of `gcc.exe` and `-fsyntax-only` in place of `-c ... -o <object>`:
the preprocessor reads the MinGW headers and the front end checks every
declaration, but nothing is assembled or linked.

WHY. Generating C for `--os:windows` proves the Nim half -- that every
module type-checks for the target. It cannot see a `{.importc.}` binding to
a function the target's headers do not declare: `from std/posix import
realpath` type-checks for Windows, and only MinGW's gcc rejects the call
(`implicit declaration of function 'realpath'`). That is how
`5dfbf471d3` left Windows without an engine until `1a064bc4b8`, with every
Linux gate green (reprobuild-pm issue
2026-11-15-windows-repro-engine-does-not-compile-service-floor-calls-posix-realpath).

WHAT IT DOES NOT PROVE. That the image links (a missing import library is
not seen) or runs. Build on Windows before moving a pin.

Exit 0 when every file compiles, 1 when any does (each failure is printed
with the compiler's diagnostic), 2 on a usage or input error.
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# Promoted explicitly: gcc 14 already makes both an error, but the commands
# Nim writes carry `-w`, and this gate must not depend on the compiler's
# default for the defect class it exists to catch.
STRICT_FLAGS = [
    "-Werror=implicit-function-declaration",
    "-Werror=int-conversion",
]


def syntax_command(compile_cmd: str, source: str, cc: str) -> list[str]:
    """Nim's compile command for `source`, run by `cc` as a syntax check.

    Nim names the source by its basename relative to the object directory,
    so the last argument is replaced by the absolute path it recorded.
    """
    args = shlex.split(compile_cmd)
    if len(args) < 2:
        raise ValueError(f"unexpected compile command: {compile_cmd!r}")
    out = [cc]
    i = 1
    last = len(args) - 1
    while i < len(args):
        arg = args[i]
        if arg == "-o":
            i += 2
            continue
        if arg == "-c":
            out.append("-fsyntax-only")
        elif i == last:
            out.append(source)
        else:
            out.append(arg)
        i += 1
    out.extend(STRICT_FLAGS)
    return out


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    cache, cc = Path(argv[1]), argv[2]
    scripts = sorted(cache.glob("*.json"))
    scripts = [p for p in scripts if not p.name.startswith("macro_sourcemap")]
    if len(scripts) != 1:
        print(f"check_windows_generated_c: expected one compile script in "
              f"{cache}, found {[p.name for p in scripts]}", file=sys.stderr)
        return 2
    entries = json.loads(scripts[0].read_text()).get("compile", [])
    # An empty list is not a pass: it means the codegen did not run, or wrote
    # its commands elsewhere, and nothing was checked.
    if not entries:
        print(f"check_windows_generated_c: {scripts[0]} lists no C files; "
              f"nothing was checked", file=sys.stderr)
        return 2

    def run(entry: list[str]) -> tuple[str, int, str]:
        source, command = entry
        proc = subprocess.run(syntax_command(command, source, cc), cwd=cache,
                              capture_output=True, text=True)
        return source, proc.returncode, proc.stderr

    failed = 0
    with ThreadPoolExecutor(min(os.cpu_count() or 1, 16)) as pool:
        for source, code, stderr in pool.map(run, entries):
            if code != 0:
                failed += 1
                print(f"check_windows_generated_c: {source} does not compile "
                      f"for Windows:", file=sys.stderr)
                print(stderr.rstrip()[:4000], file=sys.stderr)
    if failed:
        print(f"check_windows_generated_c: {failed} of {len(entries)} C "
              f"file(s) do not compile with {cc}", file=sys.stderr)
        return 1
    print(f"check_windows_generated_c: {len(entries)} C file(s) compile "
          f"with {cc}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
