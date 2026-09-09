#!/usr/bin/env python3
"""Refuse NEW tests that compile a helper program at execution time.

WHY
---
Graph-Owned-Test-Artifacts M3: a test that shells out to ``nim c`` / ``cc`` /
``cargo build`` in its own body is building an artifact the build graph does
not know about. The artifact has no declared inputs, so nothing invalidates it;
it is rebuilt on every run, so the suite pays for it every time; and two cases
that build the same output path race each other's linker. The fix is a
``repro.nim`` build edge plus a typed input on the test's execute edge.

WHAT THIS IS
------------
A RATCHET with a REVIEWED BASELINE, in the shape this repository already uses
for ``check_ambient_execution.sh``. Every source THIS DETECTOR SEES compiling
something today carries a row in ``DISPOSITIONS`` recording WHY. A source that
acquires such a flow without a row fails the check. A source whose row says the
compile was migrated into the graph, and which then reacquires one, also fails —
so a completed migration cannot silently regress.

THE SCOPE OF "EVERY", SAID PLAINLY
----------------------------------
The baseline is exactly the set ``inventory.compiler_invocations`` detects: a
static scan, ``COMPILER_PATTERNS`` plus a data-flow pass to an executor. It is
NOT "every runtime compile in the suite", and no green from this check may be
read that way. What the check guarantees is a RATCHET over the detected set —
that set cannot grow without review, and a migration in it cannot regress.

The distinction earns its space: until this was written, ``nim check`` matched
no pattern at all, a verb in a fragment beginning with a space
(``nimExe & " c --compileOnly ..."``) escaped the verb anchor, and a compiler
fragment on a continuation line of an open ``execCmdEx(`` was matched and then
discarded for want of an executor token on its own line. Ten declared test
sources spawned a real compiler through those three holes and appeared in
neither the detected set nor the baseline. A gate with a spelling that walks
through it is not a gate, so widening the patterns — and re-deriving the whole
list when they widen — is part of maintaining this check, not an exceptional
event. ``TheRatchetHasNoWalkableBypass`` pins the closed spellings.

THE COMPILE-VERB RULE KEYS ON NIM'S SWITCH VOCABULARY. DO NOT REPLACE IT WITH A
PUNCTUATION RULE.
------------------------------------------------------------------------------
Widening the verb pattern runs straight into a collision: ``repro`` has a
``check`` verb of its own, so ``reproBin & " check --mode=pre-push"`` has the
same shape as ``nimExe & " check --hints:off"``. Telling them apart by
SEPARATOR looks obvious and is wrong twice over.

  * It under-detects. Nim takes ``=`` as readily as ``:``
    (``codetracer-nim/compiler/commands.nim:140``,
    ``elif switch[i] in {':', '='}``), so a colon rule misses
    ``nim c --out=x`` — a real compile, undetected.
  * Widening it to accept ``=`` over-detects, and not marginally: 20 declared
    test sources in this tree spell ``repro check --mode=…`` (31 occurrences
    across 22 files; the two files that are not declared test sources — the
    CLI's own usage text and an imported fixture module — are not scanned by
    this check at all). Every one of them is the product; none is a compile.
    That rule would condemn the integration surface wholesale — the precise
    failure this check is built to avoid.

Punctuation cannot separate the two languages because they share it. The switch
NAMES can: ``--out``, ``--nimcache``, ``--compileOnly`` are nim's under either
separator; ``--mode``, ``--write-report``, ``--workspace-root`` are nim's under
neither. So ``NIM_SWITCH_NAMES`` in the inventory holds nim's vocabulary,
extracted from ``processSwitch``'s own ``case switch.normalize`` block rather
than recalled, and matched through a faithful copy of ``strutils.normalize``.
Both directions are pinned by tests, deliberately: four arms require a real
compile to be seen, one requires ``repro check --mode=pre-push`` not to be. A
rule satisfying only one direction is cheap and worthless.

Remaining known blind spots, stated rather than papered over: a compiler
reached through a helper defined in another module (only ``include``d files are
followed, one level); a command assembled across procedure boundaries rather
than through the tracked ``let``/``var`` chain; and any spelling absent from
``COMPILER_PATTERNS``.

THE HARD PART: NOT FLAGGING THE PRODUCT
---------------------------------------
Reprobuild's job is to run compilers. Most of this suite's integration tests
exist precisely to invoke ``repro`` and check that it built, cached, locked or
served something — M3 says in as many words to preserve them. A check that
fired on "a compiler ran" would flag the entire integration surface and be
turned off within a week.

Two separate mechanisms keep those tests out of the violation set, and neither
is a name-based exemption list:

 1. THE EXECUTED PROGRAM IS THE DISCRIMINATOR. A violation is a test whose own
    body spawns a COMPILER. A test that spawns ``build/bin/repro`` spawns the
    product; the product may then spawn a compiler, and that is the behaviour
    under test, not a defect in the test. ``repro`` is not a compiler token, so
    those invocations are structurally invisible here — nothing has to remember
    to exempt them. ``test_repro_invocation_integration_path`` pins this.

 2. CALLS INTO REPROBUILD'S OWN COMPILATION API are separated from spawns and
    classified ``product-api``, never a violation. ``compileProviderBinary``,
    ``liftInterfaceArtifact``, ``compileProfileToRbpi`` and friends ARE the
    product; a test calling one is testing reprobuild, not building a helper.
    The inventory already resolves these through an import allowlist tied to
    the authoritative implementation modules, so an unrelated module exporting
    the same spelling cannot mimic one.

EMBEDDED FIXTURES
-----------------
This repository writes Nim inside Nim: whole modules live in triple-quoted
strings, and a fixture can contain a compiler command of its own. Those bytes
are not code this test executes. ``mask_embedded_fixtures`` blanks comments and
TRIPLE-quoted strings before the scan, preserving offsets so reported line
numbers stay true.

Single-line strings are deliberately KEPT: the real invocations in this repo
are assembled from single-line fragments (``let cmd = "nim c --hints:off" &
...``), so blanking them would blind the check to every violation it exists to
catch. Measured at the time this was written: masking changes the detected set
by zero entries on the current tree — it is insurance against the next embedded
fixture, not a fix for a live false positive, and it is claimed as nothing more.
"""

