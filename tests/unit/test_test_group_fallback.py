#!/usr/bin/env python3
"""A group test binary that fails to compile falls back to single compiles.

WHAT THIS PROTECTS
------------------
Test-Binary-Grouping M2 compiles up to fifty test sources into one
``t_group_*`` binary. One member that does not compile fails the group's
compile; the owner approved G = 50 on the condition that this costs time, not
the other members' coverage. ``scripts/test_group_fallback.py`` builds the
group's ``test-group-fallback-<group>`` collection -- each member's own compile
-- for every group whose binary is absent after ``.#test-builds``, and names
the member whose single compile fails.

WHAT IS ASSERTED
----------------
1. A group whose binary exists does not fall back: the engine is not invoked.
2. A group whose binary is absent is rebuilt as its members' own binaries,
   through exactly ``repro build ... .#test-group-fallback-<group>``.
3. When one member cannot be built singly either, the others still are, the
   broken member is named by SOURCE on stderr (the failure is attributed to the
   file, not to the group), and the exit status is non-zero.
4. A member binary left on disk by an earlier build is removed before the
   fallback, so a member that does not compile cannot run from stale bytes.
5. ``run_tests.sh`` runs the fallback after ``.#test-builds`` (and after the
   failed-binary drop) and before the pruner and the runner walk the bin dir.
6. The recipe registers a ``test-group-fallback-<group>`` collection holding
   each grouped member's own compile edge.

WHY ONE STUB (mock justification, per the workspace policy)
-----------------------------------------------------------
The engine is replaced by a stub ``repro`` executable that "builds" a fallback
collection by writing the member binaries a plan file lists, except the one
told to fail. The real engine would compile up to fifty real test binaries
from this repository per case (CPU-hours on the shared host), and what is
under test here is the orchestration contract -- which groups fall back,
which collection is requested, how failures are attributed, what is removed
and what the exit status is -- not the engine's ability to build a
collection, which every ``repro build`` test exercises. Everything else is
real: the real script, the real ``repro_tests.nim`` parser (on a small table
written in the generated shape) and real files in real directories. The
recipe side -- that ``test-group-fallback-<group>`` exists and holds each
member's own compile -- is checked against the real ``repro.nim`` in (6).
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
SCRIPT = ROOT / "scripts" / "test_group_fallback.py"
RUN_TESTS = ROOT / "scripts" / "run_tests.sh"
RECIPE = ROOT / "repro.nim"

GROUP = "t_group_tests_unit_g01"
MEMBERS = ("tests/unit/t_alpha.nim", "tests/unit/t_beta.nim", "tests/unit/t_gamma.nim")


def spec_literal(source: str, group: str) -> str:
    stem = Path(source).stem
    return (
        "  TestSpec(\n"
        f'    source: "{source}",\n'
        f'    binary: "build/test-bin/{stem}",\n'
        "    defines: @[],\n"
        "    requiresReproBinary: false,\n"
        "    extraPassC: @[],\n"
        "    extraPassL: @[],\n"
        "    targetOs: soAny,\n"
        "    selfInterposes: false,\n"
        f'    group: "{group}",\n'
        f'    singleReason: "{"" if group else "no other source shares its compile options"}")'
    )


STUB = """#!/bin/sh
# Stub engine: see the module docstring of test_test_group_fallback.py.
echo "$*" >> "$STUB_LOG"
status=0
while IFS= read -r stem; do
  if [ "$stem" = "$STUB_BROKEN" ]; then status=1; continue; fi
  printf '#!/bin/sh\\nexit 0\\n' > "build/test-bin/$stem"
  chmod +x "build/test-bin/$stem"
