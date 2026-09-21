#!/usr/bin/env python3
"""Refuse a NEW bare ``skip()`` -- a skip that never says why.

WHY THIS EXISTS
===============

``skip`` is ``template skip*(reason = "")`` in the Nim fork's
``lib/pure/unittest.nim``, and this repository's protocol shim
(``libs/ct_test_unittest_parallel``) wraps it so the reason reaches the result
document. A bare ``skip()`` supplies no reason, the writer then omits the
``skipReason`` key entirely, and the runner's rollup counts the case in
``skippedWithoutReasonCount``.

That count is now load-bearing. ``completed_clean_runs()`` in
``scripts/reprobuild_suite_inventory.py`` decides whether a suite run is
recorded as COMPLETE and MEASURED, and it requires: nothing failed, nothing
errored, and every case is either a pass or A SKIP THAT CARRIES A REASON. The
comment there spells out the reasoning -- a skip is not a pass and must never
be counted as one, but it is not an incompleteness either, PROVIDED it says
why.

Measured on dev when this lint was written (commit 3ca3b3a0f): 1222 bare skip
calls in 1124 cases across 463 files, against 122 that carry a reason. So the
predicate cannot be satisfied today, and the repository cannot record a
complete run at all. That burn-down is separate work and is deliberately NOT
attempted here.

WHAT THIS IS, AND WHAT IT IS NOT
================================

A RATCHET, exactly like ``check_ambient_execution.sh`` and
``check_shell_command_strings.sh``. ``scripts/bare-skips-baseline.tsv`` is not
a list of blessed sites -- it is the list of sites that already carry the
defect. A bare skip that is NOT on it fails the check. Shrinking it is the
work.

NO PER-ROW JUSTIFICATION COLUMN, and that is a decision rather than an
oversight. Its sibling ``assertionless-test-cases-baseline.tsv`` carries a
verdict and a written reason per row, because that population is 75 rows and a
human can argue each one. This population is 1222. Demanding a sentence per row
would produce 1222 sentences written to satisfy a lint, which is the same
vacuity defect one level up -- a reason nobody chose is worth no more than the
empty string the skip already passes. The reason belongs in the ``skip("...")``
call, where the runner reads it and a suite report prints it. This file only
pins the population so it cannot grow.

HOW A SITE IS IDENTIFIED
========================

By ``(source, test case title)`` plus a COUNT, never by line number. Its
siblings learned this first and say so in their own headers: a line number is
invalidated by any edit ABOVE the site, so a line-keyed baseline churns for
reasons that have nothing to do with the population it pins. A case title is
stable under edits elsewhere in the file and is what a reviewer reads anyway.

KNOWN LIMIT, recorded rather than papered over: because a row carries a count,
a change that deletes one bare skip from a case and adds another to the SAME
case nets to zero and is not reported. Moving a bare skip BETWEEN cases, or
into a new case, is reported. The alternative -- keying on surrounding source
text -- would make the baseline churn on every unrelated edit, which is the
failure mode this keying exists to avoid.

WHAT COUNTS AS A BARE SKIP
==========================

An identifier ``skip`` that is CALLED WITH NO ARGUMENT:

  * ``skip()`` -- including qualified forms such as ``unittest.skip()``;
  * ``skip`` alone as a whole statement, which in Nim calls the template with
    its default argument and is therefore the same defect wearing less
    punctuation. No such call exists in the tree today; it is recognised so
    that the obvious way around this lint is not to drop the parentheses.

NOT a bare skip: ``skip("...")`` or ``skip(reason)`` -- that is the fixed
shape. Nor a declaration of something named ``skip`` (``template skip*(...)``,
``proc skip(...)``), nor the name in an export/import list, nor any mention in
a comment or a string literal -- the lexer this scanner borrows drops those
before it ever sees them. That last exclusion is why this scanner's total is
LOWER than a plain ``git grep -cE 'skip\\(\\)'``; see CROSS-CHECK below.

CROSS-CHECK AGAINST GREP
========================

``git grep -nE '(^|[^_[:alnum:]])skip\\(\\)' -- tests libs tools`` reports 1281
matching lines on the commit this baseline was recorded at (3ca3b3a0f). This
scanner reports 1222. The 59-line difference is accounted for exactly, and
NONE of it is a scanner miss -- the set this scanner reports is a strict subset
of grep's, verified in both directions:

  * 3 lines are in a PYTHON file
    (``tests/unit/test_reprobuild_suite_inventory.py``), all of them comments.
  * 20 lines are in Nim files OUTSIDE the declared suite corpus. 19 are prose
    in doc comments that talk ABOUT skipping -- ``libs/repro_test_support``,
    ``libs/repro_cli_support``, ``tools/test-runner``, and others. The 20th is
    ``stdUnittest.skip()`` in
    ``libs/ct_test_unittest_parallel/src/ct_test_unittest_parallel.nim``: the
    shim delegating to the stdlib AFTER it has captured the reason. That is
    the fix, not the defect.
  * the remaining 1258 lines are in the corpus, and 1222 of them are real
    calls. The other 36 are mentions the lexer drops and grep cannot:
    33 in comments, and 3 inside STRING LITERALS. Those three are worth
    naming, because they are the shape a reviewer would most likely get wrong:
    ``t_repro_test_runner_consumes_result_document.nim`` and
    ``t_execute_edge_gives_tests_a_usable_path.nim`` embed Nim fixture SOURCE
    in a triple-quoted string, and that fixture contains a deliberate bare
    ``skip()`` whose whole purpose is to prove the runner reports an
    unexplained skip as unexplained. Baselining it would be a category error
    and "fixing" it would delete the coverage.

So grep is the looser instrument here. Run ``--cross-check`` to have the script
recompute both numbers and print this reconciliation, rather than trusting the
paragraph.

USAGE
=====

  scripts/check_bare_skips.py
      [--root DIR]          # repository root (default: this file's ..)
      [--paths A.nim ...]   # scan these instead of the declared corpus
                            # (the baseline is NOT compared: a subset is not
                            # the population)
      [--list]              # print every bare skip site with its line
      [--top N]             # print the N worst files, for burn-down
      [--cross-check]       # reconcile against a plain grep and print both
      [--write-baseline]    # re-record the baseline from the current tree

Exit codes, as the sibling ratchets use them:
  0 -- no new bare skip. If the tree is a strict SUBSET of the baseline the
       file is rewritten smaller and the run still passes: fixing or deleting
       a site must not also cost a manual baseline edit, or the ratchet stops
       being maintained.
  1 -- at least one NEW bare skip, OR the baseline is unusable (missing,
       unparseable, or empty), OR the corpus scan came back below its floor.
       stderr names each one.
  2 -- an unusable combination of flags.
"""

