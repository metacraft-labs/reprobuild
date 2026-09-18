#!/usr/bin/env python3
"""Refuse a test case whose only assertion is ``check true``.

WHY THIS EXISTS
===============

A skipped test is visible. It is printed as skipped, counted as skipped, and
this repository has an explicit zero-skip gate that refuses new ones. A test
whose body has been reduced to ``check true`` is worse in every respect: it
prints ``[OK]``, increments the pass count, and is indistinguishable in any
summary from a test that actually verified something. Running the suite can
never reveal it -- the suite is exactly what it defeats.

That is not hypothetical here. M9.R.6.1 retired the ``registeredBuildFlags``
runtime registry and replaced the assertions of 268 recipe test cases across
82 files with ``check true  # registry retired -- assertion gutted``, so the
tests would "stay registered" against an integer case-count pin. The pin has
since become a per-source TSV where a deleted case is an ordinary reviewable
diff, so nothing forces that trade any more. When those 268 assertions were
re-armed against the surface the flags had moved to, 46 of the 82 recipes
turned out to have drifted away from what their tests still claimed to pin --
drift that the green ``[OK]`` had been hiding for the whole interval.

WHAT COUNTS AS VACUOUS
======================

A case is vacuous when it contains at least one assertion and EVERY assertion
it contains is trivially true -- ``check true``, ``require true``,
``doAssert true``, ``assert true``. A case that also asserts something real is
fine: ``check true`` inside one arm of an ``if`` whose other arm checks
something is a legitimate shape and is not reported.

A case with NO assertion at all is a separate shape, and it is judged against
a committed BASELINE rather than refused outright. Most of that population is
not a defect: this repository has project-local assertion helpers
(``requireSurface``, ``expectReaderError``, and per-file ``expect*``
templates) whose names this scanner cannot know, so a case that asserts
through one of them reads as assertionless here. Refusing the shape outright
would fight a legitimate pattern; leaving it uncounted let it grow.

So ``scripts/assertionless-test-cases-baseline.tsv`` pins the set, one row per
case, each with a verdict and a written reason. A case that ARRIVES is refused
by name. A case that is repaired or deleted is dropped from the file by the
next run, so the ratchet only moves one way and improving the tree costs no
manual edit. ``--include-assertionless`` still lists the population and no
longer decides the run.

CHANGED 2026-09-19, and the reason is worth keeping. This paragraph used to end
"it is counted on every run so the number is visible, and it is deliberately
not a gate". The choice not to gate was right and is unchanged. What was wrong
is the inference that followed from it: a number printed on every run was
treated as a record, and it is not. The count went from 54 to 75 with nobody
able to name one of the 21, because no run had anything to compare against.
The three lints this one sits beside all carry a baseline for exactly this
reason; this one now does too.

KNOWN LIMIT: BRANCH-LOCAL FILLER
================================

This is a source scan, so it sees every arm of a ``when``/``if`` at once and
cannot know which one the host takes. A case shaped

    test "...":
      when not defined(windows):
        checkpoint "platform-skip: this gate is Windows-specific"
        check true
      else:
        <real assertions>

reads as non-vacuous here, because the ``else`` arm asserts. On a non-Windows
host it nevertheless runs nothing but ``check true``. 46 such arms across 24
files remain in the tree; every one carries a ``checkpoint`` or ``[VM-gated]`` /
``platform-skip`` line naming the reason, and every one belongs to a case that
DOES assert on its intended platform, which is why widening the rule to catch
them would fight a legitimate pattern rather than a defect. Making that
distinction requires per-platform runtime data the case-count baseline does not
carry; it is out of this lint's reach and is recorded here rather than papered
over.

USAGE
=====

  scripts/check_vacuous_test_cases.py
      [--root DIR]                # repository root (default: this file's ..)
      [--paths A.nim B.nim ...]   # scan these instead of the whole corpus
      [--include-assertionless]   # also list cases with no assertion
      [--list-platform-gates]     # name the gates, not just count them
      [--write-baseline]          # re-record the assertionless baseline,
                                  # keeping every surviving row's verdict

Exit codes:
  0 -- no vacuous case, and the assertionless population matches its baseline
       (or is a subset of it, in which case the baseline is rewritten).
  1 -- at least one vacuous case, OR a new assertionless case, OR the baseline
       does not parse, OR the corpus scan came back below its floor. stderr
       names each one.
  2 -- an unusable combination of flags.

Wired in three places, mirroring the suite case-count gate it sits beside:
  - ``just lint`` (which CI's lint job runs);
  - ``.github/workflows/ci.yml``, as an early named step so the annotation
    points here rather than at a lint log;
  - ``flake.nix``'s pre-commit ``pre-push`` hook set, because push is this
    repository's publication boundary and this check costs seconds.

Scope: every Nim test source declared in ``repro_tests.nim``, following
consolidation bundles into their members exactly as the suite inventory does,
so the lint sees the same corpus the case-count baseline does.
"""

