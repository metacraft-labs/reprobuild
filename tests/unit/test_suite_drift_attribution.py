"""The suite-description gates must say WHICH stale entries a change introduced.

WHY THIS FILE EXISTS

`scripts/check_suite_case_counts.sh` refuses a tree whose checked-in suite
description (the static case-count TSV, the inventory entry set) disagrees
with the sources. Its refusal named every stale source without saying whether
the change being pushed put it there. When `dev` itself went stale, every
push and every pull request after it -- PR #478 among them -- was refused
naming three files the pusher had never touched, and five commits in a row
read the job as noise (reprobuild-pm issue 2026-10-01, "suite case-count
baseline is stale on dev").

`--attribute-to REV` answers the missing question by measuring the SAME drift
at REV and partitioning the tree's drift into "introduced by this change" and
"already stale at REV". The verdict does not change: the tree being published
is stale either way, and the remedy is still one command.

WHAT IS AND IS NOT MOCKED

Nothing. The partition is pure and is tested on literal drift documents. The
end-to-end cases build tiny real git repositories in temporary directories --
a two-entry `repro_tests.nim`, two Nim sources, the scanner itself and the two
tracked artifacts it generates -- and run the real scanner and the real shell
gate against them, so the git worktree that materialises REV is a real one
and its cleanup is observed through `git worktree list`, not assumed. The
trees are minimal so each scan takes milliseconds rather than the ~1 minute a
scan of the real tree costs.
"""

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "scripts" / "reprobuild_suite_inventory.py"
SPEC = importlib.util.spec_from_file_location(
    "reprobuild_suite_inventory_attribution", MODULE_PATH
)
assert SPEC is not None and SPEC.loader is not None
inventory = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = inventory
SPEC.loader.exec_module(inventory)

INHERITED_LABEL = "already stale at"
INTRODUCED_LABEL = "introduced by this change"


def static_drift(**items):
    drift = {
        "lostSources": [],
        "gainedSources": [],
        "decreased": [],
        "increased": [],
        "relabelled": [],
    }
    drift.update(items)
    return drift


def inventory_drift(**items):
    drift = {
        "lostSources": [],
        "gainedSources": [],
        "changedSources": [],
        "changedSections": [],
    }
    drift.update(items)
    return drift


class StaticCaseCountAttributionTests(unittest.TestCase):
    """`attribute_static_case_count_drift`: identity, not presence, decides."""

    def test_an_identical_item_is_inherited(self):
        item = ("libs/x/tests/t_a.nim", 16, 17)
        result = inventory.attribute_static_case_count_drift(
            static_drift(increased=[item]), static_drift(increased=[item])
        )
        self.assertEqual(result["inherited"]["increased"], [item])
        self.assertEqual(result["introduced"]["increased"], [])

    def test_a_changed_magnitude_is_introduced(self):
        """Base `16 -> 17`, tree `16 -> 18`: this change moved it further."""
        result = inventory.attribute_static_case_count_drift(
            static_drift(increased=[("t_a.nim", 16, 18)]),
            static_drift(increased=[("t_a.nim", 16, 17)]),
        )
        self.assertEqual(result["introduced"]["increased"], [("t_a.nim", 16, 18)])
        self.assertEqual(result["inherited"]["increased"], [])

    def test_a_new_item_is_introduced_and_base_only_items_are_ignored(self):
        result = inventory.attribute_static_case_count_drift(
            static_drift(gainedSources=["t_new.nim"], lostSources=["t_old.nim"]),
            static_drift(lostSources=["t_old.nim"], decreased=[("t_gone.nim", 3, 1)]),
        )
        self.assertEqual(result["introduced"]["gainedSources"], ["t_new.nim"])
        self.assertEqual(result["inherited"]["lostSources"], ["t_old.nim"])
        # Fixed at the tree (absent from its drift) is not reported at all.
        self.assertEqual(result["introduced"]["decreased"], [])
        self.assertEqual(result["inherited"]["decreased"], [])


