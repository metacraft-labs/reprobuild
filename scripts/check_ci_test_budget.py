#!/usr/bin/env python3
"""Hold the CI ``test`` job's ceiling and the suite's measured duration as a pair.

WHY THIS EXISTS
===============

``.github/workflows/ci.yml``'s ``test`` job used to declare no
``timeout-minutes`` anywhere, so GitHub's default 360-minute job limit was the
only one in force. ``scripts/run_tests.sh`` carries its own, legible
backstops -- ``REPROBUILD_BUILD_TIMEOUT`` (default 8h, per collection build;
its 124 arm prints "Timed out building ... the build did NOT fail") and
``REPROBUILD_RUNNER_TIMEOUT`` (default 24h) -- but both sat far ABOVE that
default, so the outer, silent ceiling always fired first. Every such run
ended ``cancelled``, and a ``cancelled`` was read as a verdict on the code.
Run 38428391026 (dev @ 9aaa2a918) is the sharpest case: its suite reached a
verdict on all 10691 cases 7m45s before the ceiling killed the step, and the
run was still recorded as cancelled (reprobuild-pm issue
2026-09-30-reprobuild-ci-cannot-finish-within-the-six-hour-ceiling).

The issue's expected behaviour is that the suite's measured duration and the
job's ceiling are a CHECKED pair. This script is the check. For the ``test``
job it requires:

  (a) the job declares an integer ``timeout-minutes``, at most 7200 when
      ``runs-on`` names ``self-hosted`` (GitHub's limit for self-hosted
      runners) and at most 360 otherwise (GitHub-hosted runners);
  (b) every step declares an integer ``timeout-minutes`` of at least 1;
  (c) the step timeouts plus ``RUNNER_OVERHEAD_ALLOWANCE_MINUTES`` fit inside
      the job timeout, so a step's own limit -- which still lets the
      ``if: always()`` steps after it run and upload the logs -- fires before
      the job's, which skips them;
  (d) the ``just test`` step pins ``REPROBUILD_BUILD_TIMEOUT`` and
      ``REPROBUILD_RUNNER_TIMEOUT`` as coreutils ``timeout`` durations, and
      BUILD + RUNNER + ``JUST_TEST_IN_STEP_ALLOWANCE_MINUTES`` fits inside the
      step's ``timeout-minutes``, so run_tests.sh's legible backstops fire
      before the step's;
  (e) every budget is at least the worst duration MEASURED for it
      (``MEASURED_STEP_WORST`` and ``MEASURED_INNER_WORST`` below, each row
      citing its run). This is what makes it a pair with the evidence rather
      than a pair of arbitrary numbers: lowering a budget below the evidence
      fails, and so does recording a new worst measurement that exceeds a
      budget;
  (f) no comment in the workflow cites a source location by line number
      (metacraft-dev-guidelines/policies/recording-issues.md, "Cite symbols,
      not line numbers"). The old budget note cited ``repro.nim`` by line,
      and that line had come to name unrelated text.

WHAT IT DOES NOT DO
===================

It cannot make the job fit any particular wall clock and does not try; it
makes the limits fire in a legible order. Note also that run_tests.sh applies
``REPROBUILD_BUILD_TIMEOUT`` to EACH collection it builds, not once: the
in-step allowance covers the other collections at their measured durations,
so the ordering guarantee holds when one collection wedges, which is the case
the backstop exists for.

The workflow is read with a small text parser rather than a YAML library,
because PyYAML is not part of the dev shell (the same reasoning, and the same
approach, as ``job_steps`` in tests/unit/test_ci_reconcile_lock_credentials.py).
It understands only the block layout ``ci.yml`` is written in, and it FAILS
-- it never skips -- when it cannot find what it checks.

USAGE
=====

  python3 scripts/check_ci_test_budget.py [--workflow PATH]

Exit codes: 0 every invariant holds; 1 one or more violations (each printed
with the step and the numbers involved); 2 the workflow could not be read or
does not have the shape this checker understands.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "ci.yml"

TEST_JOB = "test"
JUST_TEST_STEP_NAME = "just test"

# GitHub's per-job execution limits: 5 days on self-hosted runners, where
# 360 minutes is only the default, and a hard 360 on GitHub-hosted ones.
# https://docs.github.com/en/actions/reference/limits
SELF_HOSTED_JOB_CEILING_MINUTES = 7200
HOSTED_JOB_CEILING_MINUTES = 360

# Time the job spends outside any step's timeout-minutes: "Set up job", the
# post-steps of actions (checkout, create-github-app-token cleanup) and
# "Complete job". Each is a minute or less on the measured runs; 15 leaves
# room for a slow runner without letting the sum of steps reach the ceiling.
RUNNER_OVERHEAD_ALLOWANCE_MINUTES = 15

# What `just test` does besides the two phases its pinned backstops bound
# (the `.#test-builds` collection build, and the test runner):
#   * prerequisite sibling builds (shim, runquota, reprobuild-cmake): the
#     reprobuild-cmake build alone took 1h08m45s on run 36590087746, against
#     6m59s on a faster host (36583430437);
#   * `.#apps`, `.#test-helpers`, `.#test-fixtures` and the fixture
#     collections: ~12m (budget note measured on run 31716928161);
#   * the Python test modules run after the runner: ~30m on 31716928161. On
#     38428391026 the step was killed 7m45s into that phase, so this run did
#     not measure it.
# 69 + 12 + 30 = 111, rounded up.
JUST_TEST_IN_STEP_ALLOWANCE_MINUTES = 120

# The Python phase, named so `just test`'s measured row can say what it adds.
PYTHON_PHASE_MINUTES = 30

ENV_BUILD_TIMEOUT = "REPROBUILD_BUILD_TIMEOUT"
ENV_RUNNER_TIMEOUT = "REPROBUILD_RUNNER_TIMEOUT"


@dataclass(frozen=True)
class Measurement:
    """The worst observed duration of one budgeted quantity, with its source."""

    subject: str  # a step name (MEASURED_STEP_WORST) or an env var name
    minutes: int  # rounded UP to the whole minute
    evidence: str


# Worst measured duration per heavy step of the `test` job. Measured with
# `gh` over the 200 most recent ci.yml runs since 2026-09-25 (read
# 2026-10-18), plus the runs reprobuild-pm issue
# 2026-09-30-reprobuild-ci-cannot-finish-within-the-six-hour-ceiling cites.
# Add a row when a run sets a new worst; never delete one to make a budget
# fit.
MEASURED_STEP_WORST: tuple[Measurement, ...] = (
    Measurement("Set up the dev environment", 12, "run 37790816989"),
    Measurement("Bootstrap Reprobuild", 101, "run 36590087746 (1h41m)"),
    Measurement("Build codetracer ct (via reprobuild)", 145,
                "run 36747212654 (2h20m on 36590087746)"),
    Measurement(
        "just test", 304 + PYTHON_PHASE_MINUTES,
        "run 38428391026: 17:00:36 -> suite verdict 22:04:04 = 5h03m28s, "
        "plus the Python phase, which that run did not get to finish"),
    Measurement(
        "just test", 268 + 320 + PYTHON_PHASE_MINUTES,
        "run 36583430437 on the slower host class: build phase 4h27m37s "
        "plus a runner phase of 5h19m21s (51m06s elapsed + the runner's own "
        "ETA of 4h28m15s; a projection, the run was killed at 16%)"),
    Measurement("Mirror logs to S3 (non-blocking)", 45, "run 36802573247"),
    Measurement("Refresh installation token for tests", 8,
                "run 37155665804 (worst token refresh; applies to each)"),
    Measurement("Refresh installation token for Reprobuild bootstrap", 8,
                "run 37155665804 (worst token refresh; applies to each)"),
    Measurement("Refresh installation token for CodeTracer source dependencies",
                8, "run 37155665804 (worst token refresh; applies to each)"),
    Measurement("Refresh installation token for the CodeTracer build", 8,
                "run 37155665804 (worst token refresh; applies to each)"),
)

# Worst measured duration of each phase a pinned run_tests.sh backstop bounds.
MEASURED_INNER_WORST: tuple[Measurement, ...] = (
    Measurement(ENV_BUILD_TIMEOUT, 249,
                "run 36583430437: the 1759-action .#test-builds graph took "
                "4h08m51s"),
    Measurement(ENV_RUNNER_TIMEOUT, 320,
                "run 36583430437: 51m06s elapsed + runner ETA 4h28m15s = "
                "5h19m21s (a projection on the slower host class; the "
                "completed run 38428391026 took 2h08m25s)"),
)

# A source location cited by line number (`repro.nim:537`).
LINE_NUMBER_CITATION = re.compile(
    r"\b[\w./-]+\.(?:nim|sh|py|md|org|ya?ml|toml):\d+")

# coreutils `timeout` DURATION: a number with an optional s/m/h/d suffix.
# https://www.gnu.org/software/coreutils/manual/html_node/timeout-invocation.html
TIMEOUT_DURATION = re.compile(r"^(\d+(?:\.\d+)?)([smhd]?)$")
_SUFFIX_SECONDS = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}


class WorkflowShapeError(Exception):
    """The workflow lacks something this checker must read (exit code 2)."""


@dataclass
class Step:
    """One item of a job's `steps:` list: its top-level scalars and `env:`."""

    index: int
    fields: dict[str, str] = field(default_factory=dict)
    env: dict[str, str] = field(default_factory=dict)

    @property
    def label(self) -> str:
        return (self.fields.get("name") or self.fields.get("uses")
                or f"<step {self.index + 1}>")