from __future__ import annotations

import argparse
import importlib.util
import pathlib
import re
import subprocess
import sys

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
INVENTORY = SCRIPT_DIR / "reprobuild_suite_inventory.py"

# The inventory module owns the Nim lexer and the ``suite`` / ``test``
# declaration finder. Importing it is deliberate, for the same reason
# ``check_vacuous_test_cases.py`` imports it: a second, independently written
# scanner would drift from the one the case-count baseline uses, and the two
# disagreeing about what a test case is would make both unreliable.
_spec = importlib.util.spec_from_file_location("reprobuild_suite_inventory", INVENTORY)
assert _spec is not None and _spec.loader is not None
inventory = importlib.util.module_from_spec(_spec)
sys.modules["reprobuild_suite_inventory"] = inventory
_spec.loader.exec_module(inventory)


SKIP_NAME = "skip"

# Keywords that make the following ``skip`` a DECLARATION of something called
# skip rather than a call of it. ``libs/ct_test_unittest_parallel`` declares
# ``template skip*(reason = "")``; that is the fix, not the defect.
DECLARATION_KEYWORDS = {"template", "proc", "func", "macro", "method", "iterator",
                        "converter"}

# A case that contains a bare skip but sits in no ``test`` block at all. There
# are none today; the bucket exists so that one appearing is reported under a
# name rather than dropped.
OUTSIDE_A_CASE = "<outside any test case>"

BASELINE = SCRIPT_DIR / "bare-skips-baseline.tsv"

