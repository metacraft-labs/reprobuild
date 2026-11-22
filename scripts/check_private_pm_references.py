#!/usr/bin/env python3
"""Refuse a NEW reference to the private project-management repository.

WHY THIS EXISTS
===============

This repository is public. The project-management repository that holds its
specifications, its issue records and its milestone plans is not. Comments,
documentation, test names and messages here nevertheless cite that private
repository by name -- an issue file, a spec section, a milestone plan -- as the
place where the reason for the code is written down.

A public reader cannot follow such a pointer. The comment that should explain
the code instead sends the reader somewhere they are not allowed to go, and
what the pointer does reveal (file names, dates, plan names) is internal
planning detail that was never meant to be published.

The fix for an individual site is to state the reason in place: say in the
comment WHY the code is the way it is, in words a reader of this repository
can check. That is a rewrite, one comment at a time, and there are well over a
thousand of them. So the existing references are recorded as debt and burnt
down gradually; this lint makes sure the debt only shrinks while that happens.

WHAT THIS IS, AND WHAT IT IS NOT
================================

A RATCHET, exactly like ``check_bare_skips.py`` and
``check_ambient_execution.sh``. ``scripts/private-pm-references-baseline.tsv``
is not a list of blessed sites -- it is the list of files that already carry
the defect, with how many times each one does. A reference that is NOT covered
by it fails the check. Shrinking it is the work.

It is NOT the sweep. Nothing here rewrites a reference, and nothing here judges
whether a particular reference is harmless. Every occurrence counts the same.

WHAT COUNTS AS A REFERENCE
==========================

Every occurrence of the private repository's name (``PATTERN`` below),
matched CASE-INSENSITIVELY, in the content of every TRACKED file, binary files
included (``git grep -a``). Case-insensitive because a sentence that starts
with the name capitalises it, and a lint that a capital letter defeats is not
a lint. Binary files included because "it is not text" is not a reason a
reference may be published; none carries one today, so this costs nothing.

TRACKED FILES ONLY, for the reason ``check_superseded_doc_pointers.sh`` gives
in its own header: a working checkout's ignored files -- build/, .nimcache/,
test-logs/ -- are gigabytes once the suite has run, they quote source text, and
nobody commits them. ``git grep`` searches the working-tree content of the
files the index tracks, which is what a commit carries.

OCCURRENCES, NOT LINES. Two references on one line are two references; a lint
that counted lines would let the second one in for free.

EXCLUDED: this script and its baseline, and nothing else. This script has to
name the pattern to search for it. Any other file that needs to talk about the
pattern -- this lint's own test, for one -- assembles it from parts, so that it
is held to the same rule as everything else.

HOW A SITE IS IDENTIFIED
========================

By FILE, with a COUNT, never by line number. The sibling ratchets learned this
first and say so in their headers: a line number is invalidated by any edit
above the site, so a line-keyed baseline churns for reasons that have nothing
to do with the population it pins. A per-file count is stable under every edit
that does not touch a reference.

The consequences, stated rather than discovered later:

  * A reference that MOVES WITHIN A FILE is not reported. Neither is deleting
    one reference and adding another in the same file -- the count nets to
    zero. That is the price of not keying on line numbers or surrounding text,
    either of which would make the baseline churn on every unrelated edit.
  * A reference that moves to ANOTHER FILE is reported: the receiving file's
    count rises.
  * RENAMING a file that carries references is reported, because the new path
    is not on the baseline. Re-record with ``--write-baseline`` and say in the
    commit message that the change is a rename: the total does not change, and
    a reviewer can see that it did not.
  * A file not on the baseline must contain no reference at all.

THE RATCHET RUNS ONE WAY
========================

  * A file whose count EXCEEDS its row -- or that has no row -- is refused, by
    name, with every matching line in it.
  * A file whose count has FALLEN has been partly or wholly cleaned, and the
    baseline is rewritten with the smaller number (a row that reaches zero is
    dropped), and the run passes. This is ``check_bare_skips.py``'s convention:
    making an improvement also cost a manual baseline edit is how ratchets stop
    being maintained. Commit the rewritten file to lock the improvement in.
  * When both happen in one run, the rewrite is withheld and the run fails on
    the new reference, because recording a new baseline in the same breath as
    refusing one blesses the half of the tree the refusal is about.

ANTI-VACUITY
============

A scan that saw nothing finds no references; every row would then look
cleaned, and the rewrite rule would ERASE the record on its way through. So,
before the baseline is consulted:

  * ``git grep`` exiting with anything other than 0 (matches) or 1 (no match)
    is an error, never "zero references";
  * the number of tracked files must reach ``TRACKED_FILE_FLOOR``. The floor is
    on the size of the corpus, never on the reference count -- driving that to
    zero is the goal and must not be refused.

CROSS-CHECK
===========

Recorded when the baseline was first written, against commit 26a9fb2d3:
1254 occurrences in 773 files (case-insensitive). The same tree gives, by a
plain ``git grep -i``, 1253 matching lines in the same 773 files -- one line
carries two references -- and, case-SENSITIVELY, 1241 occurrences on 1240 lines
in 766 files. Re-recorded before landing against c2b87d245, which had gained
one reference meanwhile: 1255 occurrences in 773 files. Recompute with
``--cross-check`` rather than trusting this paragraph.

USAGE
=====

  scripts/check_private_pm_references.py
      [--top N]             # print the N files with the most references
      [--cross-check]       # print the line-based figures beside the count
      [--write-baseline]    # re-record the baseline from the current tree
      [--tracked-file-floor N]  # lower the anti-vacuity floor; for this
                                # lint's own test only

Locate every reference with
  git grep -n -i <the pattern in PATTERN below>

Exit codes, as the sibling ratchets use them:
  0 -- no new reference. If the tree has fewer references than the baseline,
       the file is rewritten smaller and the run still passes.
  1 -- at least one NEW reference, OR the baseline is unusable (missing,
       unparseable, or empty), OR the scan failed or came back below its floor.
       stderr names each one.
"""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

