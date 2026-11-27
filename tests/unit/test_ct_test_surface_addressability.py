"""`classify_absent` must read a source's imports, not its prose.

Why this file exists
--------------------
`scripts/ct_test_surface_addressability.py` writes a reason next to every
tracked source the `ct test` surface could not see. The reasons are prose and
not a gate, which is exactly why they can rot without anything failing: the
checked-in ledger's own test compares the SET of sources and never the reasons.
A wrong reason is still expensive, because the reason is what a reader uses to
decide what to fix, and two of the reasons here imply opposite remedies —
"joining bracketed import clauses recovers this" versus "this file has to stop
importing a local shim".

The classifier used to answer both questions by searching the raw bytes of the
file. This repository embeds whole Nim fixture modules inside triple-quoted
string literals, and those fixtures carry imports of their own, so the raw-byte
search attributed four sources to the shim on the strength of an import that
belonged to an embedded fixture. Each of the four imported `std/unittest` in a
bracketed clause and was recovered by the upstream import-scan fix — the
opposite of the remedy their recorded reason named.

The ledger's currency
---------------------
The second half of this file holds the ledger to the inventory it was measured
against. The ledger went stale whenever a suite source was added,
because nothing but the surface-driven integration test read it, and that test
then failed at the next unrelated change; a ledger regenerated before the
inventory recorded disagreements the inventory's regeneration removed; and its
markdown companion quoted figures no generator wrote. The cases below drive the
real `--check`, the real producer (`measure`) and the real writer over a
throwaway tree, and the last class runs the check over this checkout itself.

Mocking: the classifier cases run the real classifier over a real file written
to a real temporary directory. The currency cases feed `measure` a hand-built
`ct test discover` response instead of running the surface: what they test is
how a ledger compares with an inventory, which is independent of what the
surface found, and running the real surface would make them depend on a
CodeTracer build that this build-free check exists not to need. The surface
itself is exercised by `tests/integration/t_ct_test_surface_case_addressability`.
`require_current_inventory` is given a stand-in `run` for the one case that
tests its refusal, because the real inventory gate takes a minute and its
behaviour is `tests/unit/test_reprobuild_suite_inventory.py`'s to test; the
argv the stand-in receives is asserted, so the wiring is still checked.
"""

import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "scripts" / "ct_test_surface_addressability.py"
SPEC = importlib.util.spec_from_file_location(
    "ct_test_surface_addressability", MODULE_PATH
)
assert SPEC is not None and SPEC.loader is not None
addressability = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = addressability
SPEC.loader.exec_module(addressability)


def classify(text: str) -> tuple[str, str]:
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "t_subject.nim"
        source.write_text(text, encoding="utf8")
        return addressability.classify_absent(source)


class NimCodeOnlyTests(unittest.TestCase):
    def test_line_structure_is_preserved(self):
        """The multi-line-clause test reads newlines, so blanking must keep them."""
        text = 'import std/[os,\n  unittest]\n## a doc comment\nlet s = "x"\n'
        code = addressability.nim_code_only(text)
        self.assertEqual(len(code), len(text))
        self.assertEqual(code.count("\n"), text.count("\n"))
        self.assertIn("import std/[os,\n  unittest]", code)

    def test_triple_quoted_body_is_removed(self):
        code = addressability.nim_code_only(
            'const F = """\nimport ct_test_unittest_parallel\n"""\nimport std/unittest\n'
        )
        self.assertNotIn("ct_test_unittest_parallel", code)
        self.assertIn("import std/unittest", code)

    def test_single_quoted_string_is_removed(self):
        code = addressability.nim_code_only('let s = "import ct_test_unittest_parallel"\n')
        self.assertNotIn("ct_test_unittest_parallel", code)

    def test_comments_are_removed(self):
        code = addressability.nim_code_only(
            "## links ct_test_unittest_parallel\n"
            "#[ block\nct_test_unittest_parallel\n]#\n"
            "import std/unittest\n"
        )
        self.assertNotIn("ct_test_unittest_parallel", code)
        self.assertIn("import std/unittest", code)

    def test_char_literal_holding_a_quote_does_not_open_a_string(self):
        """`'"'` must not swallow the import that follows it."""
        code = addressability.nim_code_only("let q = '\"'\nimport std/unittest\n")
        self.assertIn("import std/unittest", code)