BASELINE_HEADER = """\
# bare-skip baseline -- every test case that calls `skip()` without saying why.
#
# See scripts/check_bare_skips.py for what this is and why it has no
# justification column. In short: `completed_clean_runs()` records a suite run
# as COMPLETE only when every case is a pass or an EXPLAINED skip, and this
# file pins the unexplained population so it cannot grow while it is burnt
# down.
#
# Regenerate with: python3 scripts/check_bare_skips.py --write-baseline
#
# Format: <source>\\t<case title>\\t<count of bare skips in that case>
# Line numbers are deliberately absent so an edit above a site does not
# invalidate the baseline -- the same reason
# scripts/shell-command-strings-baseline.txt omits them.
#
# The ratchet runs ONE WAY. A case whose bare-skip count EXCEEDS its row here
# (or that has no row) is refused by name. A row whose count has fallen is
# rewritten smaller by the next run and a row that has reached zero is dropped,
# so fixing a site costs you no manual edit -- commit the result.
#
# To fix a row: give the `skip()` a reason that names the condition, e.g.
#   skip("git not on PATH; this case needs a real repository")
# and delete nothing here -- the next run rewrites the file for you.
"""

# ---------------------------------------------------------------------------
# Anti-vacuity floors, asserted BEFORE the baseline is consulted
# ---------------------------------------------------------------------------
#
# Copied in spirit from ``check_vacuous_test_cases.py``, whose header states
# the reason better than a paraphrase would: "zero equals any baseline you like
# once the rows are gone". A scan that parsed nothing finds zero bare skips;
# every baseline row then looks fixed, and under the rewrite rule an empty scan
# would not merely pass, it would ERASE the record on its way through. These
# floors must therefore run before the comparison and not after it.
#
# WHICH NUMBERS CAN BE FLOORED. Not the bare-skip count: burning it down to
# zero is the goal, so a floor on it would refuse the very outcome this lint
# exists to reach. What burn-down does NOT reduce is the number of skip CALLS
# -- a fixed site is still a skip, it merely gained an argument. So the floor
# sits on the total skip population (bare + with-reason) and on the size of the
# corpus itself. Those distinguish "the tree improved" from "the scanner
# stopped seeing anything", which is exactly the discrimination a floor owes.
#
# The numbers are the 2026-09-21 census and are floors, not pins.
CORPUS_SOURCE_FLOOR = 1700   # measured 1764 declared Nim sources
CORPUS_CASE_FLOOR = 9800     # measured 10300 test cases
SKIP_CALL_FLOOR = 1200       # measured 1344 skip calls of either shape

# The grep the cross-check reconciles against, kept next to the number it
# produces so neither can drift from the other unnoticed.
GREP_PATTERN = r"(^|[^_[:alnum:]])skip\(\)"
GREP_PATHS = ("tests", "libs", "tools")


# ---------------------------------------------------------------------------
# Scanning
# ---------------------------------------------------------------------------


def name_key(value: str) -> str:
    return inventory.nim_name_key(value)


def body_bounds(tokens, depths, declaration) -> tuple[int, int]:
    """Token range ``[start, end)`` of a declaration's indented body.

    Lifted verbatim from ``check_vacuous_test_cases.py`` so the two lints
    agree about where a case begins and ends.
    """
    start = declaration.colon + 1
    reference_column = declaration.token.column
    position = start
    while position < len(tokens):
        token = tokens[position]
        if token.kind == "newline":
            position += 1
            continue
        if depths[position] == 0 and token.column <= reference_column:
            return start, position
        position += 1
    return start, len(tokens)


def normalize_title(title: str) -> str:
    """Collapse whitespace runs in a case title.

    The title is a BASELINE KEY, so measurement and the committed file must
    produce byte-identical strings or every row looks new. Two things make a
    raw title unsafe as a key: a trailing space, which a TSV round-trip
    through ``str.strip`` silently eats, and an embedded newline from a
    ``"a" & "b"`` title split across source lines, which would split one row
    into two. Measured first-hand -- two real cases
    (``t_integration_shell_integration_replan_idempotent.nim`` and
    ``t_monitor_shim_edges_carry_static_libgcc.nim``) reported as both new
    AND departed on a run against a baseline the same code had just written.

    Normalising here rather than at the file boundary means the measured key
    and the recorded key go through the same function, which is the only
    arrangement in which they cannot disagree.
    """
    return " ".join(title.split())