SCRIPT = pathlib.Path(__file__).resolve()
SCRIPT_DIR = SCRIPT.parent
ROOT = SCRIPT_DIR.parent

# The search pattern. This is the ONE place the repository's name may appear
# in this file; see "EXCLUDED" in the module docstring.
PATTERN = "reprobuild-pm"

BASELINE = SCRIPT_DIR / "private-pm-references-baseline.tsv"

# Measured 8090 tracked files at 26a9fb2d3. A floor, not a pin: it exists to
# tell "the tree improved" from "the scan saw nothing".
TRACKED_FILE_FLOOR = 6000

BASELINE_HEADER = """\
# References to the private project-management repository, per tracked file.
#
# See scripts/check_private_pm_references.py for what counts and why. In
# short: this repository is public, that one is not, and a comment that points
# a public reader at it explains nothing. This file pins the existing
# references so that their number can only fall while they are rewritten.
#
# Regenerate with: python3 scripts/check_private_pm_references.py --write-baseline
#
# Format: <tracked path>\\t<count of references in that file>
# Line numbers are deliberately absent so an edit above a reference does not
# invalidate the baseline.
#
# The ratchet runs ONE WAY. A file whose count EXCEEDS its row (or that has no
# row) is refused by name. A row whose count has fallen is rewritten smaller by
# the next run, and a row that has reached zero is dropped, so cleaning a file
# costs you no manual edit -- commit the result.
#
# To clean a row: replace the pointer with the explanation it points at,
# written so that a reader of this repository can check it.
"""


# ---------------------------------------------------------------------------
# Scanning
# ---------------------------------------------------------------------------


def git(root: pathlib.Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", str(root), *args],
        capture_output=True,
    )