from __future__ import annotations

import argparse
import importlib.util
import pathlib
import sys

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
INVENTORY = SCRIPT_DIR / "reprobuild_suite_inventory.py"

# The inventory module owns the Nim lexer and the ``suite`` / ``test``
# declaration finder this lint needs. Importing it is deliberate: a second,
# independently written scanner would drift from the one the case-count
# baseline uses, and the two disagreeing about what a test case is would make
# both unreliable.
_spec = importlib.util.spec_from_file_location(
    "reprobuild_suite_inventory", INVENTORY
)
assert _spec is not None and _spec.loader is not None
inventory = importlib.util.module_from_spec(_spec)
sys.modules["reprobuild_suite_inventory"] = inventory
_spec.loader.exec_module(inventory)


# Assertion heads whose argument this lint inspects. ``expect`` is absent on
# purpose: ``expect ValueError:`` asserts that the block raises, which is a
# real assertion no matter what the block contains.
TRIVIAL_ASSERTION_HEADS = {"check", "require", "doassert", "assert"}

# Heads that make a case non-vacuous by their mere presence.
SUBSTANTIVE_HEADS = {"expect", "fail", "skip"}

# Literals that make an assertion prove nothing.
TRIVIAL_ARGUMENTS = {"true", "1", "not false"}

# The repository's sanctioned platform gate. A case that emits this marker is
# declaring, in a machine-greppable form, that its coverage does not apply to
# the host -- see the header of
# tests/integration/t_integration_launch_plan_binding_strategies.nim. Such a
# case is NOT a gutted assertion, and this lint does not refuse it. It is
# counted and printed on every run instead, because the whole difference
# between a skip and a gutted assertion is that a skip is visible and counted.
# The exemption is deliberately narrow: only this exact literal prefix earns
# it, so bypassing the lint requires writing a marker a reviewer can see.
PLATFORM_GATE_MARKER = "[platform N/A]"

# ---------------------------------------------------------------------------
# The assertionless-case baseline
# ---------------------------------------------------------------------------
#
# ADDED 2026-09-19. Until now the assertionless population was COUNTED and not
# gated, and the header above said so as a deliberate choice: this scanner
# cannot know the repository's project-local assertion helpers, so a large part
# of that count is not a defect and refusing it outright would fight a
# legitimate pattern.
#
# What that reasoning missed is that "not a gate" and "not recorded" are
# different things. The three lints this one sits beside --
# ``check_ambient_execution.sh``, ``check_shell_command_strings.sh`` and
# ``check_test_body_helper_compilation.py`` -- each carry a committed baseline,
# so a population they cannot judge outright can still only SHRINK. This one
# carried none, and the count grew from 54 to 75 with nobody able to say which
# 21 arrived or when. A number printed on every run is not a record; the only
# thing that makes it one is a file to diff it against.
#
# So: the set is pinned, with a written verdict per row, and the ratchet runs
# one way. A case that arrives is refused BY NAME. A case that is repaired or
# deleted is removed from the baseline automatically, because the improvement
# should cost the person who made it nothing.
#
# KEYED BY (source, case title), NOT BY LINE NUMBER. Its sibling
# ``shell-command-strings-baseline.txt`` learned this first and says so in its
# own header: a line number is invalidated by any edit ABOVE the site, which
# makes the baseline churn for reasons that have nothing to do with the
# population it pins. A case title is stable under edits elsewhere in the file
# and is what a reviewer reads anyway.
ASSERTIONLESS_BASELINE = SCRIPT_DIR / "assertionless-test-cases-baseline.tsv"