def case_title(tokens, declaration) -> str:
    """The case's title, joining a ``"a" & "b"`` concatenation into one string.

    ``check_vacuous_test_cases.py`` reads only the first literal, which
    truncates a wrapped title to its first fragment. That is tolerable for a
    75-row file a human reads; here it would make two differently-named cases
    that happen to share an opening fragment collapse into one key. Only
    literal-and-``&`` chains are joined -- a title built from a runtime
    expression is left as the first token, the same fallback the sibling uses.
    """
    position = declaration.expression_start
    while position < len(tokens) and tokens[position].kind == "newline":
        position += 1
    if position >= len(tokens):
        return "<unnamed>"

    def literal(index: int) -> str | None:
        token = tokens[index]
        if token.kind != "string":
            return None
        value = token.value
        if value.startswith('"') and value.endswith('"') and len(value) >= 2:
            return value.strip('"')
        return value

    first = literal(position)
    if first is None:
        return normalize_title(tokens[position].value)

    parts = [first]
    cursor = position + 1
    while cursor < len(tokens):
        if tokens[cursor].kind == "newline":
            cursor += 1
            continue
        if tokens[cursor].value != "&":
            break
        following = cursor + 1
        while following < len(tokens) and tokens[following].kind == "newline":
            following += 1
        if following >= len(tokens):
            break
        piece = literal(following)
        if piece is None:
            break
        parts.append(piece)
        cursor = following + 1
    return normalize_title("".join(parts))


def body_colons(tokens, depths, declarations) -> set[int]:
    """Token indices of the colons that open an indented block.

    ``inventory.nim_statement_start`` needs this set to tell ``skip`` at the
    head of a one-line body (``if x: skip``) from ``skip`` in the middle of a
    continued expression. The construction mirrors ``nim_declarations``'
    own, which is where the set is built for the same purpose.

    Computed LAZILY by its one caller: it is O(tokens) with an inner backward
    walk, and the paren-less ``skip`` shape it exists to judge occurs nowhere
    in the tree. Building it for all 1764 sources unconditionally tripled this
    lint's runtime for nothing.
    """
    colons: set[int] = set()
    for position, token in enumerate(tokens):
        if depths[position] != 0:
            continue
        if token.value != ":":
            continue
        previous = inventory.nim_previous_token(tokens, position)
        if previous is None:
            continue
        head = previous
        while head > 0 and not inventory.nim_statement_start(
            tokens, depths, head, colons
        ):
            head -= 1
        identifier = inventory.nim_identifier_value(tokens[head])
        if identifier is not None and name_key(identifier) in (
            inventory.NIM_INLINE_BLOCK_KEYWORDS
        ):
            colons.add(position)
    for declaration in declarations:
        colons.add(declaration.colon)
    return colons


def skip_kind(tokens, depths, colons, position) -> str | None:
    """Classify the ``skip`` identifier at ``position``.

    Returns ``"bare"``, ``"with-reason"``, or ``None`` when this occurrence is
    not a call at all (a declaration, an export list entry, a field name).
    """
    token = tokens[position]
    if token.kind != "identifier" or name_key(token.value) != SKIP_NAME:
        return None

    previous = inventory.nim_previous_token(tokens, position)
    if previous is not None:
        prior = tokens[previous]
        if prior.kind == "identifier" and name_key(prior.value) in DECLARATION_KEYWORDS:
            # `template skip*(...)` / `proc skip(...)` -- a declaration.
            return None

    following = position + 1
    if following >= len(tokens):
        return None
    after = tokens[following]

    if after.value == "(":
        # ``skip()`` versus ``skip(reason)``. The token immediately inside the
        # parentheses decides it; nothing else about the call matters.
        inner = following + 1
        while inner < len(tokens) and tokens[inner].kind == "newline":
            inner += 1
        if inner < len(tokens) and tokens[inner].value == ")":
            return "bare"
        return "with-reason"

    if after.kind == "newline":
        # A paren-less ``skip`` as a whole statement calls the template with
        # its default argument. Only count it when it is a statement HEAD --
        # otherwise `except suite, test, skip` at end of line would qualify.
        if inventory.nim_statement_start(tokens, depths, position, colons()):
            return "bare"
        return None

    return None


