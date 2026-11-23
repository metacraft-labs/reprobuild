#!/usr/bin/env python3
"""Say whether a CI test run is a verdict on the code or only a partial run.

WHY THIS EXISTS
===============

A CI job's conclusion reads as a verdict on the code whether or not the suite
behind it finished. For weeks the reprobuild ``test`` job ended ``cancelled``
at GitHub's job ceiling, and readers took that as "the suite did not run" --
including on run 38428391026, where the suite HAD run to completion (10691
cases, 105 failures) 7m45s before the ceiling killed the step. A job that
stops early must say that it stopped early, in words, where the conclusion is
read (reprobuild-pm issue
2026-09-30-reprobuild-ci-cannot-finish-within-the-six-hour-ceiling,
"stop reporting a truncated run as a result").

This script is that statement. It reads the runner's summary document
(``test-logs/parallel-run.json``, written by
tools/test-runner/repro_test_runner.nim), the end-of-script marker
(``test-logs/suite-finished.json``, written by ``scripts/run_tests.sh``
immediately before its final ``exit``, after the Python modules have run, and
deleted at its start) and the outcome of the step that produced them, and
prints one of:

  COMPLETE -- the step finished on its own (``success`` or ``failure``), the
              marker exists and parses (so run_tests.sh reached its end,
              Python phase included), the summary parses, it was not cut
              short, it is not a selected subset, and it ran at least as many
              cases as it planned (planned > 0). The job's conclusion IS a
              verdict on the code; a ``failure`` here is a red result, not a
              timeout.
  PARTIAL  -- anything else. It says how far the run got (from the summary
              when there is one, including the cases never started) and that
              the job's conclusion is NOT a verdict on the code.

It also emits a GitHub annotation (``::notice::`` for COMPLETE,
``::warning::`` for PARTIAL) and, when given ``--step-summary``, appends a
markdown section to that file (``$GITHUB_STEP_SUMMARY``).

WHAT IT IS NOT
==============

It is a declaration, not a gate: it always exits 0. The ``just test`` step's
own status carries the gate, and failure propagation is deliberately left
where it was. The marker is what closes the gap between the runner's
summary and the step's status: the summary can be complete while the step is
then killed in the Python phase (a step ``timeout-minutes`` reports
``failure``, which alone would read as a finished run). Without the marker
such a run is PARTIAL.

USAGE
=====

  python3 scripts/ci_suite_coverage.py --summary test-logs/parallel-run.json \\
      --finished-marker test-logs/suite-finished.json \\
      --outcome "${{ steps.just_test.outcome }}" \\
      [--step-summary "$GITHUB_STEP_SUMMARY"]
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

# Outcomes for which the step ran to its own end. `cancelled` (a job ceiling,
# a superseding push, a manual cancel) and `skipped` (an earlier step failed)
# mean the suite was stopped or never started by something other than itself.
FINISHED_OUTCOMES = ("success", "failure")
KNOWN_OUTCOMES = FINISHED_OUTCOMES + ("cancelled", "skipped")


@dataclass(frozen=True)
class Coverage:
    """The declaration: whether the run is a verdict, and the words saying so."""

    complete: bool
    headline: str
    details: tuple[str, ...]


def _count(summary: dict, key: str) -> int | None:
    value = summary.get(key)
    # bool is an int subclass; a boolean where a count belongs is malformed.
    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
        return value
    return None


def load_summary(path: Path) -> tuple[dict | None, str | None]:
    """``(summary object, None)``, or ``(None, why it is unusable)``."""
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None, f"no runner summary at {path} (the runner never wrote one)"
    except (OSError, UnicodeDecodeError) as error:
        return None, f"runner summary {path} is unreadable: {error}"
    try:
        document = json.loads(text)
    except json.JSONDecodeError as error:
        return None, f"runner summary {path} is not valid JSON: {error}"
    summary = document.get("summary") if isinstance(document, dict) else None
    if not isinstance(summary, dict):
        return None, f"runner summary {path} has no `summary` object"
    return summary, None


def load_marker(path: Path) -> tuple[dict | None, str | None]:
    """``(marker object, None)``, or ``(None, why it does not vouch)``."""
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None, (f"the suite step did not reach its end (Python phase or "
                      f"later did not finish): no marker at {path}")
    except (OSError, UnicodeDecodeError) as error:
        return None, f"end-of-suite marker {path} is unreadable: {error}"
    try:
        marker = json.loads(text)
    except json.JSONDecodeError as error:
        return None, f"end-of-suite marker {path} is not valid JSON: {error}"
    if not isinstance(marker, dict) or _count(marker, "suite_status") is None:
        return None, (f"end-of-suite marker {path} carries no integer "
                      f"`suite_status`")
    return marker, None


def assess(summary: dict | None, summary_problem: str | None,
           outcome: str, marker: dict | None = None,
           marker_problem: str | None = None) -> Coverage:
    """Decide COMPLETE or PARTIAL from the summary, marker and step outcome.

    A missing ``marker`` is never COMPLETE: the summary alone cannot show
    that the Python phase after the runner finished.
    """
    outcome = (outcome or "").strip() or "<empty>"
    details: list[str] = [f"`just test` step outcome: {outcome}"]
    reasons: list[str] = []
    if outcome not in KNOWN_OUTCOMES:
        reasons.append(f"step outcome {outcome!r} is not one GitHub reports")
    elif outcome not in FINISHED_OUTCOMES:
        reasons.append(f"the step did not finish on its own (outcome {outcome})")

    if marker is None:
        reasons.append(marker_problem or "no end-of-suite marker was given")
    else:
        failed_modules = marker.get("python_failed_modules")
        shown_modules = (len(failed_modules) if isinstance(failed_modules, list)
                         else "?")
        details.append(f"run_tests.sh reached its end: suite_status="
                       f"{marker['suite_status']} python_failed_modules="
                       f"{shown_modules}")

    total = planned = None
    if summary is None:
        reasons.append(summary_problem or "no runner summary")
    else:
        total = _count(summary, "total")
        planned = _count(summary, "planned_total")
        counts = {key: _count(summary, key) for key in (
            "passed", "failed", "skipped", "harness_errors",
            "status_disagreements")}
        shown = " ".join(f"{key}={'?' if value is None else value}"
                         for key, value in counts.items())
        details.append(f"runner summary: total={'?' if total is None else total} "
                       f"planned_total={'?' if planned is None else planned} {shown}")
        cut_short = summary.get("cut_short")
        if total is None or planned is None:
            reasons.append("the summary lacks a valid `total` / `planned_total`")
        elif planned == 0:
            reasons.append("the summary planned no cases at all")
        elif total < planned:
            reasons.append(f"it ran {total} of {planned} planned cases; "
                           f"{planned - total} were never started")
        if cut_short is not False:
            if cut_short is True:
                detail = summary.get("cut_short_detail")
                why = ""
                if isinstance(detail, dict):
                    signal = detail.get("signal_name") or detail.get("signal")
                    never = detail.get("cases_never_started")
                    why = f" by {signal}" if signal else ""
                    if isinstance(never, int) and not isinstance(never, bool):
                        why += f"; {never} cases never started"
                reasons.append(f"the runner was cut short{why}")
            else:
                reasons.append("the summary does not state `cut_short`")
        selection = summary.get("selection")
        if isinstance(selection, dict) and selection.get("selected_subset") is True:
            reasons.append("the runner executed a selected subset, not the suite")

    if not reasons and summary is not None and marker is not None:
        counts_text = ", ".join(
            f"{_count(summary, key) or 0} {label}" for key, label in (
                ("passed", "passed"), ("failed", "failed"),
                ("skipped", "skipped"), ("harness_errors", "harness errors")))
        headline = (f"COMPLETE: the suite reached a verdict on all {total} cases "
                    f"({counts_text}) -- this conclusion IS a verdict on the code")
        return Coverage(True, headline, tuple(details))

    progress = (f"it got through {total} of {planned} planned cases"
                if total is not None and planned is not None
                else "how far it got is unknown")
    headline = (f"PARTIAL: {progress} -- this job's conclusion is NOT a verdict "
                f"on the code")
    details.extend(f"why partial: {reason}" for reason in reasons)
    return Coverage(False, headline, tuple(details))


def annotation(coverage: Coverage) -> str:
    """The workflow command GitHub renders as an annotation on the run."""
    level = "notice" if coverage.complete else "warning"
    # Workflow-command data must escape %, CR and LF.
    # https://docs.github.com/en/actions/reference/workflow-commands-for-github-actions
    message = "\n".join((coverage.headline,) + coverage.details)
    message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    return f"::{level} title=Suite coverage::{message}"


def markdown(coverage: Coverage) -> str:
    lines = ["## Suite coverage", "", f"**{coverage.headline}**", ""]
    lines.extend(f"- {detail}" for detail in coverage.details)
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--summary", type=Path, required=True,
                        help="the runner's summary JSON (test-logs/parallel-run.json)")
    parser.add_argument("--finished-marker", type=Path, required=True,
                        help="run_tests.sh's end-of-script marker "
                             "(test-logs/suite-finished.json)")
    parser.add_argument("--outcome", required=True,
                        help="steps.<just test>.outcome: success|failure|cancelled|skipped")
    parser.add_argument("--step-summary", type=Path,
                        help="append a markdown section here ($GITHUB_STEP_SUMMARY)")
    args = parser.parse_args(argv)

    summary, problem = load_summary(args.summary)
    marker, marker_problem = load_marker(args.finished_marker)
    coverage = assess(summary, problem, args.outcome, marker, marker_problem)
    print(coverage.headline)
    for detail in coverage.details:
        print(f"  {detail}")
    print(annotation(coverage))
    if args.step_summary is not None:
        try:
            with args.step_summary.open("a", encoding="utf-8") as handle:
                handle.write(markdown(coverage))
        except OSError as error:
            # Still a declaration: the console line and annotation above
            # carry it, so a broken summary file must not change the job.
            print(f"ci_suite_coverage: could not append to {args.step_summary}: "
                  f"{error}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