class SourceInventoryAttributionTests(unittest.TestCase):
    """`attribute_source_inventory_drift`, including the aggregate-section rule."""

    CHANGED = {
        "source": "t_a.nim",
        "fields": [{"field": "staticCaseCount", "recorded": 1, "measured": 2}],
    }

    def test_a_changed_source_is_compared_by_its_whole_field_list(self):
        moved_further = {
            "source": "t_a.nim",
            "fields": [{"field": "staticCaseCount", "recorded": 1, "measured": 3}],
        }
        same = inventory.attribute_source_inventory_drift(
            inventory_drift(changedSources=[self.CHANGED]),
            inventory_drift(changedSources=[self.CHANGED]),
        )
        self.assertEqual(same["inherited"]["changedSources"], [self.CHANGED])
        further = inventory.attribute_source_inventory_drift(
            inventory_drift(changedSources=[moved_further]),
            inventory_drift(changedSources=[self.CHANGED]),
        )
        self.assertEqual(further["introduced"]["changedSources"], [moved_further])

    def test_a_section_is_inherited_only_when_every_entry_is(self):
        base = inventory_drift(
            changedSources=[self.CHANGED], changedSections=["static"]
        )
        inherited = inventory.attribute_source_inventory_drift(
            inventory_drift(changedSources=[self.CHANGED], changedSections=["static"]),
            base,
        )
        self.assertEqual(inherited["inherited"]["changedSections"], ["static"])
        self.assertEqual(inherited["introduced"]["changedSections"], [])

        # Same section listed at the base, but this change ALSO added an
        # entry: the aggregate now carries this change's contribution too.
        mixed = inventory.attribute_source_inventory_drift(
            inventory_drift(
                changedSources=[self.CHANGED],
                gainedSources=["t_new.nim"],
                changedSections=["static"],
            ),
            base,
        )
        self.assertEqual(mixed["introduced"]["changedSections"], ["static"])
        self.assertEqual(mixed["introduced"]["gainedSources"], ["t_new.nim"])

        # A section the base does not list is introduced however clean the
        # entries are.
        fresh = inventory.attribute_source_inventory_drift(
            inventory_drift(changedSections=["observedStructuralFacts"]),
            inventory_drift(),
        )
        self.assertEqual(
            fresh["introduced"]["changedSections"], ["observedStructuralFacts"]
        )


TEST_SPEC = (
    "  TestSpec(\n"
    '    source: "{source}",\n'
    '    binary: "build/test-bin/{stem}",\n'
    "    defines: @[],\n"
    "    requiresReproBinary: false,\n"
    "    extraPassC: @[],\n"
    "    extraPassL: @[],\n"
    "    targetOs: soAny,\n"
    "    selfInterposes: false),\n"
)
SOURCES = ("tests/unit/t_attr_a.nim", "tests/unit/t_attr_b.nim")


def nim_source(cases):
    body = "".join(
        f'  test "case {index}":\n    check {index} + 1 == {index + 1}\n'
        for index in range(cases)
    )
    return 'import std/unittest\n\nsuite "attribution":\n' + body