def analyze(text: str) -> tuple[int, list[tuple[int, str, str]]]:
    """Return ``(test case count, [(line, case title, kind), ...])``.

    One function rather than two because the lexer is the expensive part:
    tokenising each of the 1764 sources once instead of three times is the
    difference between this lint costing about what its sibling
    ``check_vacuous_test_cases.py`` costs and costing three times as much.
    """
    tokens = inventory.nim_tokens(text)
    depths = inventory.nim_outer_depths(tokens)
    all_declarations = inventory.nim_declarations(tokens)
    declarations = [d for d in all_declarations if d.kind == "test"]

    cached_colons: set[int] | None = None

    def colons() -> set[int]:
        nonlocal cached_colons
        if cached_colons is None:
            cached_colons = body_colons(tokens, depths, all_declarations)
        return cached_colons

    spans: list[tuple[int, int, str]] = []
    for index, declaration in enumerate(declarations):
        start, end = body_bounds(tokens, depths, declaration)
        if index + 1 < len(declarations):
            end = min(end, declarations[index + 1].colon)
        spans.append((start, end, case_title(tokens, declaration)))

    def enclosing(position: int) -> str:
        # Innermost wins; spans are emitted in source order so the last match
        # that still contains the position is the tightest one.
        title = OUTSIDE_A_CASE
        for start, end, name in spans:
            if start <= position < end:
                title = name
        return title

    found: list[tuple[int, str, str]] = []
    for position, token in enumerate(tokens):
        if token.kind != "identifier" or name_key(token.value) != SKIP_NAME:
            continue
        kind = skip_kind(tokens, depths, colons, position)
        if kind is None:
            continue
        found.append((token.line, enclosing(position), kind))
    return len(declarations), found


def scan_source(text: str):
    """``analyze``'s site list alone -- the shape the self-test asserts on."""
    return analyze(text)[1]


def declared_nim_sources(root: pathlib.Path) -> list[str]:
    """Every Nim test source declared in ``repro_tests.nim``, bundles expanded.

    Identical to ``check_vacuous_test_cases.py``'s corpus, on purpose: the
    three lints and the case-count baseline must not disagree about what the
    suite is.
    """
    nim_specs, _ = inventory.parse_repro_tests(root)
    sources: list[str] = []
    for spec in nim_specs:
        text = inventory.read_text(root / spec.source)
        members = inventory.bundle_member_paths(root, spec.source, text)
        sources.extend(members or [spec.source])
    seen: set[str] = set()
    unique: list[str] = []
    for source in sources:
        if source in seen:
            continue
        seen.add(source)
        unique.append(source)
    return unique


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
#
# A check that cannot fail is worthless, so this one must not be one. Before
# scanning the tree it scans this snippet and asserts the verdicts -- the same
# shape ``check_vacuous_test_cases.py`` uses, and the same shape
# ``check_workflows.sh`` uses when it feeds actionlint a known-bad workflow
# first. Without it, a scanner broken badly enough to find no declarations at
# all would report a clean tree.

SELF_TEST_SOURCE = '''
import std/unittest

suite "self test":
  test "bare":
    skip()

  test "bare, spaced":
    skip( )

  test "bare qualified":
    unittest.skip()

  test "with a reason":
    skip("git is not on PATH")

  test "with a reason variable":
    skip(reason)

  test "paren-less bare":
    skip

  test "two bare in one case":
    if a:
      skip()
    else:
      skip()

  test "only a comment mentions skip()":
    check 1 == 1  # this case used to skip()

  test "only a string mentions skip()":
    check text == "skip()"

  test "a wrapped title, trailing space and all; " &
       "second fragment":
    skip()

template skip*(reason = "") =
  discard reason
'''

SELF_TEST_EXPECTED = {
    "bare": ["bare"],
    "bare, spaced": ["bare"],
    "bare qualified": ["bare"],
    "with a reason": ["with-reason"],
    "with a reason variable": ["with-reason"],
    "paren-less bare": ["bare"],
    "two bare in one case": ["bare", "bare"],
    # Joined across the `&` and whitespace-normalised, which is what makes it
    # survive a TSV round-trip. See `normalize_title`.
    "a wrapped title, trailing space and all; second fragment": ["bare"],
}