class ClassifyAbsentTests(unittest.TestCase):
    def test_real_shim_import_is_attributed_to_the_shim(self):
        reason, _ = classify(
            "import std/[os, strutils]\n"
            "import ct_test_unittest_parallel\n"
            'suite "s":\n  test "t":\n    check true\n'
        )
        self.assertEqual(reason, "shim-protocol-producer")

    def test_multi_line_std_unittest_clause_is_attributed_to_the_scan(self):
        reason, _ = classify(
            "import std/[algorithm, json, os,\n    strutils, unittest]\n"
            'suite "s":\n  test "t":\n    check true\n'
        )
        self.assertEqual(reason, "provider-multi-line-import")

    def test_embedded_fixture_import_does_not_decide_the_reason(self):
        """The defect this file was written for.

        A runner test that imports `std/unittest` in a bracketed clause and
        embeds a fixture module which imports the shim is a multi-line-import
        row. Reading the raw bytes calls it a shim row and sends the reader to
        retire a shim the file does not use.
        """
        reason, _ = classify(
            "import std/[algorithm, json, os,\n    strutils, unittest]\n"
            "\n"
            'const Fixture = """\n'
            "import std/[os, strutils]\n"
            "import ct_test_unittest_parallel\n"
            'suite "fixture":\n  test "case":\n    check true\n'
            '"""\n'
            'suite "s":\n  test "t":\n    check Fixture.len > 0\n'
        )
        self.assertEqual(reason, "provider-multi-line-import")

    def test_single_line_std_unittest_import_is_unclassified_not_shim(self):
        reason, _ = classify('import std/unittest\nsuite "s":\n  test "t":\n    check true\n')
        self.assertEqual(reason, "unclassified")

    def test_mentioning_the_shim_is_not_importing_it(self):
        """Isolates the read-the-code half of the fix from the ordering half.

        No bracketed clause here, so reordering alone cannot rescue this: a
        classifier that searches raw bytes calls this a shim row under either
        ordering, and the only thing that gets it right is refusing to read an
        embedded fixture's import as the file's own.
        """
        reason, _ = classify(
            "import std/unittest\n"
            "\n"
            'const Fixture = """\nimport ct_test_unittest_parallel\n"""\n'
            'suite "s":\n  test "t":\n    check Fixture.len > 0\n'
        )
        self.assertEqual(reason, "unclassified")

    def test_a_file_that_does_both_is_reported_as_the_binding_constraint(self):
        """Isolates the ordering half.

        Here the shim import is real AND the `std/unittest` clause is real and
        bracketed. Joining the clause recovers the file whether or not the shim
        is ever retired, so the clause is the binding constraint and has to be
        the verdict; testing the shim first names a remedy that is not the one
        that would work.
        """
        reason, _ = classify(
            "import std/[os,\n    unittest]\n"
            "import ct_test_unittest_parallel\n"
            'suite "s":\n  test "t":\n    check true\n'
        )
        self.assertEqual(reason, "provider-multi-line-import")

    def test_source_declaring_nothing_falls_through(self):
        reason, _ = classify("import std/os\nlet x = 1\n")
        self.assertEqual(reason, "declares-no-cases-of-its-own")

    def test_every_reason_carries_prose(self):
        for text in (
            "import ct_test_unittest_parallel\n",
            "import std/[os,\n  unittest]\n",
            "import std/unittest\n",
            "import std/os\n",
        ):
            _, detail = classify(text)
            self.assertGreater(len(detail), 40, msg=text)


