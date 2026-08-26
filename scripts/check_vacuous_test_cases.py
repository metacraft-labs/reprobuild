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

A case with NO assertion at all is a separate shape and is NOT a failure by
default. ``--include-assertionless`` lists them, with the caveat that most of
what it lists is not a defect: this repository has project-local assertion
helpers (``requireSurface``, ``expectReaderError``, and per-file ``expect*``
templates) whose names this scanner cannot know, so a case that asserts
through one of them reads as assertionless here. Treat that list as a
starting point for review, never as a verdict. It is counted on every run so
the number is visible, and it is deliberately not a gate.

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
      [--include-assertionless]   # also report cases with no assertion
      [--list-platform-gates]     # name the gates, not just count them

Exit codes:
  0 -- no vacuous case.
  1 -- at least one vacuous case; stderr names each ``file:line`` and the
       case title.

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

    reported = list(vacuous)
    if arguments.include_assertionless:
        reported.extend(assertionless)

    # The census prints on every run, pass or fail. A platform gate is
    # legitimate but it is still coverage that did not run, and the point of
    # this whole lint is that unrun coverage must be countable.
    census = (
        f"check_vacuous_test_cases: {cases} cases in {scanned} sources; "
        f"{len(platform_gates)} declared `{PLATFORM_GATE_MARKER}` gates; "
        f"{len(assertionless)} cases with no assertion at all."
    )

    if not reported:
        print(census)
        print(
            "check_vacuous_test_cases: no case asserts only `check true`."
        )
        if arguments.list_platform_gates:
            for entry in sorted(platform_gates):
                print(f"  gate {entry}")
        return 0

    print(census)

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