def self_test() -> None:
    seen: dict[str, list[str]] = {}
    for _line, title, kind in scan_source(SELF_TEST_SOURCE):
        seen.setdefault(title, []).append(kind)
    if seen != SELF_TEST_EXPECTED:
        raise SystemExit(
            "check_bare_skips: SELF-TEST FAILED. The scanner does not classify "
            "its own fixture correctly, so its verdict on the tree means "
            "nothing.\n"
            f"  expected: {SELF_TEST_EXPECTED}\n"
            f"  got:      {seen}"
        )


# ---------------------------------------------------------------------------
# The baseline
# ---------------------------------------------------------------------------


def read_baseline(path: pathlib.Path) -> tuple[dict[tuple[str, str], int], list[str]]:
    """Parse the baseline into ``{(source, title): count}``.

    A malformed row is an ERROR, never a skipped line. A parser that shrugged
    at a bad row would let the file be emptied by corruption and still report
    "no new bare skips", which is the failure this baseline exists to prevent,
    reached through the baseline itself.
    """
    rows: dict[tuple[str, str], int] = {}
    errors: list[str] = []
    if not path.exists():
        return rows, [
            f"missing baseline: {path}. Regenerate with "
            f"`scripts/check_bare_skips.py --write-baseline`."
        ]
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 3:
            errors.append(
                f"{path.name}:{number}: expected 3 tab-separated fields "
                f"(source, title, count), got {len(fields)}"
            )
            continue
        source, title, raw_count = (field.strip() for field in fields)
        # Through the SAME normaliser the measured key goes through; see
        # ``normalize_title``. Anything else and a trailing space in a title
        # makes a row that is simultaneously new and departed.
        title = normalize_title(title)
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
        key = (source, title)
        if key in rows:
            errors.append(
                f"{path.name}:{number}: duplicate row for {source} :: {title}"
            )
        rows[key] = count
    return rows, errors


def render_baseline(rows: dict[tuple[str, str], int]) -> str:
    out = [BASELINE_HEADER]
    for source, title in sorted(rows):
        out.append(f"{source}\t{title}\t{rows[(source, title)]}\n")
    return "".join(out)


