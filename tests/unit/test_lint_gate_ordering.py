"""A stale suite baseline must not switch off the audits ordered behind it.

WHY THIS FILE EXISTS

The suite case-count baseline and the inventory entry set are BOOKKEEPING:
they go stale whenever anyone lands a test without regenerating them, so they
can be red through no fault of the change being checked. For five commits on
`dev` (reprobuild-pm issue 2026-10-01, "suite case-count baseline is stale on
dev") that red check ran AHEAD of every content audit and fail-closed on all
of them:

  * in `.github/workflows/ci.yml`, job `lint`, the baseline step failed and
    the steps after it -- the vacuous-case audit, the helper-compilation
    audit and `just lint` itself -- were SKIPPED, because a step without an
    `if:` runs only while every earlier step succeeded;
  * in the `Justfile`'s `lint` recipe, which runs under `bash -e`, the four
    `reprobuild_suite_inventory.py --check-*` lines ran early, so a stale
    baseline aborted every audit after them.

No content lint executed on `dev` for those five commits, and the only signal
anyone saw was a red check naming files they had not touched.

Both orderings are asserted here TEXTUALLY, against the real files. Nothing is
mocked and nothing runs: the defect is the order of lines in two files, so
the order of lines is what is checked. PyYAML is not available in every
interpreter this suite runs under, so the workflow is read with a small
indentation-aware parser that understands exactly the shape `ci.yml` uses
(a `steps:` list of `- ` items under `jobs.lint`) and refuses anything else
rather than guessing.
"""

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
CI_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "ci.yml"
JUSTFILE = REPO_ROOT / "Justfile"

BASELINE_STEP_NAME = "Suite case-count baseline and inventory entry set"
SUITE_INVENTORY_CHECK = "reprobuild_suite_inventory.py --check-"


def job_steps(workflow_text, job):
    """Return the steps of `jobs.<job>` as a list of {key: raw value} dicts.

    Only top-level keys of each step are recorded (`name`, `if`, `run`,
    `uses`, ...), which is all the ordering question needs. Raises
    `ValueError` when the job or its `steps:` list cannot be found, so a
    reshaped workflow fails the test loudly instead of yielding zero steps
    and passing vacuously.
    """
    lines = workflow_text.splitlines()
    try:
        start = lines.index(f"  {job}:")
    except ValueError:
        raise ValueError(f"job {job!r} not found under `jobs:`") from None
    steps_indent = None
    steps = []
    item_indent = None
    for line in lines[start + 1:]:
        stripped = line.lstrip(" ")
        indent = len(line) - len(stripped)
        if stripped and indent <= 2:
            break  # the next job, or the end of `jobs:`
        if steps_indent is None:
            if stripped == "steps:":
                steps_indent = indent
            continue
        if not stripped or stripped.startswith("#"):
            continue
        if indent <= steps_indent and not stripped.startswith("- "):
            break  # a job key after `steps:`
        if stripped.startswith("- "):
            if item_indent is None:
                item_indent = indent
            if indent == item_indent:
                steps.append({})
                stripped = stripped[2:]
                indent += 2
        if not steps:
            continue
        if indent == item_indent + 2:
            match = re.match(r"([A-Za-z_-]+):\s*(.*)$", stripped)
            if match:
                steps[-1][match.group(1)] = match.group(2)
    if steps_indent is None or not steps:
        raise ValueError(f"job {job!r} has no parseable `steps:` list")
    return steps


def recipe_commands(justfile_text, recipe):
    """The command lines of a Justfile recipe, comments and blanks removed."""
    lines = justfile_text.splitlines()
    try:
        start = lines.index(f"{recipe}:")
    except ValueError:
        raise ValueError(f"recipe {recipe!r} not found") from None
    commands = []
    for line in lines[start + 1:]:
        if line and not line[0].isspace():
            break
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            commands.append(stripped)
    if not commands:
        raise ValueError(f"recipe {recipe!r} has no commands")
    return commands


class CiLintJobOrderingTests(unittest.TestCase):
    """`ci.yml`'s lint job: a failed baseline step must not skip the audits."""

    def test_the_parser_reads_the_real_lint_job(self):
        """Positive control: the parser sees the steps this file reasons about.

        Without it, a parser that silently returned the wrong slice of the
        workflow would make the ordering test below pass on nothing.
        """
        steps = job_steps(CI_WORKFLOW.read_text(encoding="utf-8"), "lint")
        names = [step.get("name", "") for step in steps]
        self.assertIn(BASELINE_STEP_NAME, names)
        self.assertIn("just lint", names)
        self.assertLess(names.index(BASELINE_STEP_NAME), names.index("just lint"))

    def test_every_step_after_the_baseline_runs_when_it_fails(self):
        steps = job_steps(CI_WORKFLOW.read_text(encoding="utf-8"), "lint")
        names = [step.get("name", "") for step in steps]
        after = steps[names.index(BASELINE_STEP_NAME) + 1:]
        self.assertTrue(after, "nothing follows the baseline step")
        unguarded = [
            step.get("name") or step.get("uses") or "<unnamed>"
            for step in after
            if not re.search(r"!\s*cancelled\(\)|always\(\)", step.get("if", ""))
        ]
        self.assertEqual(
            unguarded,
            [],
            "these lint-job steps follow the suite baseline step and carry "
            "no `if:` that lets them run after it fails; a stale baseline "
            "would SKIP them, which is how five commits reached dev with no "
            "content lint at all. Give each `if: ${{ !cancelled() ... }}`.",
        )


class JustLintOrderingTests(unittest.TestCase):
    """`just lint` runs under `bash -e`: the first failing line aborts it."""

    def test_the_suite_inventory_checks_run_last(self):
        commands = recipe_commands(JUSTFILE.read_text(encoding="utf-8"), "lint")
        inventory = [
            index
            for index, command in enumerate(commands)
            if SUITE_INVENTORY_CHECK in command
        ]
        # Positive control: all four checks are still in the recipe, so the
        # ordering assertion below is about something.
        self.assertEqual(len(inventory), 4, commands)
        behind = [
            command
            for command in commands[inventory[0] + 1:]
            if SUITE_INVENTORY_CHECK not in command
        ]
        self.assertEqual(
            behind,
            [],
            "these `just lint` audits run AFTER a suite-inventory check, so "
            "a stale baseline -- bookkeeping that can go stale through no "
            "fault of the change being linted -- aborts them under `bash -e`. "
            "Keep the four inventory checks at the end of the recipe.",
        )

    def test_the_dev_shell_gate_is_still_first(self):
        """Moving lines must not disturb the one ordering that is load-bearing.

        `check_dev_shell_env.sh` truncates test-logs/lint.log and gates the
        honesty of every later step; see its comment in the recipe.
        """
        commands = recipe_commands(JUSTFILE.read_text(encoding="utf-8"), "lint")
        self.assertEqual(commands[0], "mkdir -p test-logs")
        self.assertIn("check_dev_shell_env.sh", commands[1])


if __name__ == "__main__":
    unittest.main()
