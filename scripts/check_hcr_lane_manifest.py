#!/usr/bin/env python3
"""HX-S-10 — the HCR gate family's per-platform expectations, held to the tree.

WHAT THIS FILE IS

``scripts/hcr-lane-manifest.tsv`` declares, for every HCR gate source in the
tree, what each of the three platform lanes is expected to do with it: RUN it
(and then execute at least N assertion-bearing cases) or declare it
UNSUPPORTED on that platform.  This script is the gate that keeps that
declaration honest.  ``scripts/run_hcr_lane.sh`` is the consumer.

WHY A MANIFEST AND NOT A ``when defined(...)`` READ

The obvious alternative -- have the lane derive "does this gate run here?"
from the gate's own platform guard -- is the defect, not the fix.  A gate's
guard is exactly the thing that goes wrong: three ``tests/e2e/hcr-watch/``
gates have a ``when defined(macosx) and defined(arm64)`` body and no else
arm, so on Linux they are not "declared macOS-only", they are simply silent.
A lane that asks the source what it expects can never disagree with the
source, so it cannot report that the source is wrong.  The declaration has to
live somewhere a HUMAN wrote it and a MACHINE compares it against two
independent things: the tree (this script) and the run (``run_hcr_lane.sh``).

WHAT IT CATCHES, AND THE FAILURE IT EXISTS FOR

1. A NEW HCR gate file that nobody declared.  The row set is compared against
   a live glob of the tree, not against a hardcoded subject list -- see
   Verification-Harness-Traps.md Sec. 35, where a ``staticRead`` subject list
   could not see a new file in the directory it claimed to cover.  Adding a
   gate and declaring it for ONE platform is impossible: a row must carry a
   token for all three columns or this script fails by name.  "Added to
   Linux, forgot macOS and Windows" is the exact drift this refuses.

2. A DELETED gate file whose row survives.  Same comparison, other direction.

3. A ``run:`` row naming a ``just`` target that does not exist -- a lane that
   would die on an unknown recipe rather than on a gate result.

4. A manifest that declares everything unsupported on some platform.  That
   satisfies "no lane failed" by running nothing, which is the shape
   Verification-Harness-Traps.md Sec. 4 is about; each platform must carry a
   ``run:`` row.

5. Its own instrument going blind.  The tree glob is asserted against a floor
   before anything is compared, so a glob that matched nothing cannot satisfy
   a set equality by leaving nothing to disagree with it.

CELL GRAMMAR

  ``run:<N>``      -- this lane must run the gate and observe at least N
                      assertion-bearing cases, and ZERO ``[SKIPPED]``.  N is
                      MEASURED on a real run of that platform; it is not a
                      guess.
  ``run:unmeasured`` -- this lane must run the gate, and no floor has been
                      measured on that platform yet.  The lane still refuses
                      zero cases and still refuses ``[SKIPPED]``; what it
                      cannot do is notice a DROP.  ``run_hcr_lane.sh`` prints
                      the measured count for every such cell so filling it in
                      is transcription, never estimation.
  ``run:<N>+skip:<M>`` -- the gate has a platform-neutral half and an
                      off-platform half in ONE file.  N cases must execute and
                      exactly M cases may be skipped.  This is NOT a licence to
                      skip: the lane additionally requires M lines matching the
                      loud-unsupported diagnostic

                          UNSUPPORTED: <case> requires <platform> ...;
                          covered by <platform> CI on <runner>.

                      so a BARE ``skip()`` can never satisfy a ``skip:`` cell.
                      A new silent skip pushes the observed count past M and
                      reddens the lane by name.  Use it only where splitting
                      the file would separate a structural assertion from the
                      engine assertion it is about.
  ``unsupported``  -- this lane must NOT count the gate.  The gate is still
                      part of the census: executed + unsupported == total, and
                      ``--verify-unsupported`` RUNS it here and requires it to
                      execute zero cases, so the declaration is checked in both
                      directions.

Run ``--check`` (the ``just lint`` entry point), ``--platform <id>`` to print
one lane's work list, or ``--census`` for the per-platform totals.
"""

from __future__ import annotations