@dataclass
class Job:
    """The parts of one job this checker reads."""

    name: str
    fields: dict[str, str]
    runs_on: list[str]
    steps: list[Step]


def parse_duration_minutes(text: str) -> float:
    """Minutes in a coreutils ``timeout`` DURATION (``90``, ``5h``, ``330m``).

    Raises ``ValueError`` for anything else, and for 0, which disables the
    backstop rather than setting one.
    """
    match = TIMEOUT_DURATION.match(text.strip())
    if match is None:
        raise ValueError(
            f"{text!r} is not a coreutils timeout duration "
            "(N, Ns, Nm, Nh or Nd)")
    seconds = float(match.group(1)) * _SUFFIX_SECONDS[match.group(2)]
    if seconds <= 0:
        raise ValueError(f"{text!r} disables the backstop instead of setting one")
    return seconds / 60.0


def _scalar(raw: str) -> str:
    """A block-style YAML scalar's value, without quotes or a trailing comment."""
    value = raw.strip()
    if value[:1] in ("'", '"'):
        end = value.find(value[0], 1)
        if end > 0:
            return value[1:end]
    return re.sub(r"\s+#.*$", "", value).strip()


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _is_meaningful(line: str) -> bool:
    stripped = line.strip()
    return bool(stripped) and not stripped.startswith("#")