def excluded_pathspecs(root: pathlib.Path) -> list[str]:
    """This script and its baseline, as root-relative exclude pathspecs.

    Computed from where the files actually are, so a copy of the script run
    from another checkout excludes its own files and nothing else.
    """
    specs = []
    for path in (SCRIPT, BASELINE):
        relative = path.relative_to(root).as_posix()
        specs.append(f":(exclude,literal){relative}")
    return specs


class ScanError(Exception):
    """The scan could not be trusted; never to be read as "no references"."""


def scan(root: pathlib.Path) -> tuple[dict[str, int], int]:
    """Count references per tracked file.

    Returns ``(counts, tracked_files)``: ``counts`` maps a root-relative path
    to its number of occurrences; ``tracked_files`` is the corpus size the
    anti-vacuity floor is checked against.
    """
    listed = git(root, "ls-files", "-z")
    if listed.returncode != 0:
        raise ScanError(
            f"`git ls-files` failed (exit {listed.returncode}): "
            f"{listed.stderr.decode(errors='replace').strip()}"
        )
    tracked_files = len([name for name in listed.stdout.split(b"\0") if name])

    # -o prints every occurrence on its own output line, which is what makes
    # this an occurrence count rather than a line count. -z puts a NUL after
    # the file name and after the line number, so a path is never quoted or
    # split. -F and -i are explicit so that no grep.* configuration can change
    # what the pattern means; --no-color so no colour codes reach the parser.
    occurrences = git(
        root,
        "-c", "grep.lineNumber=false",
        "-c", "grep.column=false",
        "grep", "--no-color", "-a", "-o", "-i", "-F", "-n", "-z",
        "-e", PATTERN,
        "--", ".", *excluded_pathspecs(root),
    )
    if occurrences.returncode not in (0, 1):
        raise ScanError(
            f"`git grep` failed (exit {occurrences.returncode}): "
            f"{occurrences.stderr.decode(errors='replace').strip()}"
        )

    counts: dict[str, int] = {}
    for record in occurrences.stdout.split(b"\n"):
        if not record:
            continue
        fields = record.split(b"\0")
        if len(fields) < 3:
            raise ScanError(f"unparseable `git grep` record: {record!r}")
        path = fields[0].decode("utf-8", errors="surrogateescape")
        counts[path] = counts.get(path, 0) + 1
    return counts, tracked_files


def matching_lines(root: pathlib.Path, path: str) -> list[str]:
    """The matching lines of one file, as ``<lineno>:<text>``, for the report.

    A second pass over only the files being refused, rather than carrying
    every matching line of every file through a run that passes.
    """
    result = git(
        root, "grep", "--no-color", "-a", "-i", "-F", "-n", "-h",
        "-e", PATTERN, "--", f":(literal){path}",
    )
    text = result.stdout.decode("utf-8", errors="replace")
    return [line for line in text.splitlines() if line]


# ---------------------------------------------------------------------------
# Baseline
# ---------------------------------------------------------------------------


def read_baseline(path: pathlib.Path) -> tuple[dict[str, int], list[str]]:
    """Parse the baseline into ``{path: count}``.

    A malformed row is an ERROR, never a skipped line: a parser that shrugged
    at a bad row would let the file be emptied by corruption and still report
    "no new references", the failure this baseline exists to prevent.
    """
    rows: dict[str, int] = {}
    errors: list[str] = []
    if not path.exists():
        return rows, [
            f"missing baseline: {path}. Regenerate with "
            f"`scripts/check_private_pm_references.py --write-baseline`."
        ]
    # CRLF-tolerant: Git may check the file out with CRLF on Windows.
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = line.rstrip("\r")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 2:
            errors.append(
                f"{path.name}:{number}: expected 2 tab-separated fields "
                f"(path, count), got {len(fields)}"
            )
            continue
        source, raw_count = fields[0], fields[1].strip()
        try:
            count = int(raw_count)
        except ValueError:
            errors.append(f"{path.name}:{number}: count `{raw_count}` is not an integer")
            continue
        if count < 1:
            errors.append(
                f"{path.name}:{number}: count {count} is not positive; a row that "
                f"pins nothing should be deleted, which the next run does for you"
            )
            continue
        if source in rows:
            errors.append(f"{path.name}:{number}: duplicate row for {source}")
        rows[source] = count
    return rows, errors


