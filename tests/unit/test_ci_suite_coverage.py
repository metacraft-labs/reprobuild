"""A CI test run states whether it is a verdict on the code or a partial run.

WHAT IS UNDER TEST
==================

``scripts/ci_suite_coverage.py``, run by ci.yml's "Declare suite coverage"
step after ``just test``. reprobuild-pm issue
``2026-09-30-reprobuild-ci-cannot-finish-within-the-six-hour-ceiling`` asks
that a truncated run say so, because a ``cancelled`` conclusion was being
read as a verdict -- in both directions: run 38428391026 was read as "the
suite did not run" when it had run all 10691 cases and was red on 105.

The rule pinned here: COMPLETE only when the step finished on its own
(``success`` or ``failure``) AND ``scripts/run_tests.sh``'s end-of-script
marker (``test-logs/suite-finished.json``) exists and parses -- so the Python
phase after the runner finished too -- AND the runner's summary parses, is not cut
short, is not a selected subset, and ran at least as many cases as it
planned (planned > 0). A ``failure`` with such a summary is still COMPLETE --
a red verdict is a verdict. Everything else is PARTIAL, says how far the run
got and says in words that the conclusion is NOT a verdict. The script always
exits 0: it declares, the ``just test`` step gates.

The marker's two ends in ``run_tests.sh`` are pinned as well: it is removed
before anything is built, and written only immediately before the final
``exit``. Its writer is extracted from the real script and RUN, and its
output is read back through the coverage script's own loader.

FIXTURES, JUSTIFIED
===================

No mocks: the real script runs as a subprocess under the same ``python3``,
reading real files. The summaries are hand-written in the shape
tools/test-runner/repro_test_runner.nim writes (``summary.total``,
``planned_total``, ``cut_short``, ``cut_short_detail``, ``selection`` ...),
because producing a real one needs a built suite run of hours; the field
names were taken from the runner's summary writer, and the counts from run
38428391026. The marker fixtures are written in the shape the extracted
``run_tests.sh`` writer produces, which the last test class checks.
"""

from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "ci_suite_coverage.py"
RUN_TESTS = ROOT / "scripts" / "run_tests.sh"
MARKER = "test-logs/suite-finished.json"
NOT_AT_END = ("the suite step did not reach its end (Python phase or later "
              "did not finish)")


def marker_document(*, suite_status=1, failed_modules=()) -> dict:
    return {"schema": "reprobuild.suite-finished.v1",
            "test_builds_status": 0, "cross_repo_fixtures_status": 0,
            "package_fixtures_status": 0, "nim_phase_status": suite_status,
            "python_failed_modules": list(failed_modules),
            "suite_status": suite_status}


def summary_document(*, total=10691, planned=10691, passed=10280, failed=105,
                     skipped=306, cut_short=False, subset=False) -> dict:
    summary = {
        "total": total, "passed": passed, "failed": failed,
        "skipped": skipped, "harness_errors": 0, "planned_total": planned,
        "cut_short": cut_short, "cancelled": 0, "status_disagreements": 0,
        "wall_time_ms": 7705286, "threads": 8,
        "selection": {"requested": subset, "applied": subset,
                      "selected_subset": subset, "deselected_unchanged": 0},
    }
    if cut_short:
        summary["cut_short_detail"] = {
            "signal": 15, "signal_name": "SIGTERM", "cases_run": total,
            "cases_planned": planned,
            "cases_never_started": max(planned - total, 0),
        }
    return {"summary": summary, "tests": []}


class CoverageCase(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="repro-ci-coverage-")
        self.addCleanup(scratch.cleanup)
        self.base = Path(scratch.name)
        self.summary = self.base / "parallel-run.json"
        self.marker = self.base / "suite-finished.json"

    def write(self, document) -> None:
        text = document if isinstance(document, str) else json.dumps(document)
        self.summary.write_text(text, encoding="utf-8")

    def write_marker(self, document=None) -> None:
        if document is None:
            document = marker_document()
        text = document if isinstance(document, str) else json.dumps(document)
        self.marker.write_text(text, encoding="utf-8")

    def run_script(self, outcome: str, *extra: str) -> subprocess.CompletedProcess:
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--summary", str(self.summary),
             "--finished-marker", str(self.marker), "--outcome", outcome,
             *extra],
            capture_output=True, text=True, check=False)
        # A declaration, never a gate: exit 0 whatever it found.
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def assertComplete(self, result, total: int):
        self.assertTrue(result.stdout.startswith(
            f"COMPLETE: the suite reached a verdict on all {total} cases"),
            result.stdout)
        self.assertIn("this conclusion IS a verdict on the code", result.stdout)
        self.assertIn("::notice title=Suite coverage::COMPLETE", result.stdout)
        self.assertNotIn("::warning", result.stdout)

    def assertPartial(self, result, *fragments: str):
        self.assertTrue(result.stdout.startswith("PARTIAL: "), result.stdout)
        self.assertIn("this job's conclusion is NOT a verdict on the code",
                      result.stdout)
        self.assertIn("::warning title=Suite coverage::PARTIAL", result.stdout)
        self.assertNotIn("::notice", result.stdout)
        for fragment in fragments:
            self.assertIn(fragment, result.stdout)