class LedgerReasonsAreCurrentTests(unittest.TestCase):
    """Reclassify the checked-in ledger's own rows from the real sources.

    The ledger is regenerated by hand, so its reasons can lag the tree. This
    recomputes each row against the file it names and requires agreement,
    which turns "the prose is stale" from something a reader has to notice
    into something the suite reports.
    """

    def test_recorded_reasons_match_the_sources_they_name(self):
        import json

        ledger_path = (
            REPO_ROOT / "benchmarks/reports/ct-test-surface-addressability.json"
        )
        ledger = json.loads(ledger_path.read_text(encoding="utf8"))
        stale = []
        for row in ledger["unaddressableSources"]:
            source = REPO_ROOT / row["source"]
            self.assertTrue(source.is_file(), msg=row["source"])
            reason, _ = addressability.classify_absent(source)
            if reason != row["reason"]:
                stale.append(f"{row['source']}: recorded {row['reason']}, now {reason}")
        self.assertEqual(stale, [], msg="\n".join(stale))


# ---------------------------------------------------------------------------
# The ledger's currency
# ---------------------------------------------------------------------------

ADDRESSABLE = "tests/unit/t_addressable.nim"
SECOND = "tests/unit/t_second.nim"
UNADDRESSABLE = "tests/bundles/bundle_pure_unit.nim"
MARKDOWN_PROSE = (
    "# Ledger\n\nHand-written prose before.\n\n"
    + "{block}"
    + "\nHand-written prose after.\n"
)


def item(kind: str, source: str, name: str, line: int = 1) -> dict:
    return {
        "kind": kind,
        "file": source,
        "id": f"nim-unittest/nim/std/unittest/{source}::s::{name}",
        "range": {"startLine": line},
    }


def response(case_counts: dict[str, int]) -> dict:
    """A `ct test discover` document naming `case_counts[source]` cases each."""
    items = []
    for source, cases in case_counts.items():
        items.append(item("suite", source, "s"))
        items += [item("case", source, f"c{i}", i + 2) for i in range(cases)]
    return {
        "schemaVersion": 1,
        "catalogs": [{"provider": {"id": "nim-unittest"}, "items": items}],
        "diagnostics": [],
    }


class LedgerTree:
    """A throwaway repository root holding an inventory, a ledger and its .md."""

    def __init__(self, tmp: str):
        self.root = Path(tmp)
        for relative in (ADDRESSABLE, SECOND):
            self.write(relative, 'import std/unittest\nsuite "s":\n  test "c": discard\n')
        self.write(UNADDRESSABLE, "import ../unit/t_addressable\n")
        self.write(
            str(addressability.MARKDOWN_RELATIVE),
            MARKDOWN_PROSE.format(
                block=addressability.MARKDOWN_BEGIN + "\n" + addressability.MARKDOWN_END + "\n"
            ),
        )

    def write(self, relative: str, text: str) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf8")

    def set_inventory(self, counts: dict[str, int]) -> None:
        tests = [
            {"source": source, "language": "nim", "staticCaseCount": n}
            for source, n in sorted(counts.items())
        ]
        tests.append({"source": "tests/unit/test_py.py", "language": "python"})
        self.write(
            str(addressability.INVENTORY_RELATIVE), json.dumps({"tests": tests})
        )

    def regenerate(self, surface_counts: dict[str, int]) -> dict:
        """What the script does after locating the surface, minus the surface."""
        surface = self.root / "ct-test"
        surface.write_bytes(b"stand-in surface binary")
        document = addressability.measure(
            self.root, str(surface), "environment", response(surface_counts)
        )
        addressability.write_ledger(self.root, document)
        return document

    def ledger(self) -> dict:
        return json.loads(
            (self.root / addressability.ARTIFACT_RELATIVE).read_text(encoding="utf8")
        )

    def markdown(self) -> str:
        return (self.root / addressability.MARKDOWN_RELATIVE).read_text(encoding="utf8")


class LedgerCurrencyTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tree = LedgerTree(self._tmp.name)
        # The bundle is tracked and declares nothing; the surface sees the two
        # unittest sources and reports one case fewer than the inventory for
        # the second, so the ledger carries one row of each kind.
        self.tree.set_inventory({ADDRESSABLE: 1, SECOND: 3, UNADDRESSABLE: 4})
        self.tree.regenerate({ADDRESSABLE: 1, SECOND: 2})

    def tearDown(self):
        self._tmp.cleanup()

    def check(self) -> list[str]:
        return addressability.check(self.tree.root)

    def test_a_freshly_regenerated_ledger_is_current(self):
        """Positive control: every refusal below is caused by its one edit."""
        self.assertEqual(self.check(), [])
        ledger = self.tree.ledger()
        self.assertEqual(ledger["trackedNimSources"], sorted([ADDRESSABLE, SECOND, UNADDRESSABLE]))
        self.assertEqual([r["source"] for r in ledger["unaddressableSources"]], [UNADDRESSABLE])
        self.assertEqual([r["source"] for r in ledger["caseCountDisagreements"]], [SECOND])

    def test_a_source_added_to_the_inventory_without_regenerating_is_refused(self):
        """The issue's failure: #376's bundles and t_nimcache_is_worktree_local.

        Each was enrolled, the inventory regenerated, the ledger not; nothing
        but the surface-driven test noticed, at the next unrelated change.
        """
        added = "tests/unit/t_nimcache_is_worktree_local.nim"
        self.tree.write(added, "echo 1\n")
        self.tree.set_inventory({ADDRESSABLE: 1, SECOND: 3, UNADDRESSABLE: 4, added: 0})
        problems = self.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("never measured", problems[0])
        self.assertIn(added, problems[0])

    def test_a_source_dropped_from_the_inventory_is_refused(self):
        """The `test_hax_m2_*` rows: sources moved out, ledger rows left behind."""
        self.tree.set_inventory({ADDRESSABLE: 1, SECOND: 3})
        problems = self.check()
        self.assertTrue(
            any("no longer in" in p and UNADDRESSABLE in p for p in problems), problems
        )

    def test_a_ledger_regenerated_before_the_inventory_is_refused(self):
        """The 2026-09-28 ordering failure: inventory=8, ledger allowed 8 vs 10.

        The ledger recorded a disagreement against the old inventory count;
        the inventory's regeneration then made the counts agree, and the gate
        failed on a stale allowance.
        """
        self.tree.set_inventory({ADDRESSABLE: 1, SECOND: 2, UNADDRESSABLE: 4})
        problems = self.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn(SECOND, problems[0])
        self.assertIn("AFTER the inventory", problems[0])

    def test_a_count_change_on_a_source_with_no_disagreement_row_is_not_refused(self):
        """What the build-free check deliberately leaves to the surface.

        Adding a case to an addressable source moves the inventory and, as a
        rule, the surface with it; only the surface can say whether they still
        agree. Refusing here would demand a ct-test regeneration for every
        added case, which is the cost the issue rules out for this gate.
        """
        self.tree.set_inventory({ADDRESSABLE: 5, SECOND: 3, UNADDRESSABLE: 4})
        self.assertEqual(self.check(), [])

    def test_the_markdown_figures_are_written_with_the_json(self):
        """The prose companion is no longer a second, hand-kept copy."""
        markdown = self.tree.markdown()
        self.assertTrue(markdown.startswith("# Ledger\n\nHand-written prose before."))
        self.assertTrue(markdown.endswith("\nHand-written prose after.\n"))
        self.assertIn("| Tracked Nim suite sources | 3 |", markdown)
        self.assertIn(f"| `{UNADDRESSABLE}` | `declares-no-cases-of-its-own` |", markdown)
        self.assertIn(f"| `{SECOND}` | 3 | 2 |", markdown)

        # And a regeneration that moves a figure moves it in the markdown too.
        self.tree.set_inventory({ADDRESSABLE: 1, SECOND: 2, UNADDRESSABLE: 4})
        self.tree.regenerate({ADDRESSABLE: 1, SECOND: 2})
        self.assertEqual(self.check(), [])
        self.assertNotIn(f"| `{SECOND}` | 3 | 2 |", self.tree.markdown())
        self.assertIn("### The 0 per-source case-count disagreements", self.tree.markdown())

    def test_a_hand_edited_markdown_figure_is_refused_and_re_rendered(self):
        markdown = self.tree.markdown()
        self.tree.write(
            str(addressability.MARKDOWN_RELATIVE),
            markdown.replace("| Tracked Nim suite sources | 3 |", "| Tracked Nim suite sources | 9 |"),
        )
        problems = self.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("does not match", problems[0])
        self.assertEqual(addressability.main(["--write-markdown"], root=self.tree.root), 0)
        self.assertEqual(self.tree.markdown(), markdown)
        self.assertEqual(self.check(), [])

    def test_a_markdown_without_its_generated_block_is_refused(self):
        self.tree.write(str(addressability.MARKDOWN_RELATIVE), "# Ledger\n")
        problems = self.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("exactly one generated block", problems[0])

    def test_a_hand_edit_that_hides_a_source_is_refused(self):
        """Adding the new source to `trackedNimSources` alone is not enough."""
        added = "tests/unit/t_new.nim"
        self.tree.set_inventory({ADDRESSABLE: 1, SECOND: 3, UNADDRESSABLE: 4, added: 1})
        ledger = self.tree.ledger()
        ledger["trackedNimSources"] = sorted(ledger["trackedNimSources"] + [added])
        self.tree.write(str(addressability.ARTIFACT_RELATIVE), json.dumps(ledger))
        problems = self.check()
        self.assertTrue(
            any("trackedNimSuiteSources" in p for p in problems), problems
        )

    def test_a_version_1_ledger_is_refused_not_half_checked(self):
        ledger = self.tree.ledger()
        ledger["schemaVersion"] = 1
        del ledger["trackedNimSources"]
        self.tree.write(str(addressability.ARTIFACT_RELATIVE), json.dumps(ledger))
        problems = self.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("trackedNimSources", problems[0])

    def test_check_exits_non_zero_and_names_the_remedy(self):
        self.tree.set_inventory({ADDRESSABLE: 1, SECOND: 3, UNADDRESSABLE: 4, "tests/unit/t_x.nim": 1})
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            status = addressability.main(["--check"], root=self.tree.root)
        self.assertEqual(status, 1)
        self.assertIn(addressability.REGENERATE_COMMAND, stderr.getvalue())