def render_baseline(rows: dict[str, int]) -> str:
    out = [BASELINE_HEADER]
    # Sorted by code point, so the file's order never depends on a locale.
    for source in sorted(rows):
        out.append(f"{source}\t{rows[source]}\n")
    return "".join(out)


def write_baseline(rows: dict[str, int]) -> None:
    BASELINE.write_text(render_baseline(rows), encoding="utf-8", newline="\n")


# ---------------------------------------------------------------------------
# The ratchet
# ---------------------------------------------------------------------------


def run_ratchet(root: pathlib.Path, measured: dict[str, int], write: bool) -> bool:
    """Compare the measured counts with the baseline. ``True`` means fail."""
    recorded, errors = read_baseline(BASELINE)
    total = sum(measured.values())

    if write:
        write_baseline(measured)
        added = sum(
            measured[key] - recorded.get(key, 0)
            for key in measured
            if measured[key] > recorded.get(key, 0)
        )
        removed = sum(
            recorded[key] - measured.get(key, 0)
            for key in recorded
            if measured.get(key, 0) < recorded[key]
        )
        print(
            f"check_private_pm_references: wrote {len(measured)} rows "
            f"({total} references) to {BASELINE.name} "
            f"(+{added} / -{removed} against the previous file)."
        )
        return False

    if errors:
        print("error: the private-reference baseline does not parse:", file=sys.stderr)
        for message in errors:
            print(f"    {message}", file=sys.stderr)
        return True

    if not recorded:
        # Once the burn-down reaches zero this branch is the finish line, and
        # the right move then is to delete the baseline mechanism rather than
        # keep an empty file -- so say that instead of refusing blindly.
        if not measured:
            print(
                "check_private_pm_references: no references and an empty baseline. "
                "The burn-down is complete; the baseline can now be retired in "
                "favour of a plain zero-tolerance check."
            )
            return False
        print(
            f"error: {BASELINE.name} has no rows, so every one of the {total} "
            f"references in the tree is a new offender. That is not a useful "
            f"diagnostic -- regenerate it with --write-baseline.",
            file=sys.stderr,
        )
        return True

    arrived = sorted(key for key in measured if measured[key] > recorded.get(key, 0))
    improved = sorted(key for key in recorded if measured.get(key, 0) < recorded[key])

    if arrived:
        print(
            "FAIL: new reference(s) to the private project-management repository.",
            file=sys.stderr,
        )
        print("", file=sys.stderr)
        print(
            "      This repository is public and that one is not, so a public reader\n"
            "      cannot follow the pointer. State the reason in place instead: say\n"
            "      in the comment, doc or message itself why the code is the way it\n"
            "      is, in words a reader of this repository can check. Do not cite\n"
            "      private issue, spec or milestone files.",
            file=sys.stderr,
        )
        print("", file=sys.stderr)
        for source in arrived:
            was = recorded.get(source, 0)
            now = measured[source]
            detail = (
                f"{now} reference(s), file not on the baseline"
                if was == 0
                else f"{was} -> {now} references"
            )
            print(f"  {source}  [{detail}]", file=sys.stderr)
            for line in matching_lines(root, source):
                print(f"      {line}", file=sys.stderr)
        print("", file=sys.stderr)
        print(
            f"      {len(arrived)} file(s) gained a reference. The count is per file,\n"
            f"      so every matching line of such a file is listed above, old ones\n"
            f"      included. If the change only RENAMED a file that already carried\n"
            f"      references, re-record with --write-baseline and say so in the\n"
            f"      commit message.",
            file=sys.stderr,
        )
        if improved:
            print(
                f"      ({len(improved)} baseline row(s) also shrank; they are NOT "
                f"rewritten while this run is failing.)",
                file=sys.stderr,
            )
        return True

    if improved:
        write_baseline(measured)
        removed = sum(recorded[key] - measured.get(key, 0) for key in improved)
        print(
            f"check_private_pm_references: {removed} reference(s) across "
            f"{len(improved)} file(s) are gone -- {BASELINE.name} rewritten "
            f"smaller. COMMIT IT to lock the improvement in:"
        )
        for source in improved:
            print(f"    {source}  {recorded[source]} -> {measured.get(source, 0)}")

    print(
        f"check_private_pm_references: {total} reference(s) in {len(measured)} "
        f"file(s), all baselined."
    )
    return False