# Verdict vocabulary. Each says WHY a case with no recognised assertion is on
# the list, and the two that mean "this is fine" have to name the mechanism
# that makes it fine -- a verdict without a reason is a rubber stamp.
ASSERTIONLESS_VERDICTS = {
    "local-helper": (
        "asserts through a project-local helper whose name this scanner "
        "cannot know; the justification names the helper"
    ),
    "asserts-in-callee": (
        "the assertions live in a proc/template this case calls; the "
        "justification names the callee"
    ),
    "platform-gate": (
        "a deliberate no-op on this platform, asserting nothing here by design"
    ),
    "smoke-only": (
        "the property is 'it did not raise'; the justification says whether "
        "raising is actually possible"
    ),
    "genuinely-vacuous": (
        "runs code and asserts nothing; a defect, kept only until it is "
        "repaired or deleted"
    ),
}

BASELINE_HEADER = """\
# assertionless test cases -- the population `check_vacuous_test_cases.py`
# finds with no assertion head it recognises.
#
# Regenerate with: python3 scripts/check_vacuous_test_cases.py --write-baseline
# Then WRITE THE VERDICT for each new entry: it is a defect until argued
# otherwise, and `genuinely-vacuous` is the verdict for "I have not looked".
#
# Format: <source>\\t<case title>\\t<verdict>\\t<justification>
# Line numbers are deliberately absent so an edit above a case does not
# invalidate the baseline -- the same reason
# scripts/shell-command-strings-baseline.txt omits them.
#
# The ratchet runs ONE WAY. A case that appears here and is not in the file is
# refused by name. A row whose case has been repaired or deleted is dropped
# from this file automatically by the next run, so improving the tree does not
# also cost you a manual edit -- commit the result.
#
# Verdicts:
%s#
# KNOWN BLIND SPOT, inherited and not fixed here: this lint counts cases with
# NO assertion, so it cannot see a case whose assertions all sit inside a
# runtime `if` that the host never takes. That is a different scan and is
# recorded in Distribution-And-Packaging.milestones.org rather than papered
# over here.
"""

# Anti-vacuity floors for the corpus itself, asserted BEFORE the baseline is
# compared against anything. A scan that parsed nothing finds zero
# assertionless cases, and zero equals any baseline you like once the rows
# have also been dropped as "repaired" -- so an empty scan would not merely
# pass, it would ERASE the record on its way through. The numbers are the
# 2026-09-18 census (9878 cases in 1716 sources) and are a floor, not a pin:
# the suite grows, and a floor that tracked the exact count would be a second
# baseline to maintain.
CORPUS_CASE_FLOOR = 9878
CORPUS_SOURCE_FLOOR = 1716


def baseline_key(source: str, title: str) -> tuple[str, str]:
    """The identity of an assertionless case: where it lives and what it is called."""
    return (source, title)


