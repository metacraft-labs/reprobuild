#!/usr/bin/env python3
"""Remove test executables from a bin dir that this revision does not declare.

WHY THIS EXISTS
---------------
The suite runner (``tools/test-runner/repro_test_runner.nim``,
``scanTestBinaries``) executes every executable in ``--bin-dir`` whose stem
starts with ``t_`` or ``test_``. It does not read ``repro_tests.nim``; its
contract is "run what is in the directory", and its own tests rely on that by
handing it scratch directories of synthetic binaries.

``scripts/run_tests.sh`` wipes ``build/test-bin`` before a cold run, so on a
cold run the directory holds exactly what ``.#test-builds`` just produced, which
is exactly the declared set. A WARM run (``REPROBUILD_TEST_WARM_REUSE=1``) keeps
the directory, and with it every binary an EARLIER revision declared. A test
that was removed, renamed or moved out of the suite then keeps running from its
last binary and is counted in the totals: measured on run 14, two HCR drivers
that d2f6b85e0 had moved to ``tests/fixtures/hcr/`` ran from two-day-old
binaries and were reported as failures.

So the directory is reconciled with the declaration here, before the runner
walks it, rather than by changing the runner's contract. The declared set is
not re-encoded: it is read with ``reprobuild_suite_inventory.parse_repro_tests``,
the same parser the case-count baseline and the source-scan lints use, so the
suite has one definition of "what the suite is".

WHAT IS AND IS NOT TOUCHED
--------------------------
Only files the runner would execute are candidates: a regular, executable file
whose stem (``.exe`` removed) starts with ``t_`` or ``test_`` -- the runner's
``looksLikeTestStem`` predicate. Helper executables without that prefix are
left alone (the runner ignores them), and so is every declared binary, whatever
its ``targetOs``. Nothing is removed if ``repro_tests.nim`` parses to an empty
declared set: an empty parse is a parser failure, not a revision with no tests,
and acting on it would delete the whole warm tree.

Usage::

    python3 scripts/prune_undeclared_test_binaries.py [--root <repo>] \
        [--bin-dir build/test-bin] [--dry-run]

Prints one ``pruned: <name>`` line per removed file and a summary line.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import pathlib
import sys

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
INVENTORY = SCRIPT_DIR / "reprobuild_suite_inventory.py"

_spec = importlib.util.spec_from_file_location("reprobuild_suite_inventory", INVENTORY)
assert _spec is not None and _spec.loader is not None
inventory = importlib.util.module_from_spec(_spec)
sys.modules["reprobuild_suite_inventory"] = inventory
_spec.loader.exec_module(inventory)


def looks_like_test_stem(stem: str) -> bool:
    """Mirror of the runner's ``looksLikeTestStem``."""
    return stem.startswith("t_") or stem.startswith("test_")


def declared_binary_stems(root: pathlib.Path) -> set[str]:
    nim_specs, _ = inventory.parse_repro_tests(root)
    return {pathlib.PurePosixPath(spec.binary).name for spec in nim_specs}


def runner_candidates(bin_dir: pathlib.Path) -> list[pathlib.Path]:
    """Files the runner's ``scanTestBinaries`` would pick up."""
    out: list[pathlib.Path] = []
    if not bin_dir.is_dir():
        return out
    for entry in sorted(bin_dir.iterdir()):
        if entry.is_symlink() or not entry.is_file():
            continue
        name = entry.name
        if os.name == "nt":
            if not name.endswith(".exe"):
                continue
            stem = name[: -len(".exe")]
        else:
            if not os.access(entry, os.X_OK):
                continue
            stem = name
        if looks_like_test_stem(stem):
            out.append(entry)
    return out


def undeclared(bin_dir: pathlib.Path, declared: set[str]) -> list[pathlib.Path]:
    result = []
    for path in runner_candidates(bin_dir):
        stem = path.name[: -len(".exe")] if path.name.endswith(".exe") else path.name
        if stem not in declared:
            result.append(path)
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--bin-dir", default="build/test-bin")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    root = pathlib.Path(args.root).resolve()
    bin_dir = pathlib.Path(args.bin_dir)
    if not bin_dir.is_absolute():
        bin_dir = root / bin_dir

    declared = declared_binary_stems(root)
    if not declared:
        print(
            "prune_undeclared_test_binaries: refusing: repro_tests.nim declares "
            "no test binaries, which is a parse failure rather than an empty "
            "suite; nothing removed",
            file=sys.stderr,
        )
        return 2

    stale = undeclared(bin_dir, declared)
    for path in stale:
        print(f"pruned: {path.name}" if not args.dry_run else f"would prune: {path.name}")
        if not args.dry_run:
            path.unlink()
    print(
        f"prune_undeclared_test_binaries: {len(stale)} undeclared test "
        f"binar{'y' if len(stale) == 1 else 'ies'} "
        f"{'found in' if args.dry_run else 'removed from'} {bin_dir} "
        f"({len(declared)} declared)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