import argparse
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(REPO_ROOT, "scripts", "hcr-lane-manifest.tsv")
JUSTFILE = os.path.join(REPO_ROOT, "Justfile")

PLATFORMS = ["linux-x86_64", "macos-arm64", "windows-x86_64"]

# Anti-vacuity floor for the TREE GLOB itself.  Measured 2026-09-19: 46 HCR
# gate sources.  The floor is deliberately well below that and above zero --
# its job is to refuse a glob that matched nothing or almost nothing, which
# would satisfy every set comparison below by leaving nothing to compare.
TREE_CENSUS_FLOOR = 30

CELL_RE = re.compile(r"^(?:unsupported|run:(?:unmeasured|[0-9]+)(?:\+skip:[0-9]+)?)$")

# A gate with NO platform guard anywhere in its CODE is portable by
# construction, and declaring it `unsupported` on a platform silently drops
# coverage that would have run.  The escape hatch is deliberate and greppable:
# put this token in the row's note, followed by the reason.
PORTABLE_OVERRIDE = "unsupported-despite-portable:"
GUARD_RE = re.compile(r"when\s+(?:not\s+)?defined\((?:linux|macosx|windows|posix|android)\)")


def code_only(path: str) -> str:
    """The source with whole-line ``#``/``##`` comments removed.

    RESIDUAL, stated where the scan is rather than where its result is quoted
    (Verification-Harness-Traps.md Sec. 35): a guard spelled in a TRAILING
    comment on a line that also carries code is not removed, so such a gate
    reads as guarded and is exempted from the portable-coverage rule below.
    That fails in the permissive direction -- it can miss a misdeclaration, it
    cannot invent one -- and no gate in the tree is written that way today.
    The failure it DOES catch is the one that actually happened: this
    milestone's own manifest declared the portable
    ``t_hcr_rb_application_abi_contract`` unsupported on macOS because a
    generator matched ``when defined(linux) and defined(amd64)`` inside that
    file's WHOLE-LINE comment at :21 -- the exact confusion the milestone's
    Goal warns about, reproduced by the tool written to end it.
    """
    with open(os.path.join(REPO_ROOT, path), "r", encoding="utf-8", errors="replace") as handle:
        return "".join(line for line in handle if not line.lstrip().startswith("#"))


def tree_census() -> list[str]:
    """Every HCR gate source, enumerated from the TREE.

    A glob, never a literal list: Verification-Harness-Traps.md Sec. 35.  The
    subject is `tests/**/t_*hcr*.nim`, which is the same subject the milestone
    census uses (`find tests -name 't_*hcr*.nim'`).
    """
    found: list[str] = []
    tests_root = os.path.join(REPO_ROOT, "tests")
    for dirpath, _dirnames, filenames in os.walk(tests_root):
        for name in filenames:
            if not name.endswith(".nim"):
                continue
            if not name.startswith("t_"):
                continue
            if "hcr" not in name:
                continue
            abs_path = os.path.join(dirpath, name)
            found.append(os.path.relpath(abs_path, REPO_ROOT).replace(os.sep, "/"))
    return sorted(found)


def just_targets() -> set[str]:
    targets: set[str] = set()
    with open(JUSTFILE, "r", encoding="utf-8") as handle:
        for line in handle:
            match = re.match(r"^([a-z_][a-z0-9_-]*):", line)
            if match:
                targets.add(match.group(1))
    return targets


class Row:
    __slots__ = ("source", "target", "cells", "note", "lineno")

    def __init__(self, source: str, target: str, cells: dict, note: str, lineno: int):
        self.source = source
        self.target = target
        self.cells = cells
        self.note = note
        self.lineno = lineno

    def runs_on(self, platform: str) -> bool:
        return self.cells[platform].startswith("run:")

    def floor(self, platform: str):
        cell = self.cells[platform]
        if not cell.startswith("run:"):
            return None
        value = cell[len("run:"):].split("+", 1)[0]
        return None if value == "unmeasured" else int(value)

    def declared_skips(self, platform: str) -> int:
        cell = self.cells[platform]
        if "+skip:" not in cell:
            return 0
        return int(cell.split("+skip:", 1)[1])