def read_assertionless_baseline(
    path: pathlib.Path,
) -> tuple[dict[tuple[str, str], tuple[str, str]], list[str]]:
    """Parse the baseline into ``{(source, title): (verdict, justification)}``.

    A malformed row is an ERROR, never a skipped line. A parser that shrugged
    at a bad row would let the file be emptied by corruption and still report
    "no new assertionless cases", which is the failure this baseline exists to
    prevent, reached through the baseline itself.
    """
    rows: dict[tuple[str, str], tuple[str, str]] = {}
    errors: list[str] = []
    if not path.exists():
        return rows, [
            f"missing baseline: {path}. Regenerate with "
            f"`scripts/check_vacuous_test_cases.py --write-baseline`, then write "
            f"a verdict for every row."
        ]
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 4:
            errors.append(
                f"{path.name}:{number}: expected 4 tab-separated fields "
                f"(source, title, verdict, justification), got {len(fields)}"
            )
            continue
        source, title, verdict, justification = (field.strip() for field in fields)
        if verdict not in ASSERTIONLESS_VERDICTS:
            errors.append(
                f"{path.name}:{number}: unknown verdict `{verdict}`; expected one of "
                f"{', '.join(sorted(ASSERTIONLESS_VERDICTS))}"
            )
        if not justification:
            errors.append(
                f"{path.name}:{number}: {source} :: {title} has no justification. "
                f"A verdict without a reason is a rubber stamp; say which helper "
                f"asserts, or say what is missing."
            )
        key = baseline_key(source, title)
        if key in rows:
            errors.append(
                f"{path.name}:{number}: duplicate row for {source} :: {title}. "
                f"Two cases in one file with the same title cannot be told apart "
                f"by this baseline; rename one."
            )
        rows[key] = (verdict, justification)
    return rows, errors


def render_assertionless_baseline(
    rows: dict[tuple[str, str], tuple[str, str]],
) -> str:
    verdict_lines = "".join(
        f"#   {name:<18} {description}\n"
        for name, description in sorted(ASSERTIONLESS_VERDICTS.items())
    )
    out = [BASELINE_HEADER % verdict_lines]
    for (source, title) in sorted(rows):
        verdict, justification = rows[(source, title)]
        out.append(f"{source}\t{title}\t{verdict}\t{justification}\n")
    return "".join(out)


def name_key(value: str) -> str:
    return inventory.nim_name_key(value)


def body_bounds(tokens, depths, declaration) -> tuple[int, int]:
    """Token range ``[start, end)`` of a declaration's indented body."""
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


def statement_arguments(tokens, depths, position, end) -> list[str]:
    """Token values of the statement beginning just after ``position``.

    Stops at the newline that closes the statement at bracket depth zero, so
    a multi-line ``check`` expression is read whole rather than truncated
    into a trivial-looking prefix.
    """
    values: list[str] = []
    cursor = position + 1
    base_depth = depths[position]
    while cursor < end:
        token = tokens[cursor]
        if token.kind == "newline":
            if depths[cursor] <= base_depth:
                break
            cursor += 1
            continue
        values.append(token.value)
        cursor += 1
    return values


def scan_case(tokens, depths, declaration, end) -> tuple[int, int, bool]:
    """Return ``(assertions, trivial_assertions, platform_gated)``."""
    start, _ = body_bounds(tokens, depths, declaration)
    assertions = 0
    trivial = 0
    platform_gated = False
    position = start
    while position < end:
        token = tokens[position]
        if token.kind == "string" and PLATFORM_GATE_MARKER in token.value:
            platform_gated = True
            position += 1
            continue
        if token.kind != "identifier":
            position += 1
            continue
        key = name_key(token.value)
        if key in SUBSTANTIVE_HEADS:
            assertions += 1
            position += 1
            continue
        if key not in TRIVIAL_ASSERTION_HEADS:
            position += 1
            continue
        # ``check:`` opens a BLOCK of assertions rather than taking a single
        # argument. Count it as one substantive assertion: its contents are
        # bare expressions, not assertion heads, so leaving it uncounted
        # would make a case that asserts only through the block form read as
        # having no assertion at all.
        following = position + 1
        if following < end and tokens[following].value == ":":
            assertions += 1
            position += 1
            continue
        arguments = statement_arguments(tokens, depths, position, end)
        assertions += 1
        if " ".join(arguments).strip().lower() in TRIVIAL_ARGUMENTS:
            trivial += 1
        position += 1
    return assertions, trivial, platform_gated