def _parse_step(index: int, lines: list[str], item_indent: int) -> Step:
    step = Step(index)
    key_indent = item_indent + 2
    current = None
    block: list[str] = []

    def close():
        if current is None:
            return
        head, body = block[0], block[1:]
        if current == "env" and head == "":
            step.env = _parse_mapping(body)
        elif head in ("|", "|-", ">", ">-"):
            step.fields[current] = "\n".join(body)
        else:
            step.fields[current] = _scalar(head)

    for raw in lines:
        prefix = raw[:key_indent]
        rest = raw[key_indent:]
        if prefix.strip() in ("", "-") and rest[:1] not in ("", " ", "#") \
                and re.match(r"[A-Za-z_][\w-]*:", rest):
            close()
            key, _, value = rest.partition(":")
            current, block = key.strip(), [value.strip()]
        elif current is not None:
            block.append(raw)
    close()
    return step


def _parse_mapping(body: list[str]) -> dict[str, str]:
    content = [line for line in body if _is_meaningful(line)]
    if not content:
        return {}
    indent = _indent(content[0])
    result: dict[str, str] = {}
    for line in content:
        if _indent(line) == indent and ":" in line:
            key, _, value = line.strip().partition(":")
            result[key.strip()] = _scalar(value)
    return result


def _parse_runs_on(value: str, block: list[str]) -> list[str]:
    value = value.strip()
    if value.startswith("["):
        inner = value.strip("[]")
        return [_scalar(part) for part in inner.split(",") if part.strip()]
    if value:
        return [_scalar(value)]
    return [_scalar(line.strip()[2:]) for line in block
            if line.strip().startswith("- ")]