class CoverageTests(CoverageCase):
    def test_complete_summary_and_success_is_a_verdict(self):
        self.write(summary_document(failed=0, passed=10385))
        self.write_marker(marker_document(suite_status=0))
        result = self.run_script("success")
        self.assertComplete(result, 10691)
        self.assertIn("10385 passed, 0 failed, 306 skipped, 0 harness errors",
                      result.stdout)

    def test_complete_summary_and_failure_is_still_a_verdict(self):
        """Run 38428391026's numbers: red on 105 real failures, not a timeout."""
        self.write(summary_document())
        self.write_marker()
        result = self.run_script("failure")
        self.assertComplete(result, 10691)
        self.assertIn("10280 passed, 105 failed, 306 skipped", result.stdout)
        self.assertIn("run_tests.sh reached its end: suite_status=1",
                      result.stdout)

    def test_complete_summary_without_the_marker_is_partial(self):
        """The residual case: killed in the Python phase after the Nim verdict.

        A step ``timeout-minutes`` reports ``failure``, and the runner's
        summary is already complete; only the marker's absence tells them
        apart from a run that reached its end.
        """
        self.write(summary_document())
        result = self.run_script("failure")
        self.assertPartial(result, "10691 of 10691", NOT_AT_END)

    def test_unusable_markers_are_partial(self):
        self.write(summary_document())
        for text, why in (('{"suite_status": ', "not valid JSON"),
                          ("[]", "no integer `suite_status`"),
                          ('{"suite_status": "0"}', "no integer `suite_status`")):
            with self.subTest(text=text):
                self.write_marker(text)
                self.assertPartial(self.run_script("success"), why)

    def test_cut_short_summary_is_partial(self):
        self.write(summary_document(total=1697, planned=10605, cut_short=True))
        result = self.run_script("failure")
        self.assertPartial(result, "1697 of 10605", "cut short by SIGTERM",
                           "8908 cases never started")

    def test_fewer_cases_than_planned_is_partial(self):
        # Not marked cut short, yet short: the counts alone decide.
        self.write(summary_document(total=10000, planned=10691))
        result = self.run_script("success")
        self.assertPartial(result, "10000 of 10691", "691 were never started")

    def test_no_planned_cases_is_partial(self):
        self.write(summary_document(total=0, planned=0, passed=0, failed=0,
                                    skipped=0))
        self.assertPartial(self.run_script("success"), "planned no cases")

    def test_selected_subset_is_partial(self):
        self.write(summary_document(subset=True))
        self.assertPartial(self.run_script("success"), "selected subset")

    def test_missing_summary_is_partial(self):
        result = self.run_script("failure")
        self.assertPartial(result, "how far it got is unknown",
                           "no runner summary at")

    def test_malformed_json_is_partial(self):
        self.write('{"summary": {"total": 10691, ')
        self.assertPartial(self.run_script("success"), "not valid JSON")

    def test_wrong_shapes_are_partial(self):
        for document, why in (
                ([], "no `summary` object"),
                ({"summary": "done"}, "no `summary` object"),
                ({"summary": {"total": "10691", "planned_total": 10691,
                              "cut_short": False}},
                 "lacks a valid `total`"),
                ({"summary": {"total": True, "planned_total": 1,
                              "cut_short": False}},
                 "lacks a valid `total`"),
                ({"summary": {"total": 5, "planned_total": 5}},
                 "does not state `cut_short`")):
            with self.subTest(document=document):
                self.write(document)
                self.assertPartial(self.run_script("success"), why)

    def test_cancelled_with_a_complete_looking_summary_is_partial(self):
        """The step was stopped from outside; the file may predate the stop."""
        self.write(summary_document())
        result = self.run_script("cancelled")
        self.assertPartial(result, "10691 of 10691",
                           "did not finish on its own (outcome cancelled)")

    def test_skipped_and_unknown_outcomes_are_partial(self):
        self.write(summary_document())
        self.assertPartial(self.run_script("skipped"), "outcome skipped")
        self.assertPartial(self.run_script(""), "'<empty>' is not one GitHub")
        self.assertPartial(self.run_script("timed_out"), "'timed_out'")

    def test_step_summary_is_appended(self):
        step_summary = self.base / "step-summary.md"
        step_summary.write_text("# earlier section\n", encoding="utf-8")
        self.write(summary_document(total=1697, planned=10605, cut_short=True))
        self.run_script("cancelled", "--step-summary", str(step_summary))
        self.write(summary_document())
        self.write_marker()
        self.run_script("failure", "--step-summary", str(step_summary))
        text = step_summary.read_text(encoding="utf-8")
        self.assertTrue(text.startswith("# earlier section\n"), text)
        self.assertEqual(text.count("## Suite coverage"), 2, text)
        self.assertIn("**PARTIAL: it got through 1697 of 10605", text)
        self.assertIn("**COMPLETE: the suite reached a verdict on all 10691", text)

    def test_unwritable_step_summary_does_not_change_the_exit(self):
        self.write(summary_document())
        self.write_marker()
        result = self.run_script(
            "success", "--step-summary", str(self.base / "missing-dir" / "s.md"))
        self.assertComplete(result, 10691)
        self.assertIn("could not append", result.stderr)

    def test_annotation_is_a_single_workflow_command_line(self):
        self.write(summary_document(total=1697, planned=10605, cut_short=True))
        result = self.run_script("cancelled")
        commands = [line for line in result.stdout.splitlines()
                    if line.startswith("::")]
        self.assertEqual(len(commands), 1, result.stdout)
        self.assertIn("%0A", commands[0])


