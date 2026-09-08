#!/usr/bin/env python3
"""Measure how much of this suite is addressable through CodeTracer's `ct test`.

What this produces
------------------
`benchmarks/reports/ct-test-surface-addressability.json` — the ledger that
`tests/integration/t_ct_test_surface_case_addressability.nim` holds the tree
to. The test is the gate; this script is how the gate's expectations are
regenerated when the tree legitimately moves.

Two halves, and only one of them is a judgement:

* the *counts* are read straight out of one `ct test discover --workspace`
  response and one tracked inventory artifact, and nothing here interprets
  them;
* the *reason* attached to each source the surface could not see is this
  script's classification, and it is written into the artifact as prose so a
  reader can disagree with it. The test compares the SET of sources, never the
  reasons, so a wrong reason is a documentation defect and not a silent pass.

Why the ground truth is the inventory artifact
----------------------------------------------
`benchmarks/reports/reprobuild-suite-m0-inventory-sources.json` is produced by
`reprobuild_suite_inventory.py` — a different program, in a different language,
in a different repository from CodeTracer's provider. Using it here means the
two sides of the comparison do not share a PRODUCER. In particular NOTHING in
this measurement runs `repro_test_runner`: if it did, "the canonical surface
can address these cases" would be resting on the runner the surface is meant to
replace.

They do share a DEFINITION, and the numbers below have to be read with that in
mind. The field used here is `staticCaseCount`, which is the inventory's own
Nim token scan; the checked-in artifact carries no `--list-json`-derived count
at all. Both sides therefore count a case as a literal `test "…"` call, and a
case declared through a repository-local template is invisible to both — it can
appear in neither the numerator nor the denominator. Nine such cases exist
today (the `testWithReturn` template in the four
`tests/integration/t_repro_test_runner_*` sources that define it). They are
part of the gap between the percentages here and "every logical Reprobuild
case", and this script cannot see them.

Usage
-----
    python3 scripts/ct_test_surface_addressability.py            # write
    python3 scripts/ct_test_surface_addressability.py --print    # stdout only

The surface is located the same way `libs/ct_test_surface` locates it:
`$CT_TEST`, then `ct-test` on PATH, then `ct`. Point `$CT_TEST` at a specific
build to record a reproducible identity — the dev shell's `ct-test` tracks the
`codetracer-src` flake input, which the workspace `.envrc` auto-overrides to a
`../codetracer` sibling when one exists, so on a workspace host it is not
necessarily the pinned revision.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
INVENTORY = REPO_ROOT / "benchmarks/reports/reprobuild-suite-m0-inventory-sources.json"
ARTIFACT = REPO_ROOT / "benchmarks/reports/ct-test-surface-addressability.json"
SURFACE_CANDIDATES = ("ct-test", "ct")


def locate_surface() -> tuple[str, str]:
    """`$CT_TEST`, then `ct-test` on PATH, then `ct`. No local-runner tail."""
    from_env = os.environ.get("CT_TEST", "")
    if from_env and Path(from_env).is_file():
        return str(Path(from_env).resolve()), "environment"
    for candidate in SURFACE_CANDIDATES:
        found = shutil.which(candidate)
        if found:
            return found, f"PATH:{candidate}"
    sys.exit(
        "the canonical `ct test` surface was not found. Looked for $CT_TEST, "
        "then `ct-test` on PATH, then `ct`. `ct-test` is in the dev shell's "
        "packages (flake.nix); run this from the dev shell."
    )


def discover_workspace(surface: str) -> dict:
    completed = subprocess.run(
        [surface, "test", "discover", "--workspace", str(REPO_ROOT), "--json"],
        capture_output=True,
        text=True,
        errors="replace",
        cwd=str(REPO_ROOT),
    )
    if completed.returncode != 0:
        sys.exit(
            f"`{surface} test discover` exited {completed.returncode}:\n"
            + (completed.stderr or completed.stdout)[:2000]
        )
    stream = completed.stdout
    start = stream.find("\n{\n")
    body = stream if start < 0 else stream[start + 1 :]
    return json.loads(body)


def classify_absent(source: Path) -> tuple[str, str]:
    """Why did the surface not see this source? Prose, not a gate."""
    text = source.read_text(encoding="utf8", errors="replace")
    if re.search(r"\bct_test_unittest_parallel\b", text):
        return (
            "shim-protocol-producer",
            "imports the vendored ct_test_unittest_parallel shim instead of "
            "std/unittest. Note what does NOT happen: the provider's "
            "`frameworkForImport` matches the literal names `unittest`, "
            "`unittest2` and `unittest_parallel`, and `ct_test_unittest_parallel` "
            "is none of them — so no framework is detected, no `detected but not "
            "implemented` warning is emitted (the workspace response carries "
            "zero of those), and the file falls through the same generic path as "
            "any non-test source, reported as `no Nim unittest imports detected "
            "in file`. Implementing unittest_parallel support upstream would "
            "therefore NOT recover these rows; retiring the shim would",
        )
    for match in re.finditer(r"\b(?:import|from)\s+std/\[", text):
        rest = text[match.end() :]
        close = rest.find("]")
        if close < 0:
            continue
        clause = rest[:close]
        if "\n" in clause and re.search(r"(^|[,\s])unittest($|[,\s])", clause):
            return (
                "provider-multi-line-import",
                "imports std/unittest inside a bracketed clause spanning more "
                "than one line; the provider's framework scan is line-oriented "
                "and never sees the continuation, so the file is never scanned "
                "for declarations. It is not silent, but the diagnostic it does "
                "emit says the opposite of the truth: `no Nim unittest imports "
                "detected in file`, one of 206 such rows in the workspace "
                "response, for a file that plainly does import it",
            )
    if re.search(r"^\s*import\s.*\bunittest\b", text, re.M):
        return ("unclassified", "imports unittest and is still not discovered")
    return (
        "declares-no-cases-of-its-own",
        "declares no literal suite/test of its own; any cases it contributes "
        "are declared in the modules it imports, which are discovered "
        "separately under their own identities",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--print", action="store_true", dest="print_only")
    args = parser.parse_args()

    surface, origin = locate_surface()
    response = discover_workspace(surface)

    by_file: dict[str, list[dict]] = collections.defaultdict(list)
    by_provider: collections.Counter = collections.Counter()
    by_kind: collections.Counter = collections.Counter()
    seen_files: set[str] = set()
    identities: collections.Counter = collections.Counter()
    identity_sites: dict[str, list[dict]] = collections.defaultdict(list)
    for catalog in response["catalogs"]:
        provider = catalog["provider"]["id"]
        for item in catalog["items"]:
            by_provider[provider] += 1
            by_kind[item["kind"]] += 1
            seen_files.add(item["file"])
            if item["kind"] != "case":
                continue
            by_file[item["file"]].append(item)
            identities[item["id"]] += 1
            identity_sites[item["id"]].append(
                {"file": item["file"], "startLine": item["range"]["startLine"]}
            )

    inventory = json.loads(INVENTORY.read_text())
    nim = [t for t in inventory["tests"] if t.get("language") == "nim"]

    unaddressable = []
    disagreements = []
    addressable_cases = 0
    for entry in sorted(nim, key=lambda t: t["source"]):
        source = entry["source"]
        recorded = entry.get("staticCaseCount", 0)
        if source not in seen_files:
            reason, detail = classify_absent(REPO_ROOT / source)
            unaddressable.append(
                {
                    "source": source,
                    "reason": reason,
                    "detail": detail,
                    "inventoryStaticCaseCount": recorded,
                }
            )
            continue
        observed = len(by_file.get(source, ()))
        addressable_cases += observed
        if observed != recorded:
            disagreements.append(
                {
                    "source": source,
                    "inventoryStaticCaseCount": recorded,
                    "ctTestCaseCount": observed,
                }
            )

    collisions = [
        {
            "id": identity,
            "occurrences": count,
            "sites": sorted(
                identity_sites[identity], key=lambda s: (s["file"], s["startLine"])
            ),
            "detail": "more than one declaration reduces to this identity; the "
            "surface's id is a slug and carries no line, so these declarations "
            "are not separately addressable through it. Check the sites before "
            "calling it a source-side duplication: discovery is a static scan "
            "and is blind to `when` selection, so declarations in mutually "
            "exclusive branches collide here while at most one of them exists "
            "in any given build. That is a limitation of the identity (it has "
            "no configuration dimension), not necessarily a defect in the "
            "source",
        }
        for identity, count in sorted(identities.items())
        if count > 1
    ]

    tracked_cases = sum(t.get("staticCaseCount", 0) for t in nim)
    case_items = sum(len(v) for v in by_file.values())
    document = {
        "schemaVersion": 1,
        "title": "Reprobuild case addressability through the canonical "
        "`ct test` surface",
        "generatedBy": "scripts/ct_test_surface_addressability.py",
        "command": f"{Path(surface).name} test discover --workspace <repo> --json",
        "discoveryScope": "auto (the surface's default: the workspace's own VCS "
        "inventory; vendored and ignored trees excluded)",
        # Deliberately NOT the absolute path: this file is tracked, and a
        # host-local path in it would be provenance that means nothing on any
        # other machine. The content hash identifies the build; `provenance`
        # is whatever the operator declared through $CT_TEST_PROVENANCE, and
        # an empty one is recorded as empty rather than guessed at.
        "surface": {
            "binary": Path(surface).name,
            "resolvedBy": origin,
            "sha256": hashlib.sha256(Path(surface).read_bytes()).hexdigest(),
            "provenance": os.environ.get("CT_TEST_PROVENANCE", ""),
        },
        "counts": {
            "catalogs": len(response["catalogs"]),
            "itemsTotal": sum(by_provider.values()),
            "itemsByProvider": dict(sorted(by_provider.items())),
            "itemsByKind": dict(sorted(by_kind.items())),
            "responseDiagnostics": dict(
                sorted(
                    collections.Counter(
                        d["severity"] for d in response.get("diagnostics", ())
                    ).items()
                )
            ),
        },
        "reconciliation": {
            "groundTruth": str(INVENTORY.relative_to(REPO_ROOT)),
            "trackedNimSuiteSources": len(nim),
            "sourcesAddressableThroughTheSurface": len(nim) - len(unaddressable),
            "sourcesNotAddressable": len(unaddressable),
            "sourceCoveragePercent": round(
                100.0 * (len(nim) - len(unaddressable)) / len(nim), 2
            ),
            "trackedStaticCaseCount": tracked_cases,
            "casesAddressableThroughTheSurface": addressable_cases,
            "caseCoveragePercent": round(100.0 * addressable_cases / tracked_cases, 2),
            "caseItemsInCatalog": case_items,
            "distinctCaseIdentities": len(identities),
            "collidingIdentities": len(collisions),
            "perSourceCaseCountAgreement": {
                "compared": len(nim) - len(unaddressable),
                "agree": len(nim) - len(unaddressable) - len(disagreements),
                "disagree": len(disagreements),
            },
        },
        "unaddressableSources": unaddressable,
        "caseCountDisagreements": disagreements,
        "identityCollisions": collisions,
    }

    rendered = json.dumps(document, indent=2, sort_keys=True) + "\n"
    if args.print_only:
        sys.stdout.write(rendered)
    else:
        ARTIFACT.write_text(rendered)
        summary = document["reconciliation"]
        print(
            f"{ARTIFACT.relative_to(REPO_ROOT)}: "
            f"{summary['sourcesAddressableThroughTheSurface']}"
            f"/{summary['trackedNimSuiteSources']} sources "
            f"({summary['sourceCoveragePercent']}%), "
            f"{summary['casesAddressableThroughTheSurface']}"
            f"/{summary['trackedStaticCaseCount']} cases "
            f"({summary['caseCoveragePercent']}%), "
            f"{summary['collidingIdentities']} colliding identities"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