def parse_job(workflow_text: str, job: str) -> Job:
    """Read ``jobs.<job>`` from block-style workflow YAML.

    Raises ``WorkflowShapeError`` when the job, its ``runs-on`` or its
    ``steps:`` cannot be found, so a reshaped workflow fails the check
    instead of yielding nothing to check.
    """
    lines = workflow_text.splitlines()
    try:
        start = lines.index(f"  {job}:")
    except ValueError:
        raise WorkflowShapeError(f"job `{job}` not found under `jobs:`") from None
    end = next((i for i in range(start + 1, len(lines))
                if re.match(r"^ {0,2}\S", lines[i]) and _is_meaningful(lines[i])),
               len(lines))
    body = lines[start + 1:end]

    # Job-level keys sit at indent 4.
    fields: dict[str, str] = {}
    blocks: dict[str, list[str]] = {}
    current = None
    steps_at = None
    for i, line in enumerate(body):
        if not _is_meaningful(line):
            continue
        if _indent(line) == 4:
            key, _, value = line.strip().partition(":")
            current = key.strip()
            fields[current] = _scalar(value) if value.strip() else ""
            blocks[current] = []
            if current == "steps":
                steps_at = i
                break
        elif current is not None:
            blocks[current].append(line)
    if "runs-on" not in fields:
        raise WorkflowShapeError(f"job `{job}` declares no `runs-on`")
    if steps_at is None:
        raise WorkflowShapeError(f"job `{job}` has no `steps:` list")
    runs_on = _parse_runs_on(fields["runs-on"], blocks.get("runs-on", []))

    steps: list[Step] = []
    current_lines: list[str] = []
    item_indent = None
    for line in body[steps_at + 1:]:
        if _is_meaningful(line) and _indent(line) <= 4:
            break  # a job key after `steps:`
        match = re.match(r"^( *)- ", line)
        if match and (item_indent is None or len(match.group(1)) == item_indent):
            item_indent = len(match.group(1))
            if current_lines:
                steps.append(_parse_step(len(steps), current_lines, item_indent))
            current_lines = [line]
        elif current_lines:
            current_lines.append(line)
    if current_lines:
        steps.append(_parse_step(len(steps), current_lines, item_indent))
    if not steps:
        raise WorkflowShapeError(f"job `{job}` has an empty `steps:` list")
    return Job(job, fields, runs_on, steps)


def _shown(value: str | None) -> str:
    return "none" if value is None else repr(value)


def _int_minutes(value: str | None) -> int | None:
    if value is None or not re.fullmatch(r"\d+", value.strip()):
        return None
    return int(value)


def line_number_citations(workflow_text: str) -> list[tuple[int, str]]:
    """``(line number, citation)`` for each comment citing a ``file:line``."""
    found = []
    for number, line in enumerate(workflow_text.splitlines(), start=1):
        match = re.search(r"(?:^|\s)#(.*)$", line)
        if match is None:
            continue
        for citation in LINE_NUMBER_CITATION.finditer(match.group(1)):
            found.append((number, citation.group(0)))
    return found