def load_manifest(path: str, errors: list[str]) -> list[Row]:
    rows: list[Row] = []
    if not os.path.exists(path):
        errors.append(f"manifest missing: {path}")
        return rows
    with open(path, "r", encoding="utf-8") as handle:
        for lineno, raw in enumerate(handle, start=1):
            line = raw.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            fields = line.split("\t")
            if fields[0] == "source":
                # Header row: it is checked rather than skipped, because a
                # column reordered without the consumers noticing is how a
                # per-platform table silently starts answering about the
                # wrong platform.
                expected = ["source", "just_target"] + PLATFORMS + ["note"]
                if fields != expected:
                    errors.append(
                        f"{path}:{lineno}: header is {fields!r}, expected {expected!r} "
                        "-- the platform columns are positional and every consumer reads them by index"
                    )
                continue
            if len(fields) != 2 + len(PLATFORMS) + 1:
                errors.append(
                    f"{path}:{lineno}: {len(fields)} field(s), expected "
                    f"{2 + len(PLATFORMS) + 1} (source, just_target, {', '.join(PLATFORMS)}, note)"
                )
                continue
            source, target = fields[0], fields[1]
            cells = dict(zip(PLATFORMS, fields[2:2 + len(PLATFORMS)]))
            note = fields[-1]
            for platform, cell in cells.items():
                if not CELL_RE.match(cell):
                    errors.append(
                        f"{path}:{lineno}: {source}: {platform} cell is {cell!r}; "
                        "expected 'unsupported', 'run:unmeasured' or 'run:<N>'"
                    )
            rows.append(Row(source, target, cells, note, lineno))
    return rows


def check(rows: list[Row], manifest_path: str, errors: list[str]) -> None:
    census = tree_census()

    # (5) The instrument first.  A glob that matched nothing would satisfy
    # every comparison below.
    if len(census) < TREE_CENSUS_FLOOR:
        errors.append(
            f"tree census found only {len(census)} HCR gate source(s) under tests/, "
            f"below the anti-vacuity floor of {TREE_CENSUS_FLOOR}. The glob, not the tree, "
            "is the thing to check first: an empty enumeration satisfies every set "
            "comparison in this gate by leaving nothing to disagree with it."
        )
        return

    declared = [row.source for row in rows]
    if len(declared) != len(set(declared)):
        seen: set[str] = set()
        for source in declared:
            if source in seen:
                errors.append(f"{manifest_path}: duplicate row for {source}")
            seen.add(source)

    declared_set = set(declared)
    census_set = set(census)

    for source in sorted(census_set - declared_set):
        errors.append(
            f"UNDECLARED HCR gate: {source} exists in the tree and has no row in "
            f"{os.path.relpath(manifest_path, REPO_ROOT)}. Add one row declaring what EACH of "
            f"{', '.join(PLATFORMS)} does with it. Declaring it for one platform is not "
            "possible and that is the point: a gate added to one lane and forgotten on the "
            "other two is the drift this gate exists to refuse."
        )
    for source in sorted(declared_set - census_set):
        errors.append(
            f"STALE HCR gate row: {os.path.relpath(manifest_path, REPO_ROOT)} declares {source}, "
            "which is not in the tree. Delete the row, or restore the file."
        )

    targets = just_targets()
    for row in rows:
        runs_anywhere = any(row.runs_on(platform) for platform in PLATFORMS)
        if runs_anywhere and row.target not in targets:
            errors.append(
                f"{manifest_path}:{row.lineno}: {row.source} is declared 'run' on at least one "
                f"platform but its just target {row.target!r} does not exist in the Justfile. "
                "A lane would die on an unknown recipe instead of on a gate result."
            )
        if not runs_anywhere:
            errors.append(
                f"{manifest_path}:{row.lineno}: {row.source} is 'unsupported' on every platform. "
                "A gate no lane ever runs is not covered by this campaign; either give it a "
                "lane or delete it."
            )

    for platform in PLATFORMS:
        running = [row for row in rows if row.runs_on(platform)]
        if not running:
            errors.append(
                f"no gate is declared 'run' on {platform}. A lane with nothing to run "
                "satisfies 'no failures' trivially."
            )

    # A PORTABLE gate must not be quietly dropped from a lane.
    #
    # This rule exists because it fired on its own author. The first version of
    # this manifest declared `t_hcr_rb_application_abi_contract` -- the
    # platform-neutral rb_hcr_* ABI contract gate, whose whole point is that it
    # runs everywhere -- `unsupported` on macOS, because the generator that
    # seeded the table read a platform guard out of a COMMENT. Nothing would
    # have said so: a gate that runs on two lanes instead of three still leaves
    # every lane green.
    portable_checked = 0
    for row in rows:
        if row.source not in census_set:
            continue  # already reported as stale above
        if GUARD_RE.search(code_only(row.source)):
            continue
        portable_checked += 1
        if PORTABLE_OVERRIDE in row.note:
            continue
        dropped = [p for p in PLATFORMS if not row.runs_on(p)]
        if dropped:
            errors.append(
                f"{manifest_path}:{row.lineno}: {row.source} has NO platform guard in its code "
                f"— it is portable by construction — yet it is declared 'unsupported' on "
                f"{', '.join(dropped)}. A portable gate dropped from a lane is coverage lost "
                f"with every lane still green. Either declare it 'run' there, or put "
                f"'{PORTABLE_OVERRIDE} <reason>' in the row's note so the exception is "
                "deliberate and greppable."
            )
    if portable_checked == 0:
        errors.append(
            "the portable-coverage rule examined ZERO gates. Every HCR gate source appears to "
            "carry a platform guard, which has never been true; the guard scan, not the tree, "
            "is what to check first (Verification-Harness-Traps.md Sec. 4)."
        )


