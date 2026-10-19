#!/usr/bin/env python3
"""Regenerate the build-free suite artifacts and describe the result as a PR.

WHY THIS EXISTS

`scripts/check_suite_case_counts.sh` refuses a tree whose checked-in
description of the test suite is stale. It reports, and reporting is not
recovery: when a stale artifact reached `dev`, `dev` stayed stale until someone
volunteered a regeneration -- five consecutive commits, with every pull request
opened in that window inheriting the red (reprobuild-pm issue 2026-10-01,
"suite case-count baseline is stale on dev"). The spec's "Mainline recovery"
rule (reprobuild-pm `spec/Test-Designs/Test-Suite-Architecture-Guidelines.md`,
"Suite-Artifact Staleness") makes CI open a pull request carrying the
regeneration instead. This script is the half of that which runs in a
checkout; `.github/workflows/suite-case-counts.yml`'s `regenerate-on-dev` job
is the half that commits, pushes and opens the pull request.

WHAT IT REGENERATES, AND WHAT IT MUST NOT

Exactly the two artifacts that are a FACT about the source text, with exactly
the commands the gate's refusal prints -- read from the scanner's own
`*_REGENERATE_COMMAND` constants, so the two cannot drift apart:

  * scripts/reprobuild-suite-static-case-counts.tsv
  * benchmarks/reports/reprobuild-suite-m0-inventory-sources.json

Nothing that records a JUDGEMENT is touched: the bare-skips baseline (each row
accepts a defect), the uninvoked-shell-tests baseline (each row accepts an
unrun script), and the edge table `repro_tests.nim` with the shape-parity
verdicts the edge generator writes beside it (enrolling a test is a decision,
and needs the Nim generator besides). Regenerating those would turn every red
they raise into a silent acceptance. They are snapshotted before and compared
after, and a change to any of them is an error, not a pull request.

A DECREASE IS NOT ROUTINE

A regeneration also records coverage that LEFT the suite -- a source that lost
cases or stopped being declared. The scanner already labels those lines
`COVERAGE LOST` / `RECORDED BUT NO LONGER DECLARED`; when the drift report
carries either, the body opens with a review marker and the title says so,
because merging it accepts the loss.

STILL RED AFTERWARDS

After regenerating, the gate is run again, and so is the bare-skips lint
(which the gate does not run but whose baseline is one of the judgement files
above). Whatever is still red -- an unenrolled source, a shape-parity
divergence, a new bare skip -- is quoted in the body, so a reviewer does not
merge the pull request believing `dev` is green.

USAGE

  scripts/regenerate_suite_artifacts.py BODY.md [--title-file TITLE.txt]
                                        [--repo-root DIR]

Exit codes:
  0 -- at least one artifact changed; BODY.md (and TITLE.txt) were written and
       a pull request is warranted.
  3 -- neither artifact changed: the tree was not stale in these two. Nothing
       is written. (Whatever made the gate red needs a judgement, not this.)
  1 -- error: a command failed, an input is missing, or a judgement file was
       modified (it is restored before exiting).
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

# `python3 scripts/regenerate_suite_artifacts.py` puts scripts/ on sys.path,
# so the scanner imports by name: its constants are the single source of the
# regeneration commands and artifact paths. No bytecode: this runs in the
# checkout that becomes the pull request, and should leave in it only the two
# files it regenerates.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import reprobuild_suite_inventory as inventory  # noqa: E402

EXIT_CHANGED = 0
EXIT_ERROR = 1
EXIT_UNCHANGED = 3

REGENERATIONS = (
    (inventory.STATIC_CASE_COUNTS_PATH, inventory.STATIC_CASE_COUNTS_REGENERATE_COMMAND),
    (inventory.SOURCE_INVENTORY_PATH, inventory.SOURCE_INVENTORY_REGENERATE_COMMAND),
)

JUDGEMENT_FILES = (
    Path("scripts/bare-skips-baseline.tsv"),
    inventory.UNINVOKED_SHELL_TESTS_BASELINE_PATH,
    Path("repro_tests.nim"),
    inventory.SHAPE_PARITY_PATH,
)

GATE_COMMAND = "bash scripts/check_suite_case_counts.sh"
BARE_SKIPS_COMMAND = "python3 scripts/check_bare_skips.py"

COVERAGE_LOSS_LABELS = ("COVERAGE LOST", "RECORDED BUT NO LONGER DECLARED")

# GitHub refuses a pull request body over 65,536 characters. Each quoted
# output is capped well under that so the body always posts; the full text is
# in the workflow log.
MAX_QUOTED_CHARS = 20_000


class RegenerationError(Exception):
    pass


@dataclass
class CommandResult:
    command: str
    returncode: int
    output: str


def interpreter() -> str:
    # Same resolution the gate uses (`${PYTHON:-python3}`), falling back to
    # the interpreter running this script rather than to whatever `python3`
    # happens to be on PATH.
    return os.environ.get("PYTHON") or sys.executable


def run_command(root: Path, command: str) -> CommandResult:
    """Run one of the printed commands verbatim, with only `python3` resolved."""
    argv = shlex.split(command)
    if argv[0] == "python3":
        argv[0] = interpreter()
    env = dict(os.environ, PYTHON=interpreter())
    # The re-run gate is asked for a verdict, not an attribution: after a
    # regeneration there is no drift left in the two artifacts to attribute,
    # and an inherited base would only add a worktree checkout.
    for name in ("SUITE_CASE_COUNTS_BASE", "PRE_COMMIT_FROM_REF"):
        env.pop(name, None)
    try:
        completed = subprocess.run(
            argv,
            cwd=str(root),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except OSError as error:
        raise RegenerationError(f"could not run `{command}`: {error}") from error
    return CommandResult(command, completed.returncode, completed.stdout)


def read_optional(path: Path) -> bytes | None:
    return path.read_bytes() if path.is_file() else None


def snapshot(root: Path, paths) -> dict[Path, bytes | None]:
    return {path: read_optional(root / path) for path in paths}


def restore(root: Path, saved: dict[Path, bytes | None]) -> None:
    for path, content in saved.items():
        target = root / path
        if content is None:
            target.unlink(missing_ok=True)
        else:
            target.write_bytes(content)


def head_revision(root: Path) -> str:
    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=str(root),
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip() if completed.returncode == 0 else ""


def fenced(text: str) -> str:
    """`text` as a Markdown code block that its own content cannot close."""
    text = text.rstrip("\n")
    if len(text) > MAX_QUOTED_CHARS:
        text = (
            text[:MAX_QUOTED_CHARS]
            + f"\n… truncated ({len(text) - MAX_QUOTED_CHARS} more characters;"
            " the full output is in the workflow log)"
        )
    longest = max((len(run) for run in re.findall(r"`+", text)), default=0)
    fence = "`" * max(3, longest + 1)
    return f"{fence}text\n{text}\n{fence}"


def render_title(short: str, coverage_lost: bool) -> str:
    title = "chore(suite): regenerate suite artifacts for dev"
    if short:
        title += f" at {short}"
    if coverage_lost:
        title += " (coverage lost: needs review)"
    return title


def render_body(
    revision: str,
    changed: list[Path],
    writes: list[CommandResult],
    still_red: list[CommandResult],
) -> tuple[str, bool]:
    drift = "\n\n".join(result.output.rstrip("\n") for result in writes)
    coverage_lost = any(label in drift for label in COVERAGE_LOSS_LABELS)
    at = f"`{revision}`" if revision else "the checked-out commit"
    lines: list[str] = []
    if coverage_lost:
        lines += [
            "> [!WARNING]",
            "> **Needs review: coverage lost.** The drift below includes "
            + " / ".join(f"`{label}`" for label in COVERAGE_LOSS_LABELS)
            + " lines: tests that left the suite or declare fewer cases than"
            " recorded. Merging this records the loss as the new baseline, so"
            " confirm each one was intended.",
            "",
        ]
    lines += [
        f"The `Suite case counts` gate failed on `dev` at {at}: the checked-in"
        " description of the test suite was stale. This pull request carries"
        " the regeneration, made with exactly the commands the gate's refusal"
        " prints:",
        "",
        *(f"- `{command}`" for _, command in REGENERATIONS),
        "",
        "Changed: " + ", ".join(f"`{path}`" for path in changed) + ".",
        "",
        "Nothing that records a judgement was regenerated: "
        + ", ".join(f"`{path}`" for path in JUDGEMENT_FILES)
        + " are untouched.",
        "",
        "## Drift report",
        "",
        fenced(drift),
        "",
    ]
    if still_red:
        lines += [
            "## Still red after regeneration",
            "",
            "These checks still fail on this branch. Fixing them is a judgement"
            " (enrol or delete a test, record or explain a skip) that this"
            " automation does not make, so merging this pull request alone"
            " does NOT make `dev` green.",
            "",
        ]
        for result in still_red:
            lines += [
                f"`{result.command}` exited {result.returncode}:",
                "",
                fenced(result.output),
                "",
            ]
    else:
        lines += [
            f"After regeneration `{GATE_COMMAND}` and `{BARE_SKIPS_COMMAND}`"
            " both pass.",
            "",
        ]
    lines += [
        "Opened by the `regenerate-on-dev` job of"
        " `.github/workflows/suite-case-counts.yml`. Later stale pushes to"
        " `dev` update this pull request in place.",
    ]
    return "\n".join(lines) + "\n", coverage_lost


def regenerate(root: Path, body_path: Path, title_path: Path | None) -> int:
    for script in (Path("scripts/check_suite_case_counts.sh"), Path("scripts/check_bare_skips.py")):
        # Fatal, not skipped: a follow-up check that silently does not run
        # would let the body claim `dev` is green when nobody looked.
        if not (root / script).is_file():
            raise RegenerationError(f"{root / script} not found")

    artifacts = [path for path, _ in REGENERATIONS]
    before = snapshot(root, artifacts)
    judgement = snapshot(root, JUDGEMENT_FILES)

    writes: list[CommandResult] = []
    for _, command in REGENERATIONS:
        result = run_command(root, command)
        sys.stdout.write(result.output)
        if result.returncode != 0:
            raise RegenerationError(
                f"`{command}` exited {result.returncode}"
            )
        writes.append(result)

    if snapshot(root, JUDGEMENT_FILES) != judgement:
        restore(root, judgement)
        raise RegenerationError(
            "a judgement file changed during regeneration and was restored; "
            "the regeneration must write only "
            + ", ".join(str(path) for path in artifacts)
        )

    after = snapshot(root, artifacts)
    changed = [path for path in artifacts if after[path] != before[path]]
    if not changed:
        print(
            "regenerate_suite_artifacts: neither artifact changed; "
            "nothing to propose."
        )
        return EXIT_UNCHANGED

    still_red: list[CommandResult] = []
    for command in (GATE_COMMAND, BARE_SKIPS_COMMAND):
        result = run_command(root, command)
        if result.returncode != 0:
            sys.stdout.write(result.output)
            still_red.append(result)

    revision = head_revision(root)
    body, coverage_lost = render_body(revision, changed, writes, still_red)
    title = render_title(revision[:10], coverage_lost)
    body_path.write_text(body, encoding="utf-8", newline="\n")
    if title_path is not None:
        title_path.write_text(title + "\n", encoding="utf-8", newline="\n")
    print(f"title: {title}")
    print(f"wrote {body_path}")
    return EXIT_CHANGED


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Regenerate the build-free suite artifacts and write a "
        "pull request body describing the drift."
    )
    parser.add_argument("body", help="where to write the Markdown PR body")
    parser.add_argument(
        "--title-file", help="where to write the one-line PR title suggestion"
    )
    parser.add_argument(
        "--repo-root",
        default=None,
        help="the checkout to regenerate (default: this script's repository)",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    root = (
        Path(args.repo_root) if args.repo_root else Path(__file__).resolve().parent.parent
    ).resolve()
    try:
        return regenerate(
            root,
            Path(args.body).resolve(),
            Path(args.title_file).resolve() if args.title_file else None,
        )
    except RegenerationError as error:
        print(f"regenerate_suite_artifacts: error: {error}", file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