def check_workflow_text(
    workflow_text: str,
    *,
    measured_steps: Iterable[Measurement] = MEASURED_STEP_WORST,
    measured_inner: Iterable[Measurement] = MEASURED_INNER_WORST,
) -> list[str]:
    """Every violation of invariants (a)-(f), as one message each.

    Raises ``WorkflowShapeError`` when the job cannot be read at all.
    """
    job = parse_job(workflow_text, TEST_JOB)
    problems: list[str] = []

    # (a) the job ceiling.
    self_hosted = "self-hosted" in job.runs_on
    ceiling = (SELF_HOSTED_JOB_CEILING_MINUTES if self_hosted
               else HOSTED_JOB_CEILING_MINUTES)
    job_timeout = _int_minutes(job.fields.get("timeout-minutes"))
    if job_timeout is None:
        problems.append(
            f"(a) job `{job.name}` declares no integer `timeout-minutes` "
            f"(found {_shown(job.fields.get('timeout-minutes'))}); GitHub's "
            f"360-minute default then silently becomes the first limit to fire")
    elif job_timeout > ceiling:
        problems.append(
            f"(a) job `{job.name}` timeout-minutes {job_timeout} exceeds "
            f"GitHub's {ceiling}-minute limit for "
            f"{'self-hosted' if self_hosted else 'GitHub-hosted'} runners")

    # (b) every step's own limit.
    step_minutes: dict[int, int] = {}
    for step in job.steps:
        minutes = _int_minutes(step.fields.get("timeout-minutes"))
        if minutes is None or minutes < 1:
            problems.append(
                f"(b) step `{step.label}` declares no integer "
                f"`timeout-minutes` >= 1 "
                f"(found {_shown(step.fields.get('timeout-minutes'))})")
        else:
            step_minutes[step.index] = minutes

    # (c) the steps fit inside the job.
    if job_timeout is not None and len(step_minutes) == len(job.steps):
        total = sum(step_minutes.values()) + RUNNER_OVERHEAD_ALLOWANCE_MINUTES
        if total > job_timeout:
            problems.append(
                f"(c) step timeouts sum to {sum(step_minutes.values())} min, "
                f"+ {RUNNER_OVERHEAD_ALLOWANCE_MINUTES} min runner overhead "
                f"= {total} min, which exceeds the job's timeout-minutes "
                f"{job_timeout}; the job ceiling would fire before a step's "
                f"own limit and skip the `if: always()` steps")

    # (d) run_tests.sh's backstops fit inside the `just test` step.
    just_test = [s for s in job.steps if s.fields.get("name") == JUST_TEST_STEP_NAME]
    if len(just_test) != 1:
        raise WorkflowShapeError(
            f"expected exactly one step named `{JUST_TEST_STEP_NAME}` in job "
            f"`{job.name}`, found {len(just_test)}")
    step = just_test[0]
    inner: dict[str, float] = {}
    for var in (ENV_BUILD_TIMEOUT, ENV_RUNNER_TIMEOUT):
        raw = step.env.get(var)
        if raw is None:
            problems.append(
                f"(d) step `{step.label}` does not pin `{var}` in its `env:`; "
                f"run_tests.sh's defaults (8h per collection build, 24h "
                f"for the runner) then apply, unchecked against the step "
                f"limit")
            continue
        try:
            inner[var] = parse_duration_minutes(raw)
        except ValueError as error:
            problems.append(f"(d) step `{step.label}` `{var}`: {error}")
    step_timeout = step_minutes.get(step.index)
    if len(inner) == 2 and step_timeout is not None:
        need = (inner[ENV_BUILD_TIMEOUT] + inner[ENV_RUNNER_TIMEOUT]
                + JUST_TEST_IN_STEP_ALLOWANCE_MINUTES)
        if need > step_timeout:
            problems.append(
                f"(d) step `{step.label}`: {ENV_BUILD_TIMEOUT} "
                f"{inner[ENV_BUILD_TIMEOUT]:g} min + {ENV_RUNNER_TIMEOUT} "
                f"{inner[ENV_RUNNER_TIMEOUT]:g} min + "
                f"{JUST_TEST_IN_STEP_ALLOWANCE_MINUTES} min for the rest of "
                f"`just test` = {need:g} min exceeds the step's "
                f"timeout-minutes {step_timeout}; run_tests.sh's legible "
                f"backstops must fire before the step limit")

    # (e) every budget covers the worst measurement recorded for it.
    by_label = {s.label: s for s in job.steps}
    for measurement in measured_steps:
        target = by_label.get(measurement.subject)
        if target is None:
            problems.append(
                f"(e) measured step `{measurement.subject}` "
                f"({measurement.evidence}) is not a step of job `{job.name}`; "
                f"rename the measurement with the step, never drop it")
            continue
        budget = step_minutes.get(target.index)
        if budget is not None and budget < measurement.minutes:
            problems.append(
                f"(e) step `{target.label}` timeout-minutes {budget} is below "
                f"its measured worst of {measurement.minutes} min "
                f"({measurement.evidence})")
    for measurement in measured_inner:
        budget = inner.get(measurement.subject)
        if budget is not None and budget < measurement.minutes:
            problems.append(
                f"(e) step `{step.label}` `{measurement.subject}` = "
                f"{budget:g} min is below its measured worst of "
                f"{measurement.minutes} min ({measurement.evidence})")

    # (f) symbols, not line numbers.
    for number, citation in line_number_citations(workflow_text):
        problems.append(
            f"(f) line {number}: comment cites `{citation}` by line number; "
            f"cite the symbol instead (recording-issues.md, \"Cite symbols, "
            f"not line numbers\")")
    return problems


def check_workflow(path: Path) -> list[str]:
    """``check_workflow_text`` over a file; raises ``OSError`` if unreadable."""
    return check_workflow_text(path.read_text(encoding="utf-8"))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--workflow", type=Path, default=DEFAULT_WORKFLOW,
                        help="workflow file to check (default: ci.yml)")
    args = parser.parse_args(argv)
    try:
        problems = check_workflow(args.workflow)
    except (OSError, UnicodeDecodeError, WorkflowShapeError) as error:
        print(f"check_ci_test_budget: cannot check {args.workflow}: {error}",
              file=sys.stderr)
        return 2
    if problems:
        print(f"check_ci_test_budget: {args.workflow}: job `{TEST_JOB}` "
              f"violates {len(problems)} budget invariant(s):", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    print(f"check_ci_test_budget: {args.workflow}: job `{TEST_JOB}` ceiling "
          "and suite budget are a consistent pair")
    return 0


if __name__ == "__main__":
    sys.exit(main())