def case_title(tokens, declaration) -> str:
    position = declaration.expression_start
    while position < len(tokens) and tokens[position].kind == "newline":
        position += 1
    if position >= len(tokens):
        return "<unnamed>"
    value = tokens[position].value
    if value.startswith('"') and value.endswith('"') and len(value) >= 2:
        return value.strip('"')
    return value


def scan_source(text: str):
    """Yield ``(line, title, assertions, trivial, platform_gated)`` per case."""
    tokens = inventory.nim_tokens(text)
    depths = inventory.nim_outer_depths(tokens)
    declarations = [
        declaration
        for declaration in inventory.nim_declarations(tokens)
        if declaration.kind == "test"
    ]
    for index, declaration in enumerate(declarations):
        _, end = body_bounds(tokens, depths, declaration)
        # A following declaration bounds this one even when the lexer's
        # column reading of a wrapped head would not.
        if index + 1 < len(declarations):
            end = min(end, declarations[index + 1].colon)
        assertions, trivial, gated = scan_case(tokens, depths, declaration, end)
        yield (declaration.token.line, case_title(tokens, declaration),
               assertions, trivial, gated)


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
#
# A check that cannot fail is the exact thing this script exists to refuse, so
# it must not be one itself. Before scanning the tree it scans this snippet and
# asserts the verdicts, which is the same shape `check_workflows.sh` uses when
# it feeds actionlint a known-bad workflow first. Without it, a scanner broken
# so badly that it finds no declarations at all would report a clean tree.

SELF_TEST_SOURCE = '''
import std/unittest

suite "self test":
  test "vacuous":
    check true

  test "vacuous require":
    require true

  test "vacuous with a comment":
    check true  # registry retired

  test "substantive":
    check 1 + 1 == 2

  test "mixed arms are not vacuous":
    if defined(windows):
      check true
    else:
      check 2 * 2 == 4

  test "platform gate":
    echo "[platform N/A] self-test: not applicable here"

  test "assertionless":
    discard 1
'''

SELF_TEST_EXPECTED = {
    "vacuous": "vacuous",
    "vacuous require": "vacuous",
    "vacuous with a comment": "vacuous",
    "substantive": "ok",
    "mixed arms are not vacuous": "ok",
    "platform gate": "gate",
    "assertionless": "assertionless",
}


def classify(assertions: int, trivial: int, gated: bool) -> str:
    if gated and assertions <= trivial:
        return "gate"
    if assertions and assertions == trivial:
        return "vacuous"
    if assertions == 0:
        return "assertionless"
    return "ok"


def self_test() -> None:
    seen: dict[str, str] = {}
    for _line, title, assertions, trivial, gated in scan_source(
        SELF_TEST_SOURCE
    ):
        seen[title] = classify(assertions, trivial, gated)
    if seen != SELF_TEST_EXPECTED:
        raise SystemExit(
            "check_vacuous_test_cases: SELF-TEST FAILED. The scanner does not "
            "classify its own fixture correctly, so its verdict on the tree "
            "means nothing.\n"
            f"  expected: {SELF_TEST_EXPECTED}\n"
            f"  got:      {seen}"
        )


def declared_nim_sources(root: pathlib.Path) -> list[str]:
    nim_specs, _ = inventory.parse_repro_tests(root)
    sources: list[str] = []
    for spec in nim_specs:
        text = inventory.read_text(root / spec.source)
        members = inventory.bundle_member_paths(root, spec.source, text)
        sources.extend(members or [spec.source])
    # A bundle member is also declared on its own in some configurations;
    # scanning it twice would double-report it.
    seen: set[str] = set()
    unique: list[str] = []
    for source in sources:
        if source in seen:
            continue
        seen.add(source)
        unique.append(source)
    return unique


