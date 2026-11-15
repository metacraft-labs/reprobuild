#!/usr/bin/env python3
"""Refuse a test, benchmark or helper script that kills processes by PATTERN.

WHY THIS EXISTS
===============

Test code, benchmarks and load scripts may signal only the processes they
started: a PID they recorded, or a process group or session they created.
They never kill by name (``pkill <name>``, ``killall <name>``) and never by
command-line pattern (``pkill -f <pattern>``, ``pgrep ... | xargs kill``).

A pattern names whatever happens to match it when the kill runs, not what
the test started. On a shared host -- the CI fleet runs many agent sessions
and CI jobs side by side under one user -- that is every other session's
process of the same shape. An ``ah-cli`` test's ``pkill -f`` killed two agent
sessions on 2026-11-13. Here, ``t_nix_daemon_ipc`` ran ``pkill -f -u $USER
reprobuild-nix-daemon-ipc.sock`` against a FIXED socket path, so every run
stopped every concurrent run's helper, and ten committed run scripts at the
repository root ran ``pkill -KILL -f 'cmake.*reproos'`` and the like, which
stop every matching compiler of every session on the host. A unique-looking
marker does not make a pattern safe: it is still the process table, read at
one instant, deciding what dies. (Recorded as reprobuild-pm issue
2026-11-13, "reprobuild tests and committed root scripts kill processes by
pattern".)

WHAT IS SCANNED
===============

Every tracked file that is executed as test, benchmark or tooling code:
files at the repository root, ``tests/``, ``scripts/``, ``benchmarks/``,
``tools/``, ``.github/``, and every ``tests/`` directory below ``libs/`` and
``apps/`` -- restricted to source and script types (``.nim``, ``.nims``,
``.sh``, ``.bash``, ``.py``, ``.ps1``, ``.yml``, ``.yaml`` and extension-less
files such as ``Justfile``). Product sources (``libs/*/src``, ``apps/``
outside ``tests/``) are not scanned: ``killall <restartTarget>`` there is the
behaviour the ``macos.userDefault`` resource is specified to have, and its
gate drives it against a uniquely named placeholder process. ``references/``
(third-party trees), ``docs/`` and ``recipes/`` (package content, such as a
busybox applet list naming ``killall``) are not test code.

WHAT IS REFUSED
===============

On any line that is not a whole-line comment:

* the word ``pkill`` or ``killall``, which also catches building the command
  by name (``findExe("pkill")``);
* ``pgrep`` or ``pidof`` feeding ``kill`` on the same line -- through
  ``xargs kill`` or ``$(pgrep ...)`` / ``$(pidof ...)`` around a ``kill``.
  A ``pgrep`` that only OBSERVES (``pgrep -f x || break``) is not refused;
* the Windows spellings of the same thing: ``taskkill /IM <image>``,
  ``Stop-Process -Name``, and selecting processes by their command line
  (``$_.CommandLine.Contains(...)``, ``CommandLine -like`` / ``-match``).

A line that must name one of these words without running it (a test case
titled after the product's ``killall`` behaviour, say) carries
``pattern-kill-ok: <reason>`` on that line, or in a whole-line comment
directly above it. The reason is mandatory.

HOW TO SATISFY IT
=================

Keep what you start. ``repro_test_support/owned_processes`` stops a Unix
socket server through the peer credentials of a connection to it
(``stopUnixSocketServer``), and records the session a product command
detaches with ``setsid`` (``installSetsidRecorder``) so the test can stop
exactly that process group (``stopRecordedSessions``). In shell, record
``$!`` or a ``setsid`` session leader's ``$$`` and signal that PID or
``-<pgid>``; inside a test guest, use ``startGuestSession`` /
``stopGuestSession`` from ``tests/e2e/addon/addon_testbed.nim``, or stop a
systemd unit or scope by name.

``python3 scripts/check_pattern_kills.py --self-test`` proves each refused
shape is still caught and each allowed one still passes.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SELF = "scripts/check_pattern_kills.py"

SCANNED_PREFIXES = ("tests/", "scripts/", "benchmarks/", "tools/", ".github/")
NESTED_TEST_ROOTS = ("libs/", "apps/")
SCANNED_SUFFIXES = {".nim", ".nims", ".sh", ".bash", ".py", ".ps1", ".yml",
                    ".yaml", ""}

ANNOTATION = re.compile(r"pattern-kill-ok:\s*\S")

REFUSED = (
    ("kill by name or pattern (pkill)", re.compile(r"\bpkill\b")),
    ("kill by name (killall)", re.compile(r"\bkillall\b")),
    ("pgrep/pidof piped into kill",
     re.compile(r"\b(pgrep|pidof)\b.*\|\s*xargs\b.*\bkill\b")),
    ("kill of a pgrep/pidof result",
     re.compile(r"\$\(\s*(pgrep|pidof)\b.*\bkill\b|\bkill\b.*\$\(\s*(pgrep|pidof)\b")),
    ("kill by image name (taskkill /IM)",
     re.compile(r"\btaskkill\b.*[/-]IM\b", re.IGNORECASE)),
    ("kill by name (Stop-Process -Name)",
     re.compile(r"\bStop-Process\b.*-Name\b", re.IGNORECASE)),
    ("process selected by command line",
     re.compile(r"CommandLine\s*(\.Contains\s*\(|-like\b|-match\b)",
                re.IGNORECASE)),
)


def is_comment(line: str) -> bool:
    stripped = line.lstrip()
    return stripped.startswith("#")


def scan(text: str) -> list[tuple[int, str, str]]:
    """Every refused line of ``text``: (line number, what, the line)."""
    found = []
    annotated_above = False
    for number, line in enumerate(text.splitlines(), start=1):
        if is_comment(line):
            annotated_above = bool(ANNOTATION.search(line))
            continue
        exempt = annotated_above or ANNOTATION.search(line)
        annotated_above = False
        if exempt:
            continue
        for what, pattern in REFUSED:
            if pattern.search(line):
                found.append((number, what, line.strip()))
                break
    return found


def in_scope(path: str) -> bool:
    if path == SELF or path.startswith("references/"):
        return False
    if pathlib.PurePosixPath(path).suffix not in SCANNED_SUFFIXES:
        return False
    if "/" not in path:
        return True
    if path.startswith(SCANNED_PREFIXES):
        return True
    return path.startswith(NESTED_TEST_ROOTS) and "/tests/" in path


def scanned_files(root: pathlib.Path) -> list[str]:
    tracked = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"],
        check=True, capture_output=True, text=True).stdout.split("\0")
    return [p for p in tracked if p and in_scope(p)]


SELF_TEST_SOURCE = '''\
discard execCmd("pkill -f " & quoteShell(socketPath))
let pkill = findExe("pkill")
pkill -KILL -f 'moc$' 2>/dev/null || true
killall -9 ninja
pgrep -f 'sleep 31' | xargs kill -9
for p in $(pgrep -f worker); do kill -TERM $p; done
kill $(pidof validator)
# pkill -f in a whole-line comment is prose
  ## killall in a Nim doc comment is prose
test "restartTarget killall fires":  # pattern-kill-ok: a case title
pgrep -f '[v]alidator-monitor.py' >/dev/null || break
for p in $(pgrep -f 'secret put'); do grep VmLck /proc/$p/status; done
kill -TERM -- "-$pgid"
killall5 is a different word
let x = "nopkillhere"
discard execCmd("killall x")  # pattern-kill-ok:
taskkill /F /IM repro.exe
Stop-Process -Name git -Force
Where-Object { $_.CommandLine.Contains($m) } | ForEach-Object { $_.ProcessId }
taskkill /F /T /PID 4242
Stop-Process -Id 4242
# pattern-kill-ok: a title naming the behaviour
test "killall fires":
# pattern-kill-ok:
test "the reason is mandatory above too: killall":
# pattern-kill-ok: covers only the next line
let a = 1
pkill -f still-refused
'''

SELF_TEST_EXPECTED = {1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19, 25, 28}

SELF_TEST_SCOPE = {
    "_m9r33_iso_build.sh": True,
    "Justfile": True,
    "tests/integration/t_x.nim": True,
    "tests/e2e/addon/addon_testbed.nim": True,
    "libs/repro_addon/tests/t_x.nim": True,
    "apps/reproos-installer/tests/t_x.nim": True,
    "scripts/lib/process_group.sh": True,
    ".github/workflows/ci.yml": True,
    "libs/repro_home_resources/src/repro_home_resources/drivers/defaults.nim": False,
    "recipes/reproos-iso/scripts/build-initramfs.sh": False,
    "references/nix/x.sh": False,
    "docs/x.md": False,
    "README.md": False,
    SELF: False,
}


def self_test() -> list[str]:
    problems = []
    got = {line for line, _, _ in scan(SELF_TEST_SOURCE)}
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
            print(f"check_pattern_kills: SELF-TEST FAILED: {problem}",
                  file=sys.stderr)
        return 2
    if args.self_test:
        print("check_pattern_kills: self-test OK (every refused shape caught, "
              "every allowed shape passed)")
        return 0
    paths = args.paths if args.paths else scanned_files(ROOT)
    if not args.paths and len(paths) < 1000:
        print(f"error: only {len(paths)} files in scope; the scan is too small "
              "to trust", file=sys.stderr)
        return 2
    failures = []
    for path in paths:
        text = (ROOT / path).read_text(encoding="utf-8", errors="replace")
        for number, what, line in scan(text):
            failures.append(f"{path}:{number}: {what}: {line}")
    if failures:
        print("error: test or tooling code kills processes by name or pattern.",
              file=sys.stderr)
        print("  On a shared host a pattern matches other sessions' processes. "
              "Signal only what", file=sys.stderr)
        print("  you started: a recorded PID, or a process group or session "
              "you created. See", file=sys.stderr)
        print("  scripts/check_pattern_kills.py and "
              "repro_test_support/owned_processes.", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print(f"check_pattern_kills: OK ({len(paths)} files, no kill by name or "
          "pattern)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
