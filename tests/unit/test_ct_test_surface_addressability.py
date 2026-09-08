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

Mocking: none. Every case below runs the real classifier over a real file
written to a real temporary directory.
"""

import importlib.util
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


if __name__ == "__main__":
    unittest.main()