def run_assertionless_ratchet(
    measured: dict[tuple[str, str], int],
    collisions: list[str],
    cases: int,
    scanned: int,
    write: bool,
) -> bool:
    """Compare the assertionless population against its baseline.

    Returns ``True`` when the run must fail. The ratchet runs one way:

    * a case the tree has and the baseline does not is REFUSED, by name --
      "the count went up" would not say which, and this population grew by 21
      with nobody able to name one of them;
    * a baseline row whose case no longer appears has been repaired or
      deleted, and the file is rewritten without it. Making an improvement
      also cost a manual edit is how ratchets stop being maintained.

    The two are not symmetric on purpose. When BOTH happen in one run the
    rewrite is withheld and the run fails on the new case, because recording a
    new baseline in the same breath as refusing one blesses the half of the
    tree the refusal is about (Verification-Harness-Traps §32: run the needle
    scan before re-recording the control digests, never after).
    """
    # ---- anti-vacuity, before anything is compared ----------------------
    # Asserted first and unconditionally. A scan that parsed nothing finds
    # zero assertionless cases; every baseline row then looks "repaired", and
    # under the rewrite rule below an empty scan would not merely pass, it
    # would ERASE the record on its way through. These floors are what stops
    # that, so they must run before the comparison and not after it.
    if cases < CORPUS_CASE_FLOOR or scanned < CORPUS_SOURCE_FLOOR:
        print(
            f"error: the corpus scan came back too small to trust: {cases} cases "
            f"in {scanned} sources, against a floor of {CORPUS_CASE_FLOOR} cases "
            f"in {CORPUS_SOURCE_FLOOR} sources (the 2026-09-18 census).\n"
            f"       A scan this small finds few assertionless cases for reasons "
            f"that have nothing to do with the tree, and would report the "
            f"baseline's rows as repaired. Refusing rather than comparing.",
            file=sys.stderr,
        )
        return True

    # ---- the population must be countable before it can be pinned -------
    # Two assertionless cases in one file under one title collapse to a single
    # baseline row, so the census would report 75 while the file held 74 — the
    # second one pinned by nothing. Refuse rather than pick one, and say which
    # two, because the remedy is a rename and it is cheap.
    if collisions:
        print(
            "error: two assertionless test cases share a file and a title, so the "
            "baseline cannot tell them apart (nor can a test report):",
            file=sys.stderr,
        )
        for message in collisions:
            print(f"    {message}", file=sys.stderr)
        print(
            "       Rename one. A title is a case's name in every report this "
            "suite prints; two cases answering to it is a defect on its own.",
            file=sys.stderr,
        )
        return True

    recorded, errors = read_assertionless_baseline(ASSERTIONLESS_BASELINE)

    if errors and not write:
        print("error: the assertionless baseline does not parse:", file=sys.stderr)
        for message in errors:
            print(f"    {message}", file=sys.stderr)
        return True

    if not recorded and not write:
        print(
            f"error: {ASSERTIONLESS_BASELINE.name} has no rows. An empty baseline "
            f"makes every one of the {len(measured)} assertionless cases in the "
            f"tree a new offender, which is not a useful diagnostic — regenerate "
            f"it with --write-baseline and write the verdicts.",
            file=sys.stderr,
        )
        return True

    arrived = sorted(set(measured) - set(recorded))
    departed = sorted(set(recorded) - set(measured))

    if write:
        # Keep the verdict and justification of every surviving row; a new row
        # arrives with the verdict that means "nobody has looked at this yet".
        rows: dict[tuple[str, str], tuple[str, str]] = {}
        for key in measured:
            if key in recorded:
                rows[key] = recorded[key]
            else:
                rows[key] = (
                    "genuinely-vacuous",
                    "UNREVIEWED -- recorded by --write-baseline; read the case and "
                    "replace this verdict",
                )
        ASSERTIONLESS_BASELINE.write_text(
            render_assertionless_baseline(rows), encoding="utf-8", newline="\n"
        )
        unreviewed = [key for key in rows if key not in recorded]
        print(
            f"check_vacuous_test_cases: wrote {len(rows)} rows to "
            f"{ASSERTIONLESS_BASELINE.name} "
            f"({len(unreviewed)} new, {len(departed)} dropped)."
        )
        for source, title in sorted(unreviewed):
            print(f"    NEEDS A VERDICT: {source} :: {title}")
        return False

    if arrived:
        print(
            "FAIL: test cases with no assertion this scanner can see, and no row",
            file=sys.stderr,
        )
        print(
            "      in the baseline. Each one is a defect until argued otherwise:",
            file=sys.stderr,
        )
        print(
            "      assert the property, or — if the case asserts through a local",
            file=sys.stderr,
        )
        print(
            "      helper — add a row naming that helper with",
            file=sys.stderr,
        )
        print(
            "      `scripts/check_vacuous_test_cases.py --write-baseline`.",
            file=sys.stderr,
        )
        print("", file=sys.stderr)
        for source, title in arrived:
            print(f"  {source}:{measured[(source, title)]}: {title}", file=sys.stderr)
        print("", file=sys.stderr)
        print(f"      {len(arrived)} new assertionless case(s).", file=sys.stderr)
        if departed:
            print(
                f"      ({len(departed)} baseline row(s) also no longer match; they "
                f"are NOT dropped while this run is failing.)",
                file=sys.stderr,
            )
        return True

    if departed:
        rows = {key: recorded[key] for key in measured}
        ASSERTIONLESS_BASELINE.write_text(
            render_assertionless_baseline(rows), encoding="utf-8", newline="\n"
        )
        print(
            f"check_vacuous_test_cases: {len(departed)} baseline row(s) no longer "
            f"match a case with no assertion — dropped from "
            f"{ASSERTIONLESS_BASELINE.name}. COMMIT IT to lock the improvement in:"
        )
        for source, title in departed:
            print(f"    {source} :: {title}")

    outstanding = sum(
        1 for key in measured if recorded.get(key, ("", ""))[0] == "genuinely-vacuous"
    )
    print(
        f"check_vacuous_test_cases: {len(measured)} assertionless case(s), all "
        f"baselined; {outstanding} still carry the `genuinely-vacuous` verdict."
    )
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=None)
    parser.add_argument(
        "--include-assertionless",
        action="store_true",
        help="also report cases that contain no assertion at all",
    )
    parser.add_argument(
        "--list-platform-gates",
        action="store_true",
        help="list the declared `[platform N/A]` gates as well as counting them",
    )
    parser.add_argument(
        "--paths",
        nargs="*",
        default=None,
        help="scan these sources instead of every source in repro_tests.nim",
    )
    parser.add_argument(
        "--write-baseline",
        action="store_true",
        help=(
            "rewrite the assertionless-case baseline from the current tree, "
            "keeping the verdict and justification of every row that survives"
        ),
    )
    arguments = parser.parse_args()

    self_test()

    root = pathlib.Path(arguments.root) if arguments.root else SCRIPT_DIR.parent
    root = root.resolve()

    if arguments.paths:
        sources = list(arguments.paths)
    else:
        sources = declared_nim_sources(root)

    vacuous: list[str] = []
    assertionless: list[str] = []
    # Keyed the way the baseline is keyed, so the two can be compared without
    # a second notion of what identifies a case.
    assertionless_keys: dict[tuple[str, str], int] = {}
    assertionless_collisions: list[str] = []
    platform_gates: list[str] = []
    scanned = 0
    cases = 0
    for source in sources:
        path = root / source
        if not path.is_file():
            continue
        scanned += 1
        for line, title, assertions, trivial, gated in scan_source(
            inventory.read_text(path)
        ):
            cases += 1
            substantive = assertions > trivial
            if gated and not substantive:
                platform_gates.append(f"{source}:{line}: {title}")
                continue
            if assertions and assertions == trivial:
                vacuous.append(f"{source}:{line}: {title}")
            elif assertions == 0:
                assertionless.append(f"{source}:{line}: {title}")
                key = baseline_key(source, title)
                if key in assertionless_keys:
                    # Two cases in one file under one title. The baseline
                    # cannot tell them apart, and neither can a test report.
                    # Collapsing them here would quietly pin one and leave the
                    # other unpinned — the count would say 75 and the file
                    # would hold 74, which is how a population stops being a
                    # population. Recorded, and refused below.
                    assertionless_collisions.append(
                        f"{source}: {title!r} at lines "
                        f"{assertionless_keys[key]} and {line}"
                    )
                assertionless_keys.setdefault(key, line)

    reported = list(vacuous)

    # The census prints on every run, pass or fail. A platform gate is
    # legitimate but it is still coverage that did not run, and the point of
    # this whole lint is that unrun coverage must be countable.
    census = (
        f"check_vacuous_test_cases: {cases} cases in {scanned} sources; "
        f"{len(platform_gates)} declared `{PLATFORM_GATE_MARKER}` gates; "
        f"{len(assertionless)} cases with no assertion at all."
    )

    print(census)

    # ---- the assertionless ratchet -------------------------------------
    # Skipped entirely under --paths, which scans a subset by construction:
    # comparing a subset against a whole-tree baseline would report every case
    # outside the subset as repaired and silently delete it from the file.
    baseline_failed = False
    if arguments.paths:
        if arguments.write_baseline:
            print(
                "error: --write-baseline scans the whole corpus; it cannot be "
                "combined with --paths, which would record a subset as the "
                "entire population.",
                file=sys.stderr,
            )
            return 2
        print(
            "check_vacuous_test_cases: --paths given; the assertionless "
            "baseline is not compared (a subset is not the population)."
        )
    else:
        baseline_failed = run_assertionless_ratchet(
            assertionless_keys,
            assertionless_collisions,
            cases,
            scanned,
            write=arguments.write_baseline,
        )
        if arguments.write_baseline:
            return 1 if baseline_failed else 0

    if arguments.include_assertionless:
        print("")
        print("check_vacuous_test_cases: the assertionless population, in full.")
        print("  Cases with no assertion head this scanner recognises. The")
        print(f"  committed verdict for each is in {ASSERTIONLESS_BASELINE.name};")
        print("  listing them does not decide the run, the ratchet above does.")
        print("")
        for entry in sorted(assertionless):
            print(f"  {entry}")
        print("")
        print(f"  {len(assertionless)} case(s).")

    if not reported:
        print(
            "check_vacuous_test_cases: no case asserts only `check true`."
        )
        if arguments.list_platform_gates:
            for entry in sorted(platform_gates):
                print(f"  gate {entry}")
        return 1 if baseline_failed else 0

    print(
        "FAIL: test cases whose only assertion proves nothing.",
        file=sys.stderr,
    )
    print(
        "      A `check true` body reports [OK] and increments the pass",
        file=sys.stderr,
    )
    print(
        "      count, so no amount of running the suite can reveal it.",
        file=sys.stderr,
    )
    print(
        "      Assert the property against the surface that now carries it,",
        file=sys.stderr,
    )
    print(
        "      or delete the case -- a deleted case is honest about coverage.",
        file=sys.stderr,
    )
    print("", file=sys.stderr)
    for entry in sorted(reported):
        print(f"  {entry}", file=sys.stderr)
    print("", file=sys.stderr)
    print(f"      {len(reported)} case(s).", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