def load_coverage_module():
    spec = importlib.util.spec_from_file_location("ci_suite_coverage", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class RunTestsMarkerContractTests(unittest.TestCase):
    """``run_tests.sh`` removes the marker first and writes it only at its end."""

    @classmethod
    def setUpClass(cls):
        cls.text = RUN_TESTS.read_text(encoding="utf-8")
        cls.lines = cls.text.splitlines()

    def index_of(self, pattern: str) -> int:
        for number, line in enumerate(self.lines):
            if re.search(pattern, line):
                return number
        self.fail(f"no line of run_tests.sh matches {pattern!r}")

    def test_a_stale_marker_is_removed_before_anything_is_built(self):
        removal = self.index_of(r"^rm -rf .*test-logs/suite-finished\.json")
        first_build = self.index_of(r'^\s*repro_build_collection "')
        self.assertLess(removal, first_build)

    def test_the_marker_is_written_only_after_the_python_phase(self):
        command_lines = [line for line in self.lines
                         if line.strip() and not line.lstrip().startswith("#")]
        self.assertEqual(command_lines[-1], 'exit "${suite_status}"')
        invocation = self.index_of(r"^write_suite_finished_marker( |\\|$)")
        python_loop = self.index_of(r"^done < <\(")
        reraise = self.index_of(r"^suite_status=0$")
        final_exit = len(self.lines) - 1 - self.lines[::-1].index(
            'exit "${suite_status}"')
        self.assertLess(python_loop, reraise)
        self.assertLess(reraise, invocation)
        self.assertLess(invocation, final_exit)
        # Nothing between the invocation and the exit but its warning arm.
        between = [line.strip() for line in self.lines[invocation + 1:final_exit]
                   if line.strip()]
        self.assertEqual(len(between), 1, between)
        self.assertIn("could not write", between[0])
        # The only other mention outside comments is the removal.
        writers = [line for line in self.lines
                   if "suite-finished.json" in line
                   and not line.lstrip().startswith("#")]
        self.assertEqual(len(writers), 3, writers)  # rm, local marker=, warning

    def test_the_extracted_writer_produces_a_marker_the_loader_accepts(self):
        start = self.index_of(r"^json_string\(\) \{")
        end = self.index_of(r"^write_suite_finished_marker( |\\|$)")
        functions = "\n".join(self.lines[start:end])
        module = load_coverage_module()
        with tempfile.TemporaryDirectory(prefix="repro-marker-") as scratch:
            base = Path(scratch)
            (base / "test-logs").mkdir()
            script = (
                "set -euo pipefail\n" + functions + "\n"
                "test_builds_status=0 cross_repo_fixtures_status=3 "
                "package_fixtures_status=0 nim_phase_status=1 suite_status=1\n"
                "python_failed_modules=('tests/unit/test_a.py' "
                "'tests/odd \"quoted\" \\ name/test_b.py')\n"
                "write_suite_finished_marker\n"
                "python_failed_modules=()\n"
                "suite_status=0 nim_phase_status=0 cross_repo_fixtures_status=0\n"
                "cp test-logs/suite-finished.json first.json\n"
                "write_suite_finished_marker\n")
            result = subprocess.run(["bash", "-c", script], cwd=base,
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            first, problem = module.load_marker(base / "first.json")
            self.assertIsNone(problem)
            self.assertEqual(first["suite_status"], 1)
            self.assertEqual(first["cross_repo_fixtures_status"], 3)
            self.assertEqual(first["python_failed_modules"],
                             ["tests/unit/test_a.py",
                              'tests/odd "quoted" \\ name/test_b.py'])
            second, problem = module.load_marker(base / MARKER)
            self.assertIsNone(problem)
            self.assertEqual(second["suite_status"], 0)
            self.assertEqual(second["python_failed_modules"], [])
            self.assertFalse((base / (MARKER + ".tmp")).exists())


if __name__ == "__main__":
    unittest.main()
