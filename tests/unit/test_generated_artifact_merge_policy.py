"""The four tree-derived suite artifacts must never be text-merged.

WHAT THIS GUARDS

`repro_tests.nim`, `scripts/reprobuild-test-shape-parity.tsv`,
`scripts/reprobuild-suite-static-case-counts.tsv` and
`benchmarks/reports/reprobuild-suite-m0-inventory-sources.json` are pure
functions of the tree: `scripts/generate_test_edges.nim` and
`scripts/reprobuild_suite_inventory.py` derive every byte of them from the
test sources the tree contains. Their correct post-merge value is therefore a
function of the MERGED TREE and not of the two edits, so a three-way text
merge of them produces a document no generator ever emitted.

That is measured history, not a worry. Over the 182 two-parent merges in the
last 795 commits of this repository, 51 (28%) had both sides change one of
these files differently. In 43 of the 51 every two-sided artifact came out
matching neither parent -- a document git assembled and no generator ever
emitted. In the other 8 at least one artifact came out byte-identical to one
parent while its siblings were blended, which is the worse shape rather than
the milder one: it is exactly how the artifacts come to contradict each other,
and those 8 can be shown wrong from the commit alone -- `repro_tests.nim`, the
JSON and the TSV disagree about which test sources exist, by one to four
sources (348d9517, 7e7c4a6c, fc0534df, f77e9430, 244c1f5e, df677d0e, 37261319,
011c4772). The rest cannot be settled without regenerating a historical tree,
and that is the point -- a wrong value reaches a shared branch with nothing at
the merge to notice it, and surfaces later as a gate failure attributed to
whoever branched next.

`.gitattributes` marks all four `-merge`, so git refuses instead of guessing.
This file pins that the refusal is real and that the mark is on every
artifact that needs it.

NO MOCKED GIT

Every merge, rebase and cherry-pick here is a real git operation in a real
throwaway repository seeded from this repository's OWN `.gitattributes`, and
the marked-set assertions run `git check-attr` against this checkout. There
is nothing to mock: the behaviour under test is git's, a re-implementation of
it would prove only that the re-implementation agrees with itself, and the
silent fallback this file exists to rule out is precisely the kind of thing
a stub would model away.

The one thing the subprocess environment does override is the operator's
global and system git configuration (`GIT_CONFIG_GLOBAL` / `GIT_CONFIG_SYSTEM`
pointed at os.devnull). That is not a mock of git; it is the removal of a
confounder. `rerere.enabled=true` in a developer's `~/.gitconfig` replays a
remembered resolution and would auto-resolve the very conflict these cases
assert, and `merge.conflictstyle` changes what a conflicted file looks like.
A gate that passes or fails depending on whose machine it runs on is not a
gate.
"""

