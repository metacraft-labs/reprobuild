#!/usr/bin/env python3
"""Refuse ``Stream.readAll`` on a child process's output or error stream.

WHY THIS EXISTS
===============

``streams.readAll`` reads in 1 KiB blocks and stops at the first read that
returns fewer bytes (``if readBytes < bufferSize: break``). That is end of
file for a file and "the writer has not written the rest yet" for a pipe.
On Windows ``osproc``'s stream is a raw handle and one ``ReadFile`` per read,
so a child that writes its answer in more than one write is cut at the first
short read: ``dotnet msbuild -getProperty`` was cut after 256 bytes in the
middle of a JSON string. On POSIX ``fread`` hides it. (Recorded as
reprobuild-pm issue 2026-10-27, "Process output read with ``Stream.readAll``
stops at the first short read".)

HOW TO SATISFY IT
=================

Read a process stream with ``drainStream`` from
``repro_core/process_streams``: it reads until a read returns 0 bytes, so the
answer does not depend on how the child chunked its writes.

A site that must NOT wait for end of input (a descendant of the child may
hold the pipe's write end open) cannot use ``readAll`` as a bounded read
either, since that is only cut short on one platform. It uses a bounded read
(``tools/test-runner``'s ``drainProbePipe``) or, where that is not
worth it, declares the waiver on the line, or in a whole-line comment
directly above it::

    helperOutput = process.outputStream.readAll() # readall-ok: <reason>

The reason is mandatory.

WHAT IS SCANNED
===============

Every tracked ``.nim`` file outside the third-party libraries vendored under
``libs/``: product and tool sources, recipes and examples, and test,
benchmark and test-support code as well. A test
that reads its child with ``readAll`` checks less than it claims on Windows,
or fails there: ``t_dev_env_msvc_activation`` got the first of its child's
two lines on every run (reprobuild-pm issue 2026-11-16, "Test code reads
child output with ``Stream.readAll``"). The scan sees two syntactic shapes,
``<expr>.outputStream.readAll()`` / ``.errorStream`` (with or without call
parentheses, which may hold the process: ``outputStream(p).readAll()``) and
``readAll(<expr>.outputStream)``, each on one line, and the ``peekable``
streams the same way. It does not see a stream bound to a
name first, a call split over two lines, or a stream that is itself the
result of a call inside ``readAll(...)``; a reviewer still has to. Bind the
stream and call ``drainStream`` on it instead.

``python3 scripts/check_process_stream_readall.py --self-test`` proves each
shape listed above is caught and each allowed shape passes.
"""
import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SELF = "scripts/check_process_stream_readall.py"

# Vendored third-party libraries under libs/ that are not Metacraft code: the
# ones libs/third_party_sources.txt lists, and nim-toml-serialization, which
# it omits. A waiver cannot be written into them. blake3, cbor, gxhash and
# xxh3 are Metacraft's own code (libs/README.md) and are scanned.
VENDORED = tuple(f"libs/{name}/" for name in (
    "nim-faststreams", "nim-json-serialization", "nim-serialization",
    "nim-ssz-serialization", "nim-stew", "nim-toml-serialization",
    "nimcrypto", "results", "stint"))

# A full scan covers about 5700 files, 1950 of them under ``tests/``. Fewer
# than this means part of the tree is missing and the scan proves nothing.
MINIMUM_FILES = 4000

ANNOTATION = re.compile(r"readall-ok:\s*\S")
REFUSED = re.compile(
    r"\b(?:outputStream|errorStream|peekableOutputStream|peekableErrorStream)"
    r"\s*(?:\([^()#]*\))?\s*\.\s*readAll\b"
    r"|\breadAll\s*\(\s*[^()#]*\b(?:outputStream|errorStream|"
    r"peekableOutputStream|peekableErrorStream)\b")


def in_scope(path: str) -> bool:
    if not path.endswith(".nim"):
        return False
    return not path.startswith(VENDORED)


def scanned_files(root: pathlib.Path) -> list[str]:
    out = subprocess.run(["git", "ls-files", "-z"], cwd=root, check=True,
                         capture_output=True, text=True).stdout
    return sorted(p for p in out.split("\0") if p and in_scope(p))


def scan(text: str) -> list[tuple[int, str]]:
    """Every refused line of ``text``: (line number, the line)."""
    found = []
    annotated_above = False
    for number, line in enumerate(text.splitlines(), start=1):
        if line.lstrip().startswith("#"):
            annotated_above = bool(ANNOTATION.search(line))
            continue
        exempt = annotated_above or ANNOTATION.search(line)
        annotated_above = False
        if not exempt and REFUSED.search(line):
            found.append((number, line.strip()))
    return found


SELF_TEST_SOURCE = """\
let a = p.outputStream.readAll()
let b = p.errorStream.readAll().strip()
let c = p.outputStream().readAll()
let d = child.outputStream
  .readAll()
let e = drainStream(p.outputStream)
let f = f.readAll()
# let g = p.outputStream.readAll()
let h = p.outputStream.readAll() # readall-ok: descendant holds the pipe
# readall-ok: descendant holds the pipe
let i = p.outputStream.readAll()
let j = p.outputStream.readAll()
# readall-ok:
let k = p.outputStream.readAll()
let l = streams.readAll(p.outputStream)
let m = readAll(p.errorStream())
let n = readAll(f)
let o = readAll(p.outputStream) # readall-ok: descendant holds the pipe
let q = p.peekableOutputStream.readAll()
let r = outputStream(p).readAll()
"""
# Lines 4-5 (a call split over two lines) are not recognised: see the header.
SELF_TEST_EXPECTED = {1, 2, 3, 12, 14, 15, 16, 19, 20}

SELF_TEST_SCOPE = {
    "libs/repro_core/src/repro_core/process_streams.nim": True,
    "libs/repro_build_engine/src/repro_build_engine.nim": True,
    "apps/repro-trampoline/repro_trampoline.nim": True,
    "tools/test-runner/repro_test_runner.nim": True,
    "libs/repro_core/tests/t_x.nim": True,
    "libs/repro_test_support/src/repro_test_support/output_drain.nim": True,
    "tools/catalog-harvester/tests/t_x.nim": True,
    "apps/repro-trampoline/tests/t_x.nim": True,
    "tests/unit/t_x.nim": True,
    "tests/windows/x.nim": True,
    "benchmarks/lib/x.nim": True,
    "tests/unit/t_x.py": False,
    "libs/nim-stew/src/stew/io2.nim": False,
    "libs/nim-faststreams/tests/test_x.nim": False,
    "libs/blake3/src/blake3.nim": True,
    "recipes/x/repro.nim": True,
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
            print(f"check_process_stream_readall: SELF-TEST FAILED: {problem}",
                  file=sys.stderr)
        return 2
    if args.self_test:
        print("check_process_stream_readall: self-test OK")
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
        print("error: Stream.readAll on a child process's output stops at the "
              "first short read.", file=sys.stderr)
        print("  Use drainStream from repro_core/process_streams. See "
              "scripts/check_process_stream_readall.py.", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print(f"check_process_stream_readall: OK ({len(paths)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