done < "$STUB_PLAN"
exit $status
"""


def strip_shell_comments(text: str) -> str:
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


class TestGroupFallback(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="group-fallback-"))
        self.root = self.tmp / "repo"
        self.bin_dir = self.root / "build" / "test-bin"
        self.bin_dir.mkdir(parents=True)
        rows = [spec_literal(m, GROUP) for m in MEMBERS]
        rows.append(spec_literal("tests/e2e/x/t_single.nim", ""))
        (self.root / "repro_tests.nim").write_text(
            "const reprobuildTestSpecs*: seq[TestSpec] = @[\n" + ",\n".join(rows) + "\n]\n")
        self.stub = self.tmp / "repro"
        self.stub.write_text(STUB)
        self.stub.chmod(0o755)
        self.log = self.tmp / "stub.log"
        self.plan = self.tmp / "plan.txt"
        self.plan.write_text("".join(Path(m).stem + "\n" for m in MEMBERS))

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_fallback(self, broken: str = "") -> subprocess.CompletedProcess:
        env = dict(os.environ, STUB_LOG=str(self.log), STUB_PLAN=str(self.plan),
                   STUB_BROKEN=broken)
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root),
             "--bin-dir", "build/test-bin", "--repro", str(self.stub)],
            capture_output=True, text=True, env=env, check=False)

    def invocations(self) -> list[str]:
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_a_group_that_built_does_not_fall_back(self) -> None:
        (self.bin_dir / GROUP).write_text("#!/bin/sh\n")
        result = self.run_fallback()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.invocations(), [])
        for member in MEMBERS:
            self.assertFalse((self.bin_dir / Path(member).stem).exists())

    def test_an_absent_group_is_rebuilt_as_its_members(self) -> None:
        result = self.run_fallback()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.invocations()
        self.assertEqual(len(calls), 1, calls)
        self.assertTrue(calls[0].startswith("build "), calls[0])
        self.assertTrue(calls[0].endswith(".#test-group-fallback-" + GROUP), calls[0])
        for member in MEMBERS:
            self.assertTrue((self.bin_dir / Path(member).stem).exists(), member)
        self.assertIn("group test binary NOT BUILT: " + GROUP, result.stderr)

    def test_a_broken_member_is_named_and_the_others_still_build(self) -> None:
        result = self.run_fallback(broken="t_beta")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.bin_dir / "t_alpha").exists())
        self.assertTrue((self.bin_dir / "t_gamma").exists())
        self.assertFalse((self.bin_dir / "t_beta").exists())
        self.assertIn("does not compile on its own: tests/unit/t_beta.nim", result.stderr)
        self.assertNotIn("tests/unit/t_alpha.nim", result.stderr)

    def test_a_stale_member_binary_cannot_survive_a_failed_fallback(self) -> None:
        stale = self.bin_dir / "t_beta"
        stale.write_text("#!/bin/sh\nexit 0\n")
        stale.chmod(0o755)
        result = self.run_fallback(broken="t_beta")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(stale.exists(), "a stale member binary would run as this build's")

    def test_run_tests_falls_back_between_the_build_and_the_runner(self) -> None:
        text = strip_shell_comments(RUN_TESTS.read_text())
        build = text.find('repro_build_collection ".#test-builds"')
        drop = text.find("scripts/drop_failed_test_binaries.py")
        fallback = re.search(r"^python3 scripts/test_group_fallback\.py\b", text, re.M)
        prune = text.find("python3 scripts/prune_undeclared_test_binaries.py")
        self.assertGreater(build, 0)
        self.assertIsNotNone(fallback, "run_tests.sh does not run the group fallback")
        assert fallback is not None
        self.assertLess(build, fallback.start())
        self.assertLess(drop, fallback.start())
        self.assertLess(fallback.start(), prune)

    def test_the_recipe_registers_a_fallback_collection_per_group(self) -> None:
        recipe = RECIPE.read_text()
        self.assertIn('collect("test-group-fallback-" & groupName,', recipe)
        self.assertIn("groupFallbackActions[groupIndex].add(edge.action)", recipe)


if __name__ == "__main__":
    unittest.main()