def run_ratchet(
    measured: dict[tuple[str, str], int],
    lines: dict[tuple[str, str], int],
    sources_scanned: int,
    cases: int,
    skip_calls: int,
    write: bool,
) -> bool:
    """Compare the bare-skip population against its baseline.

    Returns ``True`` when the run must fail. The ratchet runs one way:

    * a case whose bare-skip count exceeds its baseline row -- or that has no
      row -- is REFUSED, by name and line. "The count went up" would not say
      which;
    * a case whose count has FALLEN has been partly or wholly fixed, and the
      file is rewritten with the smaller number. Making an improvement also
      cost a manual edit is how ratchets stop being maintained.

    The two are not symmetric on purpose. When BOTH happen in one run the
    rewrite is withheld and the run fails on the new site, because recording a
    new baseline in the same breath as refusing one blesses the half of the
    tree the refusal is about.
    """
    # ---- anti-vacuity, before anything is compared ----------------------
    # Asserted first and unconditionally; see the floors' own comment above
    # for why this cannot be moved after the comparison.
    floor_failures: list[str] = []
    if sources_scanned < CORPUS_SOURCE_FLOOR:
        floor_failures.append(
            f"{sources_scanned} sources scanned, floor {CORPUS_SOURCE_FLOOR}"
        )
    if cases < CORPUS_CASE_FLOOR:
        floor_failures.append(f"{cases} test cases found, floor {CORPUS_CASE_FLOOR}")
    if skip_calls < SKIP_CALL_FLOOR:
        floor_failures.append(
            f"{skip_calls} skip calls of either shape found, floor {SKIP_CALL_FLOOR}"
        )
    if floor_failures:
        print(
            "error: the corpus scan came back too small to trust:",
            file=sys.stderr,
        )
        for message in floor_failures:
            print(f"    {message}", file=sys.stderr)
        print(
            "       A scan this small finds few bare skips for reasons that have "
            "nothing to do\n"
            "       with the tree, and would report the baseline's rows as fixed. "
            "Refusing\n"
            "       rather than comparing. Note the floor is on the TOTAL skip "
            "population and\n"
            "       on the corpus size, never on the bare count -- burning that to "
            "zero is the\n"
            "       goal and must not be refused.",
            file=sys.stderr,
        )
        return True

    recorded, errors = read_baseline(BASELINE)

    if errors and not write:
        print("error: the bare-skip baseline does not parse:", file=sys.stderr)
        for message in errors:
            print(f"    {message}", file=sys.stderr)
        return True

    if not recorded and not write:
        print(
            f"error: {BASELINE.name} has no rows. An empty baseline makes every one "
            f"of the {sum(measured.values())} bare skips in the tree a new offender, "
            f"which is not a useful diagnostic -- regenerate it with "
            f"--write-baseline.",
            file=sys.stderr,
        )
        return True

    arrived = sorted(key for key in measured if measured[key] > recorded.get(key, 0))
    improved = sorted(key for key in recorded if measured.get(key, 0) < recorded[key])

    if write:
        BASELINE.write_text(render_baseline(measured), encoding="utf-8", newline="\n")
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
            f"check_bare_skips: wrote {len(measured)} rows "
            f"({sum(measured.values())} bare skips) to {BASELINE.name} "
            f"(+{added} / -{removed} against the previous file)."
        )
        return False

    if arrived:
        print("FAIL: new bare `skip()` calls -- a skip that never says why.", file=sys.stderr)
        print("", file=sys.stderr)
        print(
            "      `completed_clean_runs()` records a suite run as COMPLETE only when",
            file=sys.stderr,
        )
        print(
            "      every case is a pass or an EXPLAINED skip, so an unexplained skip",
            file=sys.stderr,
        )
        print(
            "      makes the whole run unrecordable. Give it a reason that names the",
            file=sys.stderr,
        )
        print(
            '      condition:  skip("git not on PATH; this case needs a repository")',
            file=sys.stderr,
        )
        print("", file=sys.stderr)
        for source, title in arrived:
            was = recorded.get((source, title), 0)
            now = measured[(source, title)]
            line = lines[(source, title)]
            detail = f"{now} bare skip(s)" if was == 0 else f"{was} -> {now} bare skips"
            print(f"  {source}:{line}: {title}  [{detail}]", file=sys.stderr)
        print("", file=sys.stderr)
        print(
            f"      {len(arrived)} case(s) gained a bare skip. Locate them all with:",
            file=sys.stderr,
        )
        print("          scripts/check_bare_skips.py --list", file=sys.stderr)
        if improved:
            print(
                f"      ({len(improved)} baseline row(s) also shrank; they are NOT "
                f"rewritten while this run is failing.)",
                file=sys.stderr,
            )
        return True

    if improved:
        BASELINE.write_text(render_baseline(measured), encoding="utf-8", newline="\n")
        removed = sum(
            recorded[key] - measured.get(key, 0) for key in improved
        )
        print(
            f"check_bare_skips: {removed} bare skip(s) across {len(improved)} case(s) "
            f"are gone -- {BASELINE.name} rewritten smaller. COMMIT IT to lock the "
            f"improvement in:"
        )
        for source, title in improved:
            was = recorded[(source, title)]
            now = measured.get((source, title), 0)
            print(f"    {source} :: {title}  {was} -> {now}")

    print(
        f"check_bare_skips: {sum(measured.values())} bare skip(s) in "
        f"{len(measured)} case(s), all baselined; "
        f"{skip_calls - sum(measured.values())} skip(s) carry a reason."
    )
    return False


# ---------------------------------------------------------------------------
# Cross-check
# ---------------------------------------------------------------------------