from __future__ import annotations

import argparse
import importlib.util
import re
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
DISPOSITIONS = REPO_ROOT / "scripts" / "test-body-helper-compilation-dispositions.tsv"

# Verdicts a reviewed row may carry. Each one is a REASON the flow is not a
# migration target, except ``migrate-pending``, which is accepted debt, and
# ``graph-owned``, which asserts the migration is DONE and must not regress.
KEEP_VERDICTS = {
    "product-api": "the flow is a call into reprobuild's own compilation API",
    "compiler-is-subject": "the compiler's own behaviour is what the test asserts",
    "dynamic-source": "the compiled source text is generated at run time",
    "mutated-artifact": "the produced binary is destructively rewritten by the test",
    "optional-host-tool": "a host-installed packer/installer the test skips without",
}
MIGRATE_PENDING = "migrate-pending"
GRAPH_OWNED = "graph-owned"
VALID_VERDICTS = set(KEEP_VERDICTS) | {MIGRATE_PENDING, GRAPH_OWNED}


def load_inventory() -> Any:
    """Import the inventory module by path.

    By path rather than by name because ``scripts/`` is not a package and a
    plain ``import`` picks up whatever else is on ``sys.path``. Reusing the
    inventory's detector is the point: two implementations of "is this a
    compiler flow" would disagree, and the disagreement would surface as a
    baseline that is correct against one of them.
    """
    spec = importlib.util.spec_from_file_location(
        "reprobuild_suite_inventory",
        REPO_ROOT / "scripts" / "reprobuild_suite_inventory.py",
    )
    module = importlib.util.module_from_spec(spec)
    # Registered before execution: the module defines dataclasses, and
    # ``dataclasses`` resolves ``cls.__module__`` through ``sys.modules``.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def mask_embedded_fixtures(text: str) -> str:
    """Blank comments and triple-quoted strings, preserving offsets.

    Offsets are preserved (spaces for content, newlines kept) because the
    detector reports line numbers and reads multi-line assignment blocks by
    indentation; deleting the bytes would move every line after a fixture.
    """
    out: list[str] = []
    index, length = 0, len(text)
    while index < length:
        char = text[index]
        if text.startswith("#[", index):  # nestable block comment
            depth, cursor = 1, index + 2
            while cursor < length and depth:
                if text.startswith("#[", cursor):
                    depth += 1
                    cursor += 2
                elif text.startswith("]#", cursor):
                    depth -= 1
                    cursor += 2
                else:
                    cursor += 1
            out.append("".join(c if c == "\n" else " " for c in text[index:cursor]))
            index = cursor
            continue
        if char == "#":
            cursor = text.find("\n", index)
            cursor = length if cursor < 0 else cursor
            out.append(" " * (cursor - index))
            index = cursor
            continue
        if text.startswith('"""', index):
            cursor = text.find('"""', index + 3)
            cursor = length if cursor < 0 else cursor + 3
            out.append("".join(c if c == "\n" else " " for c in text[index:cursor]))
            index = cursor
            continue
        if char == '"':
            # Single-line string, KEPT verbatim: this is where the repository
            # writes its real compiler command fragments.
            cursor = index + 1
            while cursor < length and text[cursor] != "\n":
                if text[cursor] == "\\":
                    cursor += 2
                    continue
                if text[cursor] == '"':
                    cursor += 1
                    break
                cursor += 1
            out.append(text[index:cursor])
            index = cursor
            continue
        out.append(char)
        index += 1
    return "".join(out)