def report_platform(rows: list[Row], platform: str) -> None:
    for row in rows:
        if row.runs_on(platform):
            floor = row.floor(platform)
            print(
                f"run\t{row.target}\t{row.source}"
                f"\t{'' if floor is None else floor}\t{row.declared_skips(platform)}"
            )
        else:
            print(f"unsupported\t{row.target}\t{row.source}\t\t0")


def report_census(rows: list[Row]) -> None:
    print(f"total\t{len(rows)}")
    for platform in PLATFORMS:
        running = [row for row in rows if row.runs_on(platform)]
        measured = [row for row in running if row.floor(platform) is not None]
        total_floor = sum(row.floor(platform) for row in measured)
        print(
            f"{platform}\trun={len(running)}\tunsupported={len(rows) - len(running)}"
            f"\tmeasured_floors={len(measured)}\tcase_floor={total_floor}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="hold the manifest to the tree (lint entry point)")
    parser.add_argument("--platform", choices=PLATFORMS, help="print one lane's work list")
    parser.add_argument("--census", action="store_true", help="print per-platform totals")
    parser.add_argument(
        "--manifest",
        default=MANIFEST,
        help="read another TSV instead of the tracked one. Used only by the gate that PROVES the "
             "lane, so its falsifier arms never mutate a tracked file and can never leave one "
             "mutated (Verification-Harness-Traps.md Sec. 32h).",
    )
    args = parser.parse_args()

    errors: list[str] = []
    rows = load_manifest(args.manifest, errors)

    if args.platform or args.census:
        if errors:
            for error in errors:
                print(f"check_hcr_lane_manifest: {error}", file=sys.stderr)
            return 1
        if args.platform:
            report_platform(rows, args.platform)
        if args.census:
            report_census(rows)
        return 0

    check(rows, args.manifest, errors)
    if errors:
        for error in errors:
            print(f"check_hcr_lane_manifest: {error}", file=sys.stderr)
        print(
            f"check_hcr_lane_manifest: {len(errors)} problem(s). "
            f"Remedy: edit {os.path.relpath(args.manifest, REPO_ROOT)} so every HCR gate source in the "
            "tree has exactly one row declaring all three platforms.",
            file=sys.stderr,
        )
        return 1
    census = tree_census()
    print(
        f"check_hcr_lane_manifest: {len(census)} HCR gate source(s) in the tree, "
        f"{len(rows)} declared, all three platforms declared for each."
    )
    report_census(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