import importlib.util
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "scripts" / "reprobuild_suite_inventory.py"
SPEC = importlib.util.spec_from_file_location("reprobuild_suite_inventory", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
inventory = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = inventory
SPEC.loader.exec_module(inventory)


EDGE_GENERATOR = REPO_ROOT / "scripts" / "generate_test_edges.nim"
GITATTRIBUTES = REPO_ROOT / ".gitattributes"
REGEN_RECIPE = "regen-suite-artifacts"

# The relative path of the one artifact whose shape carries the counters, used
# by the reproduction below. Read from the module rather than spelled out, so a
# rename moves this file with it instead of skipping silently.
SOURCE_INVENTORY = inventory.SOURCE_INVENTORY_PATH.as_posix()


def scrubbed_git_env():
    """A git environment that answers for THIS repository and no operator."""
    import os

    env = dict(os.environ)
    env["GIT_CONFIG_GLOBAL"] = os.devnull
    env["GIT_CONFIG_SYSTEM"] = os.devnull
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env.pop("GIT_DIR", None)
    env.pop("GIT_WORK_TREE", None)
    env.pop("GIT_INDEX_FILE", None)
    return env


def git(root, *args, check=True):
    return subprocess.run(
        ["git", *args],
        cwd=root,
        check=check,
        capture_output=True,
        text=True,
        env=scrubbed_git_env(),
    )


def declared_generated_artifacts():
    """The artifacts the generators themselves say they write.

    DERIVED, never listed. A hand-maintained list beside a hand-maintained
    `.gitattributes` is two copies of the same fact and no way to notice they
    have parted; this reads one of them out of the Python generator's own path
    constants and the other out of the Nim generator's `const` block, so a
    fifth artifact cannot be added without this test seeing it.
    """
    nim = EDGE_GENERATOR.read_text(encoding="utf-8")
    from_nim = set()
    for name in ("GeneratedFile", "ShapeParityFile"):
        match = re.search(rf'^\s+{name}\s*=\s*"([^"]+)"', nim, re.M)
        assert match is not None, (
            f"{EDGE_GENERATOR.name} no longer declares `{name}`; this test can "
            "no longer see what the edge generator writes"
        )
        from_nim.add(match.group(1))
    from_python = {
        inventory.SOURCE_INVENTORY_PATH.as_posix(),
        inventory.STATIC_CASE_COUNTS_PATH.as_posix(),
        inventory.SHAPE_PARITY_PATH.as_posix(),
    }
    return from_nim | from_python


def marked_unmergeable():
    """Paths `.gitattributes` marks `-merge`, parsed from the file itself.

    A leading `/` is stripped: it anchors the pattern to the repository root,
    which is what a root-level artifact needs (a pattern with no slash in it
    matches that basename at any depth), but it is not part of the path.
    """
    marked = set()
    for line in GITATTRIBUTES.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        if "-merge" in fields[1:]:
            marked.add(fields[0].lstrip("/"))
    return marked


class MergePolicyReproductionTests(unittest.TestCase):
    """The failure, reproduced, and then refused.

    Every case here models the same event: two branches each enrol one test
    and regenerate, which is what the generators do -- insert one entry at its
    sorted position and increment every counter that summarises the array. The
    two insertions land far apart in a 1,700-entry sorted array, so git has no
    overlapping hunk to complain about, and both sides move each counter to the
    SAME new value, so git has no differing line to conflict over either.
    """

    def seed(self, attributes):
        """A throwaway repo holding the real artifact, at a chosen policy.

        `attributes` is the literal `.gitattributes` content, so a case can ask
        for no policy at all, this repository's actual policy, or a merge
        driver that nobody registered.
        """
        root = Path(tempfile.mkdtemp(prefix="repro-merge-policy-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        target = root / SOURCE_INVENTORY
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(REPO_ROOT / SOURCE_INVENTORY, target)
        (root / ".gitattributes").write_text(attributes, encoding="utf-8")
        git(root, "init", "-q", "-b", "main")
        git(root, "config", "user.email", "tester@example.invalid")
        git(root, "config", "user.name", "Merge Policy Tester")
        git(root, "add", "-A")
        git(root, "commit", "-qm", "seed")
        return root

    def enrol(self, root, source):
        """Rewrite the artifact as a regeneration after enrolling `source`.

        Serialised through the generator's OWN renderer, so the bytes git is
        asked to merge are shaped exactly like the bytes it is asked to merge
        in production -- `indent=2`, `sort_keys=True`, trailing newline.
        """
        target = root / SOURCE_INVENTORY
        document = json.loads(target.read_text(encoding="utf-8"))
        owner, _, stem = source.rpartition("/tests/")
        document["tests"].append(
            {
                "binary": f"build/test-bin/{stem[:-4]}",
                "class": "pure unit",
                "classificationReason": "no subprocess in test body",
                "defines": [],
                "language": "nim",
                "localDependencyShape": ["repro_core"],
                "owner": owner,
                "requiresReproBinary": False,
                "source": source,
                "sourceSuiteCount": 1,
                "staticCaseCount": 1,
                "staticallyDetectedRuntimeCompilerFlow": False,
                "targetOs": "soAny",
            }
        )
        document["tests"].sort(key=lambda item: item["source"])
        facts = document["observedStructuralFacts"]
        facts["testEntries"] += 1
        facts["nimTestBinaries"] += 1
        facts["pureUnitTests"] += 1
        static = document["static"]
        static["testEntryCount"] += 1
        static["nimTestBinaryCount"] += 1
        static["classificationCounts"]["pure unit"] += 1
        target.write_text(
            inventory.render_source_inventory(document), encoding="utf-8"
        )

    def two_branches(self, attributes, merge=True):
        """Build the two-sided regeneration and return (root, merge result).

        `merge=False` stops before the merge, for the cases that need to drive
        it with a strategy option of their own.
        """
        root = self.seed(attributes)
        git(root, "checkout", "-qb", "side-a")
        self.enrol(root, "apps/repro-harvest-apt/tests/t_merge_policy_side_a.nim")
        git(root, "commit", "-qam", "side A: enrol one test and regenerate")
        git(root, "checkout", "-q", "main")
        git(root, "checkout", "-qb", "side-b")
        self.enrol(root, "tools/catalog-harvester/tests/test_merge_policy_side_b.nim")
        git(root, "commit", "-qam", "side B: enrol one test and regenerate")
        git(root, "checkout", "-q", "side-a")
        if not merge:
            return root, None
        return root, git(root, "merge", "side-b", "-m", "integrate", check=False)

    def counters_agree_with_arrays(self, root):
        """Is the artifact on disk a document a generator could have emitted?"""
        document = json.loads((root / SOURCE_INVENTORY).read_text(encoding="utf-8"))
        facts = document["observedStructuralFacts"]
        entries = len(document["tests"])
        return (
            facts["testEntries"] == entries
            and document["static"]["testEntryCount"] == entries
            and facts["nimTestBinaries"]
            == sum(1 for item in document["tests"] if item["language"] == "nim")
        )

    def test_without_the_mark_the_merge_succeeds_and_the_artifact_is_wrong(self):
        """THE FAILURE. Conflict-free, exit 0, and a fabricated document.

        This is the red case, and it is here permanently rather than as a
        one-off measurement: it is the only thing that proves the cases below
        have any power at all. If a future git resolves this differently, or
        someone reshapes the artifact so a text merge happens to converge, this
        fails and the policy can be re-argued from evidence instead of being
        carried on faith.
        """
        root, merged = self.two_branches("")
        self.assertEqual(
            merged.returncode,
            0,
            "expected git to merge the artifact with no conflict; if it now "
            "refuses on its own, the rest of this file is asserting a "
            "protection that is no longer needed",
        )
        self.assertEqual(
            git(root, "status", "--porcelain", "--", SOURCE_INVENTORY).stdout,
            "",
            "the merge left the path unmerged, so nothing silent happened",
        )
        document = json.loads((root / SOURCE_INVENTORY).read_text(encoding="utf-8"))
        # Both insertions survived -- the sorted array merged as a union, which
        # is why nothing conflicted...
        sources = {item["source"] for item in document["tests"]}
        self.assertIn("apps/repro-harvest-apt/tests/t_merge_policy_side_a.nim", sources)
        self.assertIn(
            "tools/catalog-harvester/tests/test_merge_policy_side_b.nim", sources
        )
        # ...and the counters did not, because both sides wrote the same +1 and
        # git saw one change, not two. The committed artifact now claims one
        # fewer test than it lists.
        self.assertFalse(
            self.counters_agree_with_arrays(root),
            "the reproduction stopped reproducing: the merged counters agree "
            "with the merged arrays",
        )
        facts = document["observedStructuralFacts"]
        self.assertEqual(facts["testEntries"], len(document["tests"]) - 1)

    def test_this_repositorys_attributes_turn_that_merge_into_a_refusal(self):
        """The fix, asserted through the shipped policy rather than a copy.

        `.gitattributes` is read out of this checkout, so the case tests what
        contributors actually get. Editing the mark out to make this pass is
        not available: the file IS the subject.
        """
        root, merged = self.two_branches(
            GITATTRIBUTES.read_text(encoding="utf-8")
        )
        self.assertNotEqual(merged.returncode, 0, "the merge was not refused")
        self.assertEqual(
            git(root, "status", "--porcelain", "--", SOURCE_INVENTORY).stdout.strip(),
            f"UU {SOURCE_INVENTORY}",
            "the path should be left unmerged for the contributor to regenerate",
        )
        # All three stages are in the index, so `--ours` / `--theirs` work and
        # a human can still see what each side had.
        stages = {
            line.split()[2]
            for line in git(root, "ls-files", "-u", "--", SOURCE_INVENTORY)
            .stdout.splitlines()
        }
        self.assertEqual(stages, {"1", "2", "3"})

    def test_a_declared_merge_driver_nobody_registered_fails_open_silently(self):
        """Why the mark is `-merge` and not `merge=<name>`. Measured, and pinned.

        A custom merge driver could regenerate instead of merging, but the
        `merge.<name>.driver` half lives in `.git/config`, which is not
        versioned, and git offers no way to require it. This is what a clone
        that never ran the registration step does: it prints the ordinary
        "Auto-merging" line, exits 0, and produces the same wrong artifact as
        no protection at all.

        Pinned as a test rather than written down as a conclusion because the
        conclusion is the load-bearing part of the design. If a future git
        learns to refuse or even warn about an undefined driver, this fails and
        a driver becomes worth reconsidering.
        """
        root, merged = self.two_branches(f"{SOURCE_INVENTORY} merge=reprobuild-regen\n")
        self.assertEqual(
            git(root, "check-attr", "merge", "--", SOURCE_INVENTORY).stdout.strip(),
            f"{SOURCE_INVENTORY}: merge: reprobuild-regen",
            "the attribute is in force; only the driver is missing",
        )
        self.assertEqual(
            merged.returncode, 0, "an unregistered driver did NOT fail open"
        )
        self.assertNotIn("reprobuild-regen", merged.stdout + merged.stderr)
        self.assertNotIn("driver", (merged.stdout + merged.stderr).lower())
        self.assertFalse(
            self.counters_agree_with_arrays(root),
            "the fallback merge produced a coherent artifact after all",
        )

    def test_the_refusal_leaves_a_working_tree_the_generators_can_run_on(self):
        """No conflict markers -- which is what makes regeneration the remedy.

        `-merge` does not write `<<<<<<<` into the file; it leaves OUR content
        in place and marks the path unmerged. That matters for more than
        tidiness: `repro_tests.nim` is `import`ed by `repro.nim`, and the
        inventory writers read it. Markers would make the tree uncompilable and
        unparseable at exactly the moment the contributor needs to run the
        generator over it.
        """
        root, merged = self.two_branches(
            GITATTRIBUTES.read_text(encoding="utf-8")
        )
        self.assertNotEqual(merged.returncode, 0)
        text = (root / SOURCE_INVENTORY).read_text(encoding="utf-8")
        self.assertNotIn("<<<<<<<", text)
        self.assertNotIn(">>>>>>>", text)
        document = json.loads(text)  # parses, i.e. still a usable artifact
        # And what is left is one side entire, not a blend of the two.
        ours = git(root, "show", f":2:{SOURCE_INVENTORY}").stdout
        self.assertEqual(text, ours)
        self.assertTrue(
            self.counters_agree_with_arrays(root),
            "the retained side should be internally coherent",
        )
        self.assertEqual(
            document["observedStructuralFacts"]["testEntries"],
            len(document["tests"]),
        )

    def test_a_one_sided_change_still_merges_without_a_conflict(self):
        """The mark is not a blanket conflict on every integration.

        `-merge` does nothing unless BOTH sides moved the file differently. A
        branch that regenerated while the other did not resolves trivially,
        which is the common case and must stay silent -- a protection that
        stops every merge is one people route around.
        """
        root = self.seed(GITATTRIBUTES.read_text(encoding="utf-8"))
        (root / "unrelated.txt").write_text("one\n", encoding="utf-8")
        git(root, "add", "unrelated.txt")
        git(root, "commit", "-qm", "seed an unrelated file")
        git(root, "checkout", "-qb", "side-a")
        self.enrol(root, "apps/repro-harvest-apt/tests/t_merge_policy_side_a.nim")
        git(root, "commit", "-qam", "side A: enrol one test and regenerate")
        git(root, "checkout", "-q", "main")
        git(root, "checkout", "-qb", "side-b")
        (root / "unrelated.txt").write_text("two\n", encoding="utf-8")
        git(root, "commit", "-qam", "side B: touch something else")
        git(root, "checkout", "-q", "side-a")
        merged = git(root, "merge", "side-b", "-m", "integrate", check=False)
        self.assertEqual(
            merged.returncode, 0, merged.stdout + merged.stderr
        )
        self.assertTrue(self.counters_agree_with_arrays(root))

    def test_two_sides_that_regenerated_identically_still_merge(self):
        """The other benign case: same tree change, same generated bytes.

        Both sides enrolling the SAME test produce byte-identical artifacts, so
        there is nothing to merge and nothing to refuse.
        """
        root = self.seed(GITATTRIBUTES.read_text(encoding="utf-8"))
        for branch in ("side-a", "side-b"):
            git(root, "checkout", "-q", "main")
            git(root, "checkout", "-qb", branch)
            self.enrol(root, "apps/repro-harvest-apt/tests/t_merge_policy_same.nim")
            git(root, "commit", "-qam", f"{branch}: enrol one test and regenerate")
        git(root, "checkout", "-q", "side-a")
        merged = git(root, "merge", "side-b", "-m", "integrate", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)

    def test_rebase_and_cherry_pick_refuse_as_well(self):
        """The third measured failure was a REBASE, not a merge.

        A rebase of a stack across these files conflicted on every attempt and
        one resolution discarded a regeneration commit's whole content, which
        git then dropped as empty -- invisibly. `-merge` covers rebase and
        cherry-pick because both run the same merge machinery; this pins that
        rather than assuming it, and pins it for BOTH so a future change to one
        cannot quietly stop covering the other.
        """
        attributes = GITATTRIBUTES.read_text(encoding="utf-8")
        for operation, args in (
            ("rebase", ("rebase", "side-b")),
            ("cherry-pick", ("cherry-pick", "side-b")),
        ):
            with self.subTest(operation=operation):
                root = self.seed(attributes)
                git(root, "checkout", "-qb", "side-a")
                self.enrol(
                    root, "apps/repro-harvest-apt/tests/t_merge_policy_side_a.nim"
                )
                git(root, "commit", "-qam", "side A: enrol one test and regenerate")
                git(root, "checkout", "-q", "main")
                git(root, "checkout", "-qb", "side-b")
                self.enrol(
                    root, "tools/catalog-harvester/tests/test_merge_policy_side_b.nim"
                )
                git(root, "commit", "-qam", "side B: enrol one test and regenerate")
                git(root, "checkout", "-q", "side-a")
                result = git(root, *args, check=False)
                self.assertNotEqual(
                    result.returncode,
                    0,
                    f"git {operation} text-merged a derived artifact",
                )
                self.assertEqual(
                    git(root, "status", "--porcelain", "--", SOURCE_INVENTORY)
                    .stdout.strip(),
                    f"UU {SOURCE_INVENTORY}",
                )

    def test_a_strategy_option_takes_one_side_entire_and_never_blends_them(self):
        """`-X ours` / `-X theirs` bypass the refusal -- safely. Measured.

        Both exit 0 on a `-merge` path, so the escape hatch is real and it is
        silent. What makes it tolerable is WHICH document comes out: the named
        side entire, not a splice of the two. A blend is the thing nothing can
        attribute; a stale-but-coherent artifact at least has ONE gate that can
        see it -- `--check-declared-sources`, the only one that walks the tree
        rather than deriving its universe from `repro_tests.nim` (which `-X`
        made stale in the same direction, so the other three agree with each
        other and pass). That gate is Nim-only, so a `-X` resolution that drops
        a Python test source is caught by nothing. `-X` is not a remedy.

        Pinned because that distinction is the whole reason the hatch is left
        open. If a future git starts hunk-merging under `-X ours` on an
        unmergeable path, this fails.
        """
        for option, expect_entries_bumped in (("ours", False), ("theirs", True)):
            with self.subTest(option=option):
                root, _ = self.two_branches(
                    GITATTRIBUTES.read_text(encoding="utf-8"), merge=False
                )
                merged = git(
                    root, "merge", f"-X{option}", "side-b", "-m", "integrate",
                    check=False,
                )
                self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
                document = json.loads(
                    (root / SOURCE_INVENTORY).read_text(encoding="utf-8")
                )
                sources = {item["source"] for item in document["tests"]}
                wanted = (
                    "tools/catalog-harvester/tests/test_merge_policy_side_b.nim"
                    if expect_entries_bumped
                    else "apps/repro-harvest-apt/tests/t_merge_policy_side_a.nim"
                )
                unwanted = (
                    "apps/repro-harvest-apt/tests/t_merge_policy_side_a.nim"
                    if expect_entries_bumped
                    else "tools/catalog-harvester/tests/test_merge_policy_side_b.nim"
                )
                self.assertIn(wanted, sources)
                self.assertNotIn(
                    unwanted, sources, "the two sides were blended, not chosen"
                )
                self.assertTrue(
                    self.counters_agree_with_arrays(root),
                    "the chosen side is not internally coherent, so it was not "
                    "taken entire",
                )

    def test_the_legacy_resolve_strategy_is_a_known_and_pinned_bypass(self):
        """The one hole in the mark, recorded so it cannot surprise anyone.

        `git merge --strategy=resolve` does file-level merging regardless of the
        attribute: it prints `error: Merge requires file-level merging`, falls
        back to an automatic merge anyway, and exits 0 with the blended
        document. The default strategy since git 2.34 is `ort`, which honours
        the mark, so this is reachable only by asking for a legacy strategy by
        name -- do not.

        Asserted rather than described for the reason the repository applies to
        every other blind spot: a blind spot that cannot close silently, and a
        closed one that cannot re-open silently. If git teaches `resolve` to
        honour `-merge`, this case fails and the note comes out.
        """
        root, _ = self.two_branches(
            GITATTRIBUTES.read_text(encoding="utf-8"), merge=False
        )
        merged = git(
            root, "merge", "--strategy=resolve", "side-b", "-m", "integrate",
            check=False,
        )
        self.assertEqual(
            merged.returncode,
            0,
            "`--strategy=resolve` now refuses too; delete this case and the "
            "note it guards in .gitattributes",
        )
        self.assertFalse(
            self.counters_agree_with_arrays(root),
            "`--strategy=resolve` no longer blends the two sides",
        )


class MarkedArtifactSetTests(unittest.TestCase):
    """The mark is on every generated artifact, and on nothing else."""

    def test_every_artifact_the_generators_write_is_marked_unmergeable(self):
        """A fifth generated artifact cannot arrive unprotected.

        The set is read from the generators' own path constants, so this is not
        a second list to keep in step -- it is the first list, asked of the code
        that owns it.
        """
        declared = declared_generated_artifacts()
        self.assertEqual(len(declared), 4, sorted(declared))
        missing = sorted(declared - marked_unmergeable())
        self.assertEqual(
            missing,
            [],
            "these artifacts are derived from the tree but git will still "
            "text-merge them; add `<path> -merge` to .gitattributes: "
            f"{missing}",
        )

    def test_git_itself_reports_the_mark_in_this_checkout(self):
        """Parsing `.gitattributes` is not the same as git honouring it.

        A pattern can be shadowed by a later line, or be relative in a way that
        does not match, and reading the file would never say so. This asks git.
        """
        for path in sorted(declared_generated_artifacts()):
            with self.subTest(path=path):
                answer = git(REPO_ROOT, "check-attr", "merge", "--", path).stdout
                self.assertEqual(answer.strip(), f"{path}: merge: unset")

    def test_the_mark_does_not_suppress_diffs(self):
        """`-merge` must not become `-diff`.

        These artifacts are reviewed as diffs -- the static-case-count header
        says so outright ("a row that DECREASES or DISAPPEARS is a test leaving
        the suite; that is the event this baseline exists to make visible"). A
        policy that made them binary to `git diff` would take that away.
        """
        for path in sorted(declared_generated_artifacts()):
            with self.subTest(path=path):
                answer = git(REPO_ROOT, "check-attr", "diff", "text", "--", path).stdout
                self.assertIn(f"{path}: diff: unspecified", answer)
                self.assertNotIn("diff: unset", answer)

    def test_nothing_authored_is_marked_unmergeable(self):
        """Over-marking is its own failure.

        A `-merge` mark on a file humans edit converts every concurrent edit
        into a conflict with no regeneration command to resolve it, which is
        how a policy earns a reputation and gets deleted. The marked set is
        pinned equal to the derived set in both directions.
        """
        self.assertEqual(marked_unmergeable(), declared_generated_artifacts())


class ResolutionPathTests(unittest.TestCase):
    """A guaranteed conflict needs a one-command remedy, or it is a tax."""

    def test_the_justfile_regenerates_all_four_artifacts(self):
        """Wiring asserted at the call site. A remedy nothing offers is advice."""
        justfile = (REPO_ROOT / "Justfile").read_text(encoding="utf-8")
        self.assertIn(f"\n{REGEN_RECIPE}:\n", justfile)
        recipe = justfile.split(f"\n{REGEN_RECIPE}:\n", 1)[1]
        recipe = recipe.split("\n\n", 1)[0]
        self.assertIn(inventory.SHAPE_PARITY_REGENERATE_COMMAND, recipe)
        self.assertIn("--write-static-case-counts", recipe)
        self.assertIn("--write-inventory-sources", recipe)
        # The edge generator must run FIRST: both inventory writers read the
        # repro_tests.nim it produces.
        self.assertLess(
            recipe.index(inventory.SHAPE_PARITY_REGENERATE_COMMAND),
            recipe.index("--write-static-case-counts"),
        )

    def test_the_attributes_file_names_that_recipe(self):
        """The conflict is where a contributor looks, so the answer lives there.

        git names the path it refused; `.gitattributes` is the file that
        refused it. Whoever reads the mark must find the remedy beside it
        rather than having to guess or search.
        """
        text = GITATTRIBUTES.read_text(encoding="utf-8")
        self.assertIn(REGEN_RECIPE, text)


class DuplicateEntryCollapseTests(unittest.TestCase):
    """`--check-inventory` must not pass a document listing a source twice.

    Found while measuring this failure mode. `source_inventory_drift` keys both
    sides by source into a dict, so a duplicated `tests[]` entry used to have
    its earlier copy silently discarded and the gate passed as long as the
    surviving copy matched the tree. A duplicated entry in a sorted array is
    exactly what a union-style resolution of one of these conflicts produces,
    so the hole sits directly in this failure mode's blast radius. The TSV
    parser beside it has refused a repeated source since it was written; the
    projection now does the same.
    """

    def document(self):
        return json.loads(
            (REPO_ROOT / SOURCE_INVENTORY).read_text(encoding="utf-8")
        )

    def test_the_tracked_artifact_still_projects_cleanly(self):
        """The control. A refusal that also refuses the real file is a bug."""
        projected = inventory.inventory_source_projection(self.document())
        self.assertTrue(projected["tests"])

    def test_a_duplicated_source_is_refused_rather_than_collapsed(self):
        document = self.document()
        duplicated = document["tests"][0]
        document["tests"].append(dict(duplicated))
        with self.assertRaises(inventory.InventoryProjectionError) as caught:
            inventory.inventory_source_projection(document)
        message = str(caught.exception)
        self.assertIn(duplicated["source"], message)
        self.assertIn(inventory.SOURCE_INVENTORY_REGENERATE_COMMAND, message)

    def test_the_refusal_does_not_depend_on_the_copy_being_identical(self):
        """A duplicate whose fields differ is the dangerous shape.

        Collapsing kept the LAST occurrence, so a duplicate that disagrees with
        its twin was the case most likely to matter and least likely to be
        noticed: the gate compared the survivor, matched the tree, and reported
        green over a document that says two things about one source.
        """
        document = self.document()
        duplicated = dict(document["tests"][0])
        duplicated["staticCaseCount"] = duplicated["staticCaseCount"] + 7
        document["tests"].append(duplicated)
        with self.assertRaises(inventory.InventoryProjectionError):
            inventory.inventory_source_projection(document)

    def test_the_gate_refuses_a_duplicated_file_end_to_end(self):
        """Through the loader the gate actually calls, not just the projection."""
        root = Path(tempfile.mkdtemp(prefix="repro-merge-policy-dup-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        target = root / SOURCE_INVENTORY
        target.parent.mkdir(parents=True, exist_ok=True)
        document = self.document()
        document["tests"].append(dict(document["tests"][0]))
        target.write_text(
            inventory.render_source_inventory(document), encoding="utf-8"
        )
        with self.assertRaises(inventory.InventoryProjectionError):
            inventory.load_source_inventory(root)


if __name__ == "__main__":
    unittest.main()