class AttributionEndToEndTests(unittest.TestCase):
    """The real scanner and the real gate, in a real (tiny) git repository."""

    def setUp(self):
        self.env = dict(os.environ)
        self.env.update(
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_SYSTEM=os.devnull,
            GIT_AUTHOR_NAME="Attribution Test",
            GIT_AUTHOR_EMAIL="attribution@example.invalid",
            GIT_COMMITTER_NAME="Attribution Test",
            GIT_COMMITTER_EMAIL="attribution@example.invalid",
            GIT_TERMINAL_PROMPT="0",
            # The gate script runs `${PYTHON:-python3}`; pin it to the
            # interpreter running this test so the result does not depend on
            # whether a `python3` happens to be on PATH (it is not, outside
            # the dev shell).
            PYTHON=sys.executable,
        )
        for leaked in (
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_INDEX_FILE",
            "SUITE_CASE_COUNTS_BASE",
            "PRE_COMMIT_FROM_REF",
        ):
            self.env.pop(leaked, None)
        self.root = Path(tempfile.mkdtemp(prefix="suite-attribution-test-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.work = self.root / "work"
        self.work.mkdir()

    def git(self, *args):
        result = subprocess.run(
            ["git", *args],
            cwd=str(self.work),
            capture_output=True,
            text=True,
            env=self.env,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def scanner(self, *args):
        return subprocess.run(
            [sys.executable, "scripts/reprobuild_suite_inventory.py", *args],
            cwd=str(self.work),
            capture_output=True,
            text=True,
            env=self.env,
        )

    def set_cases(self, source, cases):
        (self.work / source).write_text(nim_source(cases), encoding="utf-8")

    def make_stale_base(self):
        """A clean commit, then a commit that adds a case and forgets both
        artifacts. Returns that second commit's sha: the stale base."""
        self.git("init", "-q", "-b", "main")
        (self.work / "scripts").mkdir()
        shutil.copy2(MODULE_PATH, self.work / "scripts" / MODULE_PATH.name)
        shutil.copy2(
            REPO_ROOT / "scripts" / "check_suite_case_counts.sh",
            self.work / "scripts" / "check_suite_case_counts.sh",
        )
        shutil.copy2(
            REPO_ROOT / inventory.SHAPE_PARITY_PATH,
            self.work / inventory.SHAPE_PARITY_PATH,
        )
        (self.work / "tests" / "unit").mkdir(parents=True)
        (self.work / "repro_tests.nim").write_text(
            "const reprobuildTestSpecs*: seq[TestSpec] = @[\n"
            + "".join(
                TEST_SPEC.format(source=source, stem=Path(source).stem)
                for source in SOURCES
            )
            + "]\nconst pythonTestPaths*: seq[string] = @[\n]\n",
            encoding="utf-8",
        )
        for source in SOURCES:
            self.set_cases(source, 1)
        for flag in ("--write-static-case-counts", "--write-inventory-sources"):
            result = self.scanner(flag)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.git("add", "-A")
        self.git("commit", "-qm", "clean")
        # Positive control: the starting tree is clean, so every refusal
        # below is caused by what the test changes afterwards.
        for flag in ("--check-static-case-counts", "--check-inventory"):
            result = self.scanner(flag)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.set_cases(SOURCES[0], 2)
        self.git("commit", "-qam", "stale: add a case, forget the artifacts")
        return self.git("rev-parse", "HEAD")

    def worktree_count(self):
        listing = self.git("worktree", "list", "--porcelain")
        return sum(1 for line in listing.splitlines() if line.startswith("worktree "))

    def test_inherited_staleness_is_attributed_to_the_base(self):
        base = self.make_stale_base()
        (self.work / "README").write_text("unrelated\n", encoding="utf-8")
        self.git("add", "README")
        self.git("commit", "-qm", "an unrelated change")
        short = self.git("rev-parse", "--short", base)
        for flag in ("--check-static-case-counts", "--check-inventory"):
            with self.subTest(flag=flag):
                result = self.scanner(flag, "--attribute-to", base)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(f"{INHERITED_LABEL} {short}", result.stderr)
                self.assertIn(SOURCES[0], result.stderr)
                self.assertNotIn(INTRODUCED_LABEL + ":", result.stderr)
                self.assertIn("introduced none", result.stderr)
        self.assertEqual(self.worktree_count(), 1)

    def test_a_case_this_change_adds_is_attributed_to_the_change(self):
        base = self.make_stale_base()
        self.set_cases(SOURCES[1], 3)  # uncommitted: the working tree counts
        for flag in ("--check-static-case-counts", "--check-inventory"):
            with self.subTest(flag=flag):
                result = self.scanner(flag, "--attribute-to", base)
                self.assertEqual(result.returncode, 1, result.stderr)
                block = result.stderr.split("attribution against", 1)[1]
                introduced, inherited = block.split(INHERITED_LABEL, 1)
                self.assertIn(INTRODUCED_LABEL, introduced)
                self.assertIn(SOURCES[1], introduced)
                self.assertNotIn(SOURCES[0], introduced)
                self.assertIn(SOURCES[0], inherited)
        self.assertEqual(self.worktree_count(), 1)

    def test_a_scanner_change_in_the_range_suppresses_attribution(self):
        base = self.make_stale_base()
        with (self.work / "scripts" / MODULE_PATH.name).open(
            "a", encoding="utf-8"
        ) as handle:
            handle.write("\n# a scanner edit inside the attributed range\n")
        result = self.scanner("--check-static-case-counts", "--attribute-to", base)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("note:", result.stderr)
        self.assertIn(MODULE_PATH.name, result.stderr)
        self.assertNotIn("attribution against", result.stderr)
        self.assertEqual(self.worktree_count(), 1)

    def test_an_unresolvable_base_is_a_note_not_a_new_verdict(self):
        self.make_stale_base()
        result = self.scanner(
            "--check-static-case-counts", "--attribute-to", "no-such-revision"
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("note:", result.stderr)
        self.assertIn("no-such-revision", result.stderr)
        self.assertNotIn("attribution against", result.stderr)

    def test_a_clean_tree_pays_nothing_for_attribution(self):
        base = self.make_stale_base()
        for flag in ("--write-static-case-counts", "--write-inventory-sources"):
            self.assertEqual(self.scanner(flag).returncode, 0)
        for flag in ("--check-static-case-counts", "--check-inventory"):
            result = self.scanner(flag, "--attribute-to", base)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("attribution", result.stdout + result.stderr)

    def test_the_gate_script_passes_the_base_it_resolves(self):
        base = self.make_stale_base()
        short = self.git("rev-parse", "--short", base)
        env = dict(self.env, SUITE_CASE_COUNTS_BASE=base)
        result = subprocess.run(
            ["bash", "scripts/check_suite_case_counts.sh"],
            cwd=str(self.work),
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f"{INHERITED_LABEL} {short}", result.stderr)
        self.assertEqual(self.worktree_count(), 1)

    def test_the_gate_script_says_how_to_supply_a_missing_base(self):
        """No env var, an all-zero pre-commit ref (a new branch), no upstream."""
        self.make_stale_base()
        env = dict(self.env, PRE_COMMIT_FROM_REF="0" * 40)
        result = subprocess.run(
            ["bash", "scripts/check_suite_case_counts.sh"],
            cwd=str(self.work),
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("SUITE_CASE_COUNTS_BASE", result.stderr)
        self.assertNotIn("attribution against", result.stderr)


if __name__ == "__main__":
    unittest.main()