INCLUDE_RE = re.compile(r"(?m)^\s*include\s+([^\n#]+)")


def included_sources(root: Path, source: str, masked: str) -> list[Path]:
    """Repo-local files this source ``include``s, resolved to real paths.

    ONE OF THE DETECTOR'S FOUR DECLARED BLIND SPOTS, closed here.
    Nim's ``include`` splices a file in textually, so a compiler invocation in
    an included file is a compiler invocation in THIS test — but a scan of the
    including file's own bytes cannot see it. Ten sources in this tree use
    ``include``; none of them currently hides a compile behind it (checked),
    which is exactly why closing the hole now is cheap.

    Resolution is deliberately conservative: only paths that exist on disk are
    followed, and only one level. A ``include`` naming something unresolvable
    is left alone rather than guessed at.
    """
    found: list[Path] = []
    base = (root / source).parent
    for clause in INCLUDE_RE.findall(masked):
        clause = re.sub(r"\s+as\s+\w+", "", clause)
        for name in re.split(r"[,\s]+", clause.strip()):
            name = name.strip("\"[]")
            if not name:
                continue
            candidate = (base / (name + ".nim")).resolve()
            if candidate.is_file():
                found.append(candidate)
    return found


def classify_source(
    inventory: Any, source: str, text: str, root: Path | None = None
) -> tuple[bool, bool]:
    """Return ``(spawns_compiler, calls_product_api)`` for one test source.

    The two are computed SEPARATELY and only the first can be a violation.
    Collapsing them is what would make this check fire on the product.

    When ``root`` is given, ``include``d files are scanned as part of this
    source, because that is what Nim does with them.
    """
    masked = mask_embedded_fixtures(text)
    matches = inventory.compiler_invocations(source, masked)
    if root is not None:
        for included in included_sources(root, source, masked):
            matches += inventory.compiler_invocations(
                str(included),
                mask_embedded_fixtures(inventory.read_text(included)),
            )
    spawns = any("runtimeCompilerApi" not in match for match in matches)
    product_api = any("runtimeCompilerApi" in match for match in matches)
    return spawns, product_api


def detect(root: Path) -> tuple[set[str], set[str]]:
    """Scan every declared test source. Returns ``(spawners, product_api)``."""
    inventory = load_inventory()
    nim_specs, _ = inventory.parse_repro_tests(root)
    spawners: set[str] = set()
    product_api: set[str] = set()
    for spec in nim_specs:
        text = inventory.read_text(root / spec.source)
        if not text:
            continue
        spawns, api = classify_source(inventory, spec.source, text, root)
        if spawns:
            spawners.add(spec.source)
        if api:
            product_api.add(spec.source)
    return spawners, product_api


def read_dispositions(path: Path) -> tuple[dict[str, tuple[str, str]], list[str]]:
    rows: dict[str, tuple[str, str]] = {}
    errors: list[str] = []
    if not path.exists():
        return rows, [f"missing disposition file: {path}"]
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 3:
            errors.append(f"{path.name}:{number}: expected 3 tab-separated fields")
            continue
        source, verdict, justification = (field.strip() for field in fields)
        if verdict not in VALID_VERDICTS:
            errors.append(
                f"{path.name}:{number}: unknown verdict {verdict!r}; "
                f"valid: {', '.join(sorted(VALID_VERDICTS))}"
            )
        if not justification:
            errors.append(
                f"{path.name}:{number}: {source} has no justification. A verdict "
                "without a reason is a rubber stamp; say why this flow is not a "
                "migration target."
            )
        if source in rows:
            errors.append(f"{path.name}:{number}: duplicate row for {source}")
        rows[source] = (verdict, justification)
    return rows, errors