def cross_check(root: pathlib.Path, measured: dict[str, int]) -> None:
    """Print the line-based figures a plain ``git grep`` gives, beside ours."""

    def figure(*flags: str) -> tuple[int, int]:
        result = git(
            root, "grep", "--no-color", "-a", "-F", "-c", *flags,
            "-e", PATTERN, "--", ".", *excluded_pathspecs(root),
        )
        rows = [line for line in result.stdout.decode(errors="replace").splitlines() if line]
        return sum(int(row.rsplit(":", 1)[1]) for row in rows), len(rows)

    lines_i, files_i = figure("-i")
    lines_cs, files_cs = figure()
    print("")
    print("check_private_pm_references: cross-check against plain git grep -c.")
    print(f"  this scanner (occurrences, case-insensitive): "
          f"{sum(measured.values())} in {len(measured)} files")
    print(f"  git grep -c -i (matching lines):               {lines_i} in {files_i} files")
    print(f"  git grep -c    (matching lines, exact case):   {lines_cs} in {files_cs} files")
    print("  The scanner counts at least as many as the case-insensitive line count:")
    print("  a line with two references is one grep line and two occurrences.")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Refuse a new reference to the private project-management "
        "repository (see the module docstring)."
    )
    parser.add_argument(
        "--top", type=int, default=0, help="print the N files with the most references"
    )
    parser.add_argument("--cross-check", action="store_true")
    parser.add_argument("--write-baseline", action="store_true")
    # For this lint's own test, which runs the script in a scratch repository
    # of a handful of files. Never passed by the `lint` recipe.
    parser.add_argument(
        "--tracked-file-floor", type=int, default=TRACKED_FILE_FLOOR,
        help=argparse.SUPPRESS,
    )
    arguments = parser.parse_args()

    root = ROOT
    try:
        measured, tracked_files = scan(root)
    except ScanError as error:
        print(f"error: {error}", file=sys.stderr)
        print(
            "       Refusing rather than reading a failed scan as zero references.",
            file=sys.stderr,
        )
        return 1

    # Anti-vacuity, before the baseline is consulted; see the docstring.
    if tracked_files < arguments.tracked_file_floor:
        print(
            f"error: only {tracked_files} tracked files, floor "
            f"{arguments.tracked_file_floor}. "
            f"A scan this small would report the baseline's rows as cleaned for "
            f"reasons that have nothing to do with the tree. Refusing rather than "
            f"comparing.",
            file=sys.stderr,
        )
        return 1

    print(
        f"check_private_pm_references: {tracked_files} tracked files; "
        f"{sum(measured.values())} reference(s) in {len(measured)} file(s)."
    )

    if arguments.top:
        print("")
        print(f"check_private_pm_references: the {arguments.top} worst files, for burn-down.")
        ranked = sorted(measured.items(), key=lambda row: (-row[1], row[0]))
        for source, count in ranked[: arguments.top]:
            print(f"  {count:5d}  {source}")

    if arguments.cross_check:
        cross_check(root, measured)

    failed = run_ratchet(root, measured, write=arguments.write_baseline)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
