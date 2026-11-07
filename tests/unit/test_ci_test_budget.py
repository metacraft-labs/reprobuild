"""The CI test job's ceiling and the suite's measured duration are a checked pair.

WHAT IS UNDER TEST
==================

``scripts/check_ci_test_budget.py``, the `just lint` gate added for
reprobuild-pm issue
``2026-09-30-reprobuild-ci-cannot-finish-within-the-six-hour-ceiling``. The
``test`` job in ``.github/workflows/ci.yml`` declared no ``timeout-minutes``,
so GitHub's 360-minute default ended every run that needed longer, and
run_tests.sh's own backstops (8h per collection build, 24h for the runner)
could never fire first. A run whose suite had reached a verdict
(38428391026: 10691 cases, 7m45s before the kill) was recorded ``cancelled``
and read as "the suite did not run".

These cases pin, against the REAL ``ci.yml``:

* the fixed workflow satisfies every invariant -- the case that fails
  against the unfixed workflow, for the reasons the issue states (no job or
  step ``timeout-minutes``, inner backstops not pinned below the step limit,
  a comment citing ``repro.nim:537`` by line number);
* the parser actually read the job (a positive control, so "no violations"
  cannot come from reading nothing), and the coverage-declaration step is
  wired so it cannot change the job's conclusion;

and, against small fixtures, that each invariant (a)-(f) rejects its own
violation with a message naming the step and the numbers.

FIXTURES, JUSTIFIED
===================

No mocks of the code under test: the real script runs as a subprocess under
the same ``python3`` for the end-to-end cases, and its public functions are
imported for the rest. The negative cases need workflows that are wrong in
exactly one way, which the real ``ci.yml`` is not, so they use a minimal
workflow written in ``ci.yml``'s own block layout (two jobs, ``test`` second,
a ``steps:`` list of ``- `` items with ``env:`` maps). They pass a small
measurement table of their own through ``check_workflow_text``'s keyword
arguments, because the real table names steps only the real ``ci.yml`` has;
the real table is exercised by the real-workflow cases.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check_ci_test_budget.py"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"


def load_checker():
    spec = importlib.util.spec_from_file_location("check_ci_test_budget", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    # dataclasses resolves annotations through sys.modules.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


budget = load_checker()
Measurement = budget.Measurement

# The fixture's own evidence table (see the header for why it is separate).
FIXTURE_STEPS = (Measurement("just test", 150, "fixture"),)
FIXTURE_INNER = (Measurement("REPROBUILD_BUILD_TIMEOUT", 10, "fixture"),)


def fixture(*, job_timeout="170", runs_on="[self-hosted, Linux, X64]",
            checkout_timeout="5", just_test_timeout="150",
            build_timeout='"10m"', runner_timeout='"20m"',
            extra_comment="", just_test_name="just test",
            job_name="test") -> str:
    """A minimal workflow, valid at every boundary unless a knob is changed.

    Sums: 5 + 150 + 15 (runner overhead) = 170 = the job timeout, and
    10 + 20 + 120 (in-step allowance) = 150 = the `just test` timeout.
    A knob set to None drops that line.
    """
    def line(text, value):
        return "" if value is None else text.format(value) + "\n"

    return (
        "name: CI\n"
        "on:\n"
        "  push:\n"
        "jobs:\n"
        "  lint:\n"
        "    runs-on: ubuntu-latest\n"
        "    steps:\n"
        "      - run: true\n"
        f"  {job_name}:\n"
        "    name: Test\n"
        f"    runs-on: {runs_on}\n"
        + line("    timeout-minutes: {}", job_timeout)
        + "    env:\n"
        "      REPROBUILD_TEST_THREADS: \"8\"\n"
        "    steps:\n"
        "      - uses: actions/checkout@v4\n"
        + line("        timeout-minutes: {}", checkout_timeout)
        + f"      # A comment documenting the next step. {extra_comment}\n"
        f"      - name: {just_test_name}\n"
        "        id: just_test\n"
        + line("        timeout-minutes: {}", just_test_timeout)
        + "        env:\n"
        + line("          REPROBUILD_BUILD_TIMEOUT: {}", build_timeout)
        + line("          REPROBUILD_RUNNER_TIMEOUT: {}", runner_timeout)
        + "          CT_BIN: ${{ env.CT_BIN }}\n"
        "        run: dev-exec just test\n"
        "  nix-build:\n"
        "    runs-on: [self-hosted, linux, x64]\n"
        "    steps:\n"
        "      - run: true\n"
    )


def check(text, steps=FIXTURE_STEPS, inner=FIXTURE_INNER):
    return budget.check_workflow_text(text, measured_steps=steps,
                                      measured_inner=inner)


def run_script(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(SCRIPT), *args],
                          capture_output=True, text=True, check=False)


class RealWorkflowTests(unittest.TestCase):
    """The checker against the real ``ci.yml`` and its real evidence table."""

    def test_the_real_ci_workflow_satisfies_every_invariant(self):
        result = run_script("--workflow", str(CI_WORKFLOW))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("consistent pair", result.stdout)

    def test_the_default_workflow_is_ci_yml(self):
        result = run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(CI_WORKFLOW), result.stdout)

    def test_the_parser_reads_the_real_test_job(self):
        """Positive control: "no violations" is about the job, not about nothing."""
        job = budget.parse_job(CI_WORKFLOW.read_text(encoding="utf-8"), "test")
        self.assertIn("self-hosted", job.runs_on)
        self.assertGreaterEqual(len(job.steps), 20)
        labels = [step.label for step in job.steps]
        for measurement in budget.MEASURED_STEP_WORST:
            self.assertIn(measurement.subject, labels)
        just_test = next(s for s in job.steps if s.label == "just test")
        self.assertEqual(just_test.fields.get("id"), "just_test")
        self.assertIn("REPROBUILD_BUILD_TIMEOUT", just_test.env)
        self.assertIn("CT_BIN", just_test.env)

    def test_the_coverage_declaration_cannot_change_the_conclusion(self):
        job = budget.parse_job(CI_WORKFLOW.read_text(encoding="utf-8"), "test")
        labels = [step.label for step in job.steps]
        self.assertIn("Declare suite coverage", labels)
        declare = job.steps[labels.index("Declare suite coverage")]
        self.assertGreater(labels.index("Declare suite coverage"),
                           labels.index("just test"))
        self.assertEqual(declare.fields.get("if"), "always()")
        self.assertEqual(declare.fields.get("continue-on-error"), "true")
        self.assertIn("steps.just_test.outcome",
                      declare.env.get("JUST_TEST_OUTCOME", ""))
        self.assertIn("scripts/ci_suite_coverage.py", declare.fields.get("run", ""))
        self.assertIn("--finished-marker test-logs/suite-finished.json",
                      declare.fields.get("run", ""))


class InvariantTests(unittest.TestCase):
    """Each invariant rejects its own violation, with the right message."""

    def assertOnly(self, problems, tag, *fragments):
        self.assertEqual(len(problems), 1, problems)
        self.assertTrue(problems[0].startswith(tag), problems)
        for fragment in fragments:
            self.assertIn(fragment, problems[0])

    def test_minimal_fixture_passes_at_every_boundary(self):
        self.assertEqual(check(fixture()), [])

    def test_a_job_without_a_timeout_is_rejected(self):
        self.assertOnly(check(fixture(job_timeout=None)), "(a)",
                        "job `test`", "no integer `timeout-minutes`", "360")

    def test_a_self_hosted_job_above_five_days_is_rejected(self):
        self.assertOnly(check(fixture(job_timeout="7201")), "(a)",
                        "7201", "7200", "self-hosted")

    def test_a_hosted_job_above_six_hours_is_rejected(self):
        text = fixture(job_timeout="361", runs_on="ubuntu-latest")
        self.assertOnly(check(text), "(a)", "361", "360", "GitHub-hosted")
        self.assertEqual(
            check(fixture(job_timeout="360", runs_on="ubuntu-latest")), [])

    def test_a_block_list_runs_on_is_read(self):
        text = fixture(job_timeout="7201",
                       runs_on="\n      - self-hosted\n      - Linux")
        self.assertOnly(check(text), "(a)", "self-hosted")

    def test_a_step_without_a_timeout_is_rejected(self):
        self.assertOnly(check(fixture(checkout_timeout=None)), "(b)",
                        "step `actions/checkout@v4`", "found none")

    def test_a_zero_or_expression_step_timeout_is_rejected(self):
        for value in ("0", "${{ inputs.minutes }}"):
            with self.subTest(value=value):
                self.assertOnly(check(fixture(checkout_timeout=value)), "(b)",
                                "step `actions/checkout@v4`")

    def test_steps_that_overrun_the_job_are_rejected(self):
        self.assertOnly(check(fixture(job_timeout="169")), "(c)",
                        "155 min", "15 min runner overhead", "170 min", "169")

    def test_an_unpinned_inner_backstop_is_rejected(self):
        for knob, var in (("build_timeout", "REPROBUILD_BUILD_TIMEOUT"),
                          ("runner_timeout", "REPROBUILD_RUNNER_TIMEOUT")):
            with self.subTest(var=var):
                self.assertOnly(check(fixture(**{knob: None})), "(d)",
                                "step `just test`", f"does not pin `{var}`")

    def test_a_malformed_or_disabled_backstop_is_rejected(self):
        for value, why in (('"5h30m"', "not a coreutils timeout duration"),
                           ('"0"', "disables the backstop")):
            with self.subTest(value=value):
                self.assertOnly(check(fixture(build_timeout=value)), "(d)",
                                "REPROBUILD_BUILD_TIMEOUT", why)

    def test_backstops_above_the_step_limit_are_rejected(self):
        self.assertOnly(check(fixture(runner_timeout='"21m"')), "(d)",
                        "REPROBUILD_BUILD_TIMEOUT 10 min",
                        "REPROBUILD_RUNNER_TIMEOUT 21 min", "120 min",
                        "151 min", "timeout-minutes 150")

    def test_a_step_budget_below_its_measured_worst_is_rejected(self):
        steps = (Measurement("just test", 151, "run 123"),)
        self.assertOnly(check(fixture(), steps=steps), "(e)",
                        "step `just test` timeout-minutes 150",
                        "measured worst of 151 min", "run 123")

    def test_an_inner_budget_below_its_measured_worst_is_rejected(self):
        inner = (Measurement("REPROBUILD_BUILD_TIMEOUT", 11, "run 456"),)
        self.assertOnly(check(fixture(), inner=inner), "(e)",
                        "`REPROBUILD_BUILD_TIMEOUT` = 10 min",
                        "measured worst of 11 min", "run 456")

    def test_a_measurement_for_a_missing_step_is_rejected(self):
        steps = (Measurement("Renamed step", 1, "run 789"),)
        self.assertOnly(check(fixture(), steps=steps), "(e)",
                        "measured step `Renamed step`", "never drop it")

    def test_a_line_number_citation_in_a_comment_is_rejected(self):
        text = fixture(extra_comment="See repro.nim:537 for the edge.")
        self.assertOnly(check(text), "(f)", "repro.nim:537", "line 18")

    def test_a_symbol_citation_is_accepted(self):
        text = fixture(
            extra_comment="See `compileDependencyPolicy` in repro.nim.")
        self.assertEqual(check(text), [])

    def test_every_violation_is_reported_not_only_the_first(self):
        text = fixture(job_timeout=None, checkout_timeout=None,
                       build_timeout=None, extra_comment="x.sh:1")
        tags = sorted(problem[:3] for problem in check(text))
        self.assertEqual(tags, ["(a)", "(b)", "(d)", "(f)"])


class ShapeAndCliTests(unittest.TestCase):
    """What the checker cannot read is a failure, never a silent pass."""

    def test_a_missing_job_is_a_shape_error(self):
        with self.assertRaises(budget.WorkflowShapeError):
            check(fixture(job_name="tests"))

    def test_a_missing_just_test_step_is_a_shape_error(self):
        with self.assertRaises(budget.WorkflowShapeError):
            check(fixture(just_test_name="just tests"))

    def test_the_cli_exits_1_on_violations_and_2_on_shape(self):
        with tempfile.TemporaryDirectory(prefix="repro-ci-budget-") as scratch:
            bad = Path(scratch) / "violating.yml"
            bad.write_text(fixture(job_timeout=None), encoding="utf-8")
            result = run_script("--workflow", str(bad))
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("(a) job `test` declares no integer", result.stderr)

            shapeless = Path(scratch) / "shapeless.yml"
            shapeless.write_text("name: CI\njobs:\n  lint:\n", encoding="utf-8")
            result = run_script("--workflow", str(shapeless))
            self.assertEqual(result.returncode, 2, result.stdout)
            self.assertIn("job `test` not found", result.stderr)

            result = run_script("--workflow", str(Path(scratch) / "absent.yml"))
            self.assertEqual(result.returncode, 2, result.stdout)


class DurationTests(unittest.TestCase):
    """coreutils ``timeout`` DURATION parsing, as run_tests.sh hands it over."""

    def test_valid_durations(self):
        for text, minutes in (("90", 1.5), ("30s", 0.5), ("330m", 330),
                              ("5h", 300), ("1d", 1440), ("1.5h", 90)):
            with self.subTest(text=text):
                self.assertEqual(budget.parse_duration_minutes(text), minutes)

    def test_invalid_durations(self):
        for text in ("5h30m", "", "h", "-1h", "0", "0m", "5 h"):
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    budget.parse_duration_minutes(text)


if __name__ == "__main__":
    unittest.main()