def check(root: Path, dispositions: Path | None = None) -> tuple[int, list[str]]:
    """Return ``(exit_code, failures)``.

    ``dispositions`` is a parameter rather than a constant so the check's own
    tests can point it at a synthetic tree. A check whose failure path is
    unreachable from a test is a check nobody has seen fail.
    """
    dispositions = DISPOSITIONS if dispositions is None else dispositions
    spawners, product_api = detect(root)
    rows, failures = read_dispositions(dispositions)

    reviewed = set(rows)
    detected = spawners | product_api

    for source in sorted(detected - reviewed):
        how = "spawns a compiler" if source in spawners else "calls a compile API"
        failures.append(
            f"UNREVIEWED: {source} {how} from its test body and has no row in "
            f"{dispositions.name}.\n"
            "  If the artifact is a helper/fixture binary built from a checked-in\n"
            "  source, declare a `nim.c(...)` edge in repro.nim, add the test to\n"
            "  `testFixtureArtifacts`, and give the row verdict `graph-owned`.\n"
            "  If the compile is legitimately part of what the test asserts, add a\n"
            "  row with the matching verdict and a justification."
        )

    for source in sorted(reviewed):
        verdict, _ = rows[source]
        if verdict == GRAPH_OWNED and source in spawners:
            failures.append(
                f"REGRESSED: {source} is recorded as `graph-owned` — its helper is "
                "built by a repro.nim edge — but it spawns a compiler again. The "
                "migration was undone; restore the graph edge or change the row and "
                "argue for it in review."
            )
        elif verdict == "product-api" and source in spawners:
            # The one verdict that can be checked MECHANICALLY, and it caught a
            # real mistake while this list was being written: a row claimed
            # `product-api` for a test that computes a compiler argv through a
            # product API and then SPAWNS it itself. That is a different thing —
            # the spawn is the test's, not the product's — and the verdict has
            # to say so. Without this rule, `product-api` would be the hole any
            # future helper compile could be parked in.
            failures.append(
                f"MISCLASSIFIED: {source} carries verdict `product-api`, but it "
                "spawns a compiler from its own body rather than only calling a "
                "reprobuild compile API. Use `compiler-is-subject` if executing "
                "that command is the assertion, or migrate it."
            )
        elif verdict != GRAPH_OWNED and source not in detected:
            failures.append(
                f"STALE: {source} carries verdict `{verdict}` but no compiler flow "
                "is detected in it any more. If it was migrated, change the row to "
                "`graph-owned`; otherwise delete the row. This ratchet only moves "
                "one way."
            )

    print(
        f"test sources scanned; {len(spawners)} spawn a compiler, "
        f"{len(product_api)} call a reprobuild compile API "
        f"({len(detected)} distinct sources), {len(rows)} reviewed rows"
    )
    if failures:
        print("\nFAIL: test-body helper compilation check\n", file=sys.stderr)
        for failure in failures:
            print(f"  * {failure}", file=sys.stderr)
        print(
            f"\n{len(failures)} problem(s). See the header of {Path(__file__).name} "
            "for what this check is and is not.",
            file=sys.stderr,
        )
        return 1, failures
    print(
        "OK: every compiler flow THIS DETECTOR FINDS in a test body carries a "
        "reviewed disposition (static scan; see the module header for what that "
        "does and does not cover)"
    )
    return 0, []


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--list",
        action="store_true",
        help="print the detected flows and their class, then exit 0",
    )
    parser.add_argument("--root", default=str(REPO_ROOT))
    args = parser.parse_args(argv)
    root = Path(args.root)
    if args.list:
        spawners, product_api = detect(root)
        for source in sorted(spawners | product_api):
            kind = "spawn" if source in spawners else "product-api"
            if source in spawners and source in product_api:
                kind = "spawn+product-api"
            print(f"{kind}\t{source}")
        return 0
    return check(root)[0]


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