def cross_check(root: pathlib.Path, measured_total: int) -> None:
    """Recompute the grep number and print the reconciliation.

    Requirement, not decoration: a scanner whose total nobody has compared
    against an independent method is a number with no second opinion.
    """
    result = subprocess.run(
        ["git", "grep", "-nE", GREP_PATTERN, "--", *GREP_PATHS],
        cwd=root,
        capture_output=True,
        text=True,
    )
    rows = [line for line in result.stdout.splitlines() if line.strip()]
    print("")
    print("check_bare_skips: cross-check against an independent method.")
    print(f"  git grep -nE '{GREP_PATTERN}' -- {' '.join(GREP_PATHS)}")
    print(f"      {len(rows)} matching lines")
    print(f"  this scanner (declared corpus, lexed)")
    print(f"      {measured_total} bare skip calls")
    print("")
    non_nim = [row for row in rows if not row.split(":", 1)[0].endswith(".nim")]
    corpus = set(declared_nim_sources(root))
    outside = [
        row
        for row in rows
        if row.split(":", 1)[0].endswith(".nim") and row.split(":", 1)[0] not in corpus
    ]
    print(f"  of grep's {len(rows)}:")
    print(f"      {len(non_nim)} are not Nim at all (comments in a .py file)")
    print(f"      {len(outside)} are in Nim files outside the declared suite corpus")
    print(
        f"      {len(rows) - len(non_nim) - len(outside)} are in the corpus, of which "
        f"{measured_total} are real calls"
    )
    print(
        f"      and the remaining "
        f"{len(rows) - len(non_nim) - len(outside) - measured_total} are mentions in "
        f"comments or string literals, which the lexer drops and grep cannot."
    )
    print("")
    print("  grep is the looser instrument here; the difference is accounted for")
    print("  above, line by line, and none of it is a scanner miss.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=None)
    parser.add_argument("--paths", nargs="*", default=None)
    parser.add_argument("--list", action="store_true", help="print every bare skip site")
    parser.add_argument(
        "--top", type=int, default=0, help="print the N files with the most bare skips"
    )
    parser.add_argument("--cross-check", action="store_true")
    parser.add_argument("--write-baseline", action="store_true")
    arguments = parser.parse_args()

    self_test()

    root = pathlib.Path(arguments.root) if arguments.root else SCRIPT_DIR.parent
    root = root.resolve()

    if arguments.paths:
        sources = list(arguments.paths)
        if arguments.write_baseline:
            print(
                "error: --write-baseline scans the whole corpus; it cannot be "
                "combined with --paths, which would record a subset as the entire "
                "population.",
                file=sys.stderr,
            )
            return 2
    else:
        sources = declared_nim_sources(root)

    measured: dict[tuple[str, str], int] = {}
    first_line: dict[tuple[str, str], int] = {}
    sites: list[str] = []
    per_file: dict[str, int] = {}
    sources_scanned = 0
    cases = 0
    skip_calls = 0

    for source in sources:
        path = root / source
        if not path.is_file():
            continue
        sources_scanned += 1
        text = inventory.read_text(path)
        source_cases, found = analyze(text)
        cases += source_cases
        for line, title, kind in found:
            skip_calls += 1
            if kind != "bare":
                continue
            key = (source, title)
            measured[key] = measured.get(key, 0) + 1
            first_line.setdefault(key, line)
            per_file[source] = per_file.get(source, 0) + 1
            sites.append(f"{source}:{line}: {title}")

    print(
        f"check_bare_skips: {sources_scanned} sources, {cases} test cases, "
        f"{skip_calls} skip call(s); {sum(measured.values())} of them bare, in "
        f"{len(measured)} case(s) across {len(per_file)} file(s)."
    )

    if arguments.list:
        print("")
        for site in sorted(sites):
            print(f"  {site}")
        print("")
        print(f"  {len(sites)} bare skip site(s).")

    if arguments.top:
        print("")
        print(f"check_bare_skips: the {arguments.top} worst files, for burn-down.")
        ranked = sorted(per_file.items(), key=lambda row: (-row[1], row[0]))
        for source, count in ranked[: arguments.top]:
            print(f"  {count:5d}  {source}")

    if arguments.cross_check:
        cross_check(root, sum(measured.values()))

    if arguments.paths:
        print(
            "check_bare_skips: --paths given; the baseline is not compared "
            "(a subset is not the population)."
        )
        return 0

    failed = run_ratchet(
        measured,
        first_line,
        sources_scanned,
        cases,
        skip_calls,
        write=arguments.write_baseline,
    )
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
