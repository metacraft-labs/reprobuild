#!/usr/bin/env python3
"""A warm suite run executes only the test binaries this revision declares.

WHAT THIS PROTECTS
------------------
The suite runner executes every ``t_*``/``test_*`` executable in its
``--bin-dir`` and does not read ``repro_tests.nim``. ``scripts/run_tests.sh``
keeps ``build/test-bin`` across runs when ``REPROBUILD_TEST_WARM_REUSE=1``, so
a test removed from the suite kept running from its last binary. Measured on
full-suite run 14: ``test_hax_m2_macho_lazy_symbol_and_vtable_interception``
and ``test_hax_m3_cli_watcher_triggers_compilation_and_patch_push``, moved out
of the suite by d2f6b85e0, ran from two-day-old binaries and were counted as
failures. ``scripts/prune_undeclared_test_binaries.py`` reconciles the
directory with the declaration before the runner walks it.

WHAT IS ASSERTED
----------------
1. Against the REAL ``repro_tests.nim``: in a bin dir holding one declared test
   binary, the two binaries run 14 executed as ghosts, a helper executable
   without a test prefix, a non-executable ``t_`` file and a ``t_`` symlink,
   exactly the two ghosts are removed. The declared binary surviving is the
   control -- a pruner that deleted every ``t_*`` file would remove the ghosts
   too. The ghosts are first shown to be undeclared, so the case cannot pass
   because they happened to be declared again.
2. ``--dry-run`` names the same files and removes nothing.
3. A ``repro_tests.nim`` that parses to no declared binaries is REFUSED with a
   non-zero exit and nothing is removed: an empty parse is a parser failure,
   and acting on it would empty the warm tree.
4. The prune's predicate mirrors the runner's: the runner's
   ``looksLikeTestStem`` still reads ``t_``/``test_``. If the runner's
   predicate changes, the mirror is stale and this says so.
5. ``run_tests.sh`` actually calls the pruner, unconditionally, and before the
   first runner invocation that walks ``build/test-bin``. Comments are stripped
   first: a commented-out call is not a call.

NO MOCKS
--------
The real script, the real ``repro_tests.nim``, the real runner source and the
real ``run_tests.sh``; bin dirs are real directories of real files.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "prune_undeclared_test_binaries.py"
RUN_TESTS = ROOT / "scripts" / "run_tests.sh"
RUNNER = ROOT / "tools" / "test-runner" / "repro_test_runner.nim"
REPRO_TESTS = ROOT / "repro_tests.nim"

GHOSTS = (
    "test_hax_m2_macho_lazy_symbol_and_vtable_interception",
    "test_hax_m3_cli_watcher_triggers_compilation_and_patch_push",
)


def declared_stems() -> list[str]:
    return re.findall(r'binary:\s*"build/test-bin/([^"]+)"', REPRO_TESTS.read_text())


def make_exe(path: Path) -> None:
    path.write_text("#!/bin/sh\nexit 0\n")
    path.chmod(0o755)


def run_prune(root: Path, bin_dir: Path, *extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--root", str(root), "--bin-dir", str(bin_dir), *extra],
        capture_output=True,
        text=True,
        check=False,
    )


def strip_shell_comments(text: str) -> str:
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


class PruneUndeclaredTestBinaries(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="prune-test-bin-"))
        self.bin_dir = self.tmp / "test-bin"
        self.bin_dir.mkdir()

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def populate(self) -> str:
        declared = declared_stems()
        self.assertGreater(len(declared), 100, "repro_tests.nim declares suspiciously few binaries")
        for ghost in GHOSTS:
            self.assertNotIn(ghost, declared, ghost + " is declared again; pick another ghost")
        keep = declared[0]
        make_exe(self.bin_dir / keep)
        for ghost in GHOSTS:
            make_exe(self.bin_dir / ghost)
        make_exe(self.bin_dir / "some_fixture_helper")
        (self.bin_dir / "t_not_executable").write_text("data\n")
        os.symlink(self.bin_dir / keep, self.bin_dir / "t_symlinked_elsewhere")
        return keep

    def test_removes_exactly_the_undeclared_test_binaries(self) -> None:
        keep = self.populate()
        before = sorted(p.name for p in self.bin_dir.iterdir())
        result = run_prune(ROOT, self.bin_dir)
        self.assertEqual(result.returncode, 0, result.stderr)
        after = sorted(p.name for p in self.bin_dir.iterdir())
        self.assertEqual(sorted(set(before) - set(after)), sorted(GHOSTS))
        self.assertIn(keep, after)
        for ghost in GHOSTS:
            self.assertIn("pruned: " + ghost, result.stdout)

    def test_dry_run_names_the_same_files_and_removes_nothing(self) -> None:
        self.populate()
        before = sorted(p.name for p in self.bin_dir.iterdir())
        result = run_prune(ROOT, self.bin_dir, "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(p.name for p in self.bin_dir.iterdir()), before)
        named = sorted(re.findall(r"^would prune: (\S+)$", result.stdout, re.M))
        self.assertEqual(named, sorted(GHOSTS))

    def test_an_empty_declaration_is_refused_and_removes_nothing(self) -> None:
        fake_root = self.tmp / "repo"
        fake_root.mkdir()
        (fake_root / "repro_tests.nim").write_text("# no TestSpec literals at all\n")
        make_exe(self.bin_dir / "t_would_be_deleted")
        result = run_prune(fake_root, self.bin_dir)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing", result.stderr)
        self.assertTrue((self.bin_dir / "t_would_be_deleted").exists())

    def test_the_mirrored_predicate_matches_the_runner(self) -> None:
        source = RUNNER.read_text()
        match = re.search(r"proc looksLikeTestStem\(stem: string\): bool =\n(.*?)\n\n", source, re.S)
        self.assertIsNotNone(match, "the runner no longer defines looksLikeTestStem")
        body = strip_shell_comments(re.sub(r"^\s*##.*$", "", match.group(1), flags=re.M))
        self.assertEqual(
            " ".join(body.split()),
            'stem.startsWith("t_") or stem.startsWith("test_")',
            "the runner's test-stem predicate changed; update "
            "scripts/prune_undeclared_test_binaries.py to match",
        )

    def test_run_tests_prunes_before_the_runner_walks_the_bin_dir(self) -> None:
        text = strip_shell_comments(RUN_TESTS.read_text())
        call = re.search(
            r"^python3 scripts/prune_undeclared_test_binaries\.py --root \. --bin-dir build/test-bin\b",
            text,
            re.M,
        )
        self.assertIsNotNone(call, "run_tests.sh does not call the pruner at top level")
        first_walk = text.find("--bin-dir=build/test-bin")
        self.assertGreater(first_walk, 0, "run_tests.sh no longer hands the runner build/test-bin")
        self.assertLess(call.start(), first_walk, "the pruner runs after the runner walks the bin dir")


if __name__ == "__main__":
    unittest.main()