class RegenerationOrderTests(unittest.TestCase):
    """Regeneration refuses to measure against a stale inventory."""

    def test_a_stale_inventory_stops_regeneration(self):
        calls = []

        def run(argv, cwd):
            calls.append((argv, cwd))
            return subprocess.CompletedProcess(argv, 1)

        with self.assertRaises(SystemExit) as raised:
            addressability.require_current_inventory(REPO_ROOT, run=run)
        self.assertIn(addressability.INVENTORY_REGENERATE_COMMAND, str(raised.exception))
        (argv, cwd), = calls
        self.assertEqual(argv[1:], [str(REPO_ROOT / "scripts/reprobuild_suite_inventory.py"), "--check-inventory"])
        self.assertEqual(cwd, str(REPO_ROOT))

    def test_a_current_inventory_lets_it_proceed(self):
        addressability.require_current_inventory(
            REPO_ROOT, run=lambda argv, cwd: subprocess.CompletedProcess(argv, 0)
        )


class CheckedInLedgerTests(unittest.TestCase):
    """This checkout's own ledger, and where its check runs."""

    def test_the_checked_in_ledger_is_current_with_the_inventory(self):
        problems = addressability.check(REPO_ROOT)
        self.assertEqual(problems, [], msg="\n".join(problems))

    def test_the_check_runs_where_the_case_count_gate_runs(self):
        """The pre-push hook, both CI jobs and `just lint` reach it.

        The hook and the CI jobs all run `check_suite_case_counts.sh`; `just
        lint` names each suite-description gate itself.
        """
        invocation = "scripts/ct_test_surface_addressability.py --check"
        gate = (REPO_ROOT / "scripts/check_suite_case_counts.sh").read_text(encoding="utf8")
        justfile = (REPO_ROOT / "Justfile").read_text(encoding="utf8")
        self.assertTrue(invocation in gate, "check_suite_case_counts.sh does not run it")
        self.assertTrue(invocation in justfile, "`just lint` does not run it")


if __name__ == "__main__":
    unittest.main()
