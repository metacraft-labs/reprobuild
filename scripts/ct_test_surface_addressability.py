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

Keeping the ledger current
--------------------------
The ledger is a measurement taken against one state of the inventory, and it
went stale every time the inventory moved without it: a new source the surface
was never asked about failed the gate at the NEXT, unrelated change, and a
ledger regenerated BEFORE the inventory recorded case-count disagreements the
inventory's own regeneration then removed. Three things now hold it in step:

* **Order.** Regeneration refuses to measure against an inventory that
  `reprobuild_suite_inventory.py --check-inventory` calls stale, so the ledger
  can only ever be computed AFTER the inventory.
* **A build-free check** (`--check`). It needs no `ct-test`: it compares the
  ledger with the tracked inventory and with its own markdown companion. It runs
  in `scripts/check_suite_case_counts.sh`, so a change that adds or removes a
  suite source without regenerating the ledger is refused by the same pre-push
  hook and CI gate that refuse a stale inventory, at the change that caused it.
  What it cannot see is a count the surface would report differently for a
  source it already knew; that still needs the surface, and is the integration
  test's to find.
* **One producer for both files.** The figures in the companion markdown are a
  block rendered from the JSON and written with it; `--check` refuses a block
  that no longer matches the JSON, and `--write-markdown` re-renders it from the
  checked-in JSON without a surface.

Usage
-----
    python3 scripts/ct_test_surface_addressability.py                 # write both
    python3 scripts/ct_test_surface_addressability.py --print         # JSON to stdout
    python3 scripts/ct_test_surface_addressability.py --check         # build-free gate
    python3 scripts/ct_test_surface_addressability.py --write-markdown  # re-render .md

The surface is located the same way `libs/ct_test_surface` locates it:
`$CT_TEST`, then `ct-test` on PATH, then `ct`. Point `$CT_TEST` at a specific
build to record a reproducible identity — the dev shell's `ct-test` tracks the
CodeTracer pin unless the `codetracer-src` flake input overrides it, which the
workspace `.envrc` does for a `../codetracer` sibling when one exists, so on a workspace host it is not
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
INVENTORY_RELATIVE = Path("benchmarks/reports/reprobuild-suite-m0-inventory-sources.json")
ARTIFACT_RELATIVE = Path("benchmarks/reports/ct-test-surface-addressability.json")
MARKDOWN_RELATIVE = Path("benchmarks/reports/ct-test-surface-addressability.md")
INVENTORY = REPO_ROOT / INVENTORY_RELATIVE
ARTIFACT = REPO_ROOT / ARTIFACT_RELATIVE
MARKDOWN = REPO_ROOT / MARKDOWN_RELATIVE
SURFACE_CANDIDATES = ("ct-test", "ct")

# Version 2 added `trackedNimSources`, the set the measurement compared. The
# build-free check needs it to tell a source the surface was asked about from
# one it never saw, so a version-1 ledger is refused rather than half-checked.
SCHEMA_VERSION = 2

# The remedy every refusal prints. It needs the surface, which the dev shell
# puts on PATH (`ct-test` is in flake.nix's packages), and it measures only
# against a current inventory, so it names that step first.
INVENTORY_REGENERATE_COMMAND = (
    "python3 scripts/reprobuild_suite_inventory.py --write-inventory-sources"
)
REGENERATE_COMMAND = "python3 scripts/ct_test_surface_addressability.py"
MARKDOWN_REGENERATE_COMMAND = (
    "python3 scripts/ct_test_surface_addressability.py --write-markdown"
)

# The companion markdown's generated block. Everything between the two markers
# is rendered from the JSON by `render_markdown_block`; the prose around it is
# hand-written and quotes no figure the JSON carries.
MARKDOWN_BEGIN = (
    "<!-- BEGIN GENERATED by scripts/ct_test_surface_addressability.py from "
    "ct-test-surface-addressability.json. Do not edit; regenerate. -->"
)
MARKDOWN_END = "<!-- END GENERATED -->"


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


def discover_workspace(surface: str, root: Path = REPO_ROOT) -> dict:
    completed = subprocess.run(
        [surface, "test", "discover", "--workspace", str(root), "--json"],
        capture_output=True,
        text=True,
        errors="replace",
        cwd=str(root),
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


def nim_code_only(text: str) -> str:
    """Blank out Nim comments and string literals, preserving offsets.

    Every classifier below asks a question about what a file *imports*, and an
    import is a statement. Asking it of the raw bytes answers a different
    question — what the file *mentions* — and the two diverge exactly where
    this repository writes Nim inside Nim: the runner tests embed whole fixture
    modules as triple-quoted strings, and those fixtures have imports of their
    own. Four sources were attributed to the shim on the strength of an
    `import ct_test_unittest_parallel` that belonged to an embedded fixture
    while the file itself imported `std/unittest` in a bracketed clause. The
    reason was wrong and the remedy it implied was wrong with it.

    Replacing literal and comment bodies with spaces rather than deleting them
    keeps line structure intact, which the multi-line-clause test depends on.
    """
    out = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "#":
            if text.startswith("#[", i):  # block comment, nestable in Nim
                depth, j = 1, i + 2
                while j < n and depth > 0:
                    if text.startswith("#[", j):
                        depth += 1
                        j += 2
                    elif text.startswith("]#", j):
                        depth -= 1
                        j += 2
                    else:
                        j += 1
                out.append("".join(c if c == "\n" else " " for c in text[i:j]))
                i = j
                continue
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
            continue
        if text.startswith('"""', i):
            j = text.find('"""', i + 3)
            j = n if j < 0 else j + 3
            out.append("".join(c if c == "\n" else " " for c in text[i:j]))
            i = j
            continue
        if ch == "'" and not (i > 0 and (text[i - 1].isalnum() or text[i - 1] == "_")):
            # Char literal: 'a', '\n', '\''. Skipped so that a quote inside one
            # cannot open a phantom string and blank the code that follows.
            m = re.match(r"'(\\.[0-9]*|[^'\\])'", text[i:])
            if m:
                out.append(" " * m.end())
                i += m.end()
                continue
        if ch == '"':
            raw = i > 0 and (text[i - 1].isalnum() or text[i - 1] == "_")
            j = i + 1
            while j < n and text[j] != "\n":
                if text[j] == '"':
                    if raw and text.startswith('""', j):
                        j += 2
                        continue
                    j += 1
                    break
                if not raw and text[j] == "\\":
                    j += 2
                    continue
                j += 1
            out.append(" " * (j - i))
            i = j
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def classify_absent(source: Path) -> tuple[str, str]:
    """Why did the surface not see this source? Prose, not a gate."""
    code = nim_code_only(source.read_text(encoding="utf8", errors="replace"))
    # Ordered most specific first. A file can both import std/unittest and
    # import the shim; when it does, the bracketed-clause scan is the binding
    # constraint — joining the clause recovers the file whether or not the
    # shim is ever retired — so that verdict has to be reached first.
    for match in re.finditer(r"\b(?:import|from)\s+std/\[", code):
        rest = code[match.end() :]
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
                "detected in file`, for a file that plainly does import it",
            )
    if re.search(r"\bct_test_unittest_parallel\b", code):
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
            "therefore NOT recover these rows; not importing the shim does, "
            "which is what 38 sources did. The companion .md says why the one "
            "that is left keeps the import",
        )
    if re.search(r"^\s*import\s.*\bunittest\b", code, re.M):
        return ("unclassified", "imports unittest and is still not discovered")
    return (
        "declares-no-cases-of-its-own",
        "declares no literal suite/test of its own; any cases it contributes "
        "are declared in the modules it imports, which are discovered "
        "separately under their own identities",
    )


def measure(root: Path, surface: str, origin: str, response: dict) -> dict:
    """The ledger document for one discovery response and the tracked inventory."""
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

    inventory = json.loads((root / INVENTORY_RELATIVE).read_text())
    nim = [t for t in inventory["tests"] if t.get("language") == "nim"]

    unaddressable = []
    disagreements = []
    addressable_cases = 0
    for entry in sorted(nim, key=lambda t: t["source"]):
        source = entry["source"]
        recorded = entry.get("staticCaseCount", 0)
        if source not in seen_files:
            reason, detail = classify_absent(root / source)
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
        "schemaVersion": SCHEMA_VERSION,
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
            "groundTruth": INVENTORY_RELATIVE.as_posix(),
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
        # The set this measurement compared, and the one thing the build-free
        # check cannot reconstruct: which tracked sources the surface was
        # asked about. A source the inventory gains later is outside it, and
        # that is how `--check` refuses a ledger nobody regenerated.
        "trackedNimSources": sorted(t["source"] for t in nim),
        "unaddressableSources": unaddressable,
        "caseCountDisagreements": disagreements,
        "identityCollisions": collisions,
    }
    return document



def _thousands(value: int) -> str:
    return f"{value:,}"


def _cell(text: str) -> str:
    """A markdown table cell: pipes escaped, so a path cannot split a row."""
    return text.replace("|", "\\|")


def render_markdown_block(document: dict) -> str:
    """The companion markdown's figures, as a pure function of the JSON.

    Rendered from the document alone, never from the surface, so the build-free
    check can re-render it from the checked-in JSON and compare. Every figure
    the markdown states about the current tree is in here; the prose outside
    the markers states none.
    """
    counts = document["counts"]
    summary = document["reconciliation"]
    surface = document["surface"]
    by_kind = counts.get("itemsByKind", {})
    diagnostics = counts.get("responseDiagnostics", {})
    agreement = summary["perSourceCaseCountAgreement"]
    provenance = surface.get("provenance") or (
        "not declared ($CT_TEST_PROVENANCE was empty when this was measured)"
    )
    lines = [
        MARKDOWN_BEGIN,
        "",
        "## Current figures",
        "",
        "Rendered from `ct-test-surface-addressability.json` by the script that "
        "writes it, as of its last regeneration. `--check` refuses this block "
        "when it and the JSON disagree, and refuses the JSON when the inventory "
        "gains or loses a source or moves a disagreeing source's count. A case "
        "added to a source that agreed moves the inventory's totals without "
        "moving the case totals here.",
        "",
        "| Measure | Value |",
        "|---|---|",
        f"| Surface | `{surface['binary']}`, resolved by `{surface['resolvedBy']}`, "
        f"sha256 `{surface['sha256'][:12]}…` |",
        f"| Surface provenance | {_cell(provenance)} |",
        f"| Command | `{document['command']}` |",
        f"| Ground truth | `{summary['groundTruth']}` (`staticCaseCount`) |",
        f"| Catalogs returned | {counts['catalogs']}, from providers "
        + ", ".join(f"`{p}`" for p in sorted(counts.get("itemsByProvider", {})))
        + " |",
        f"| Items returned | {_thousands(counts['itemsTotal'])} — "
        f"{_thousands(by_kind.get('case', 0))} cases, "
        f"{_thousands(by_kind.get('suite', 0))} suites |",
        "| Response diagnostics | "
        + (
            ", ".join(f"{sev}: {n}" for sev, n in sorted(diagnostics.items()))
            or "none"
        )
        + f" (errors: {diagnostics.get('error', 0)}) |",
        f"| Tracked Nim suite sources | "
        f"{_thousands(summary['trackedNimSuiteSources'])} |",
        f"| …addressable through the surface | "
        f"**{_thousands(summary['sourcesAddressableThroughTheSurface'])} "
        f"({summary['sourceCoveragePercent']}%)** |",
        f"| Tracked static case count | "
        f"{_thousands(summary['trackedStaticCaseCount'])} |",
        f"| …addressable through the surface | "
        f"**{_thousands(summary['casesAddressableThroughTheSurface'])} "
        f"({summary['caseCoveragePercent']}%)** |",
        f"| Per-source case-count agreement | {_thousands(agreement['agree'])} "
        f"of {_thousands(agreement['compared'])} agree with the independent "
        "scanner |",
        f"| Distinct case identities vs case items | "
        f"{_thousands(summary['distinctCaseIdentities'])} distinct for "
        f"{_thousands(summary['caseItemsInCatalog'])} items — "
        f"**{summary['collidingIdentities']}** colliding identities |",
        "",
        f"### The {summary['sourcesNotAddressable']} sources the surface cannot "
        "see, by recorded reason",
        "",
    ]
    by_reason: dict[str, list[dict]] = collections.defaultdict(list)
    for row in document["unaddressableSources"]:
        by_reason[row["reason"]].append(row)
    if by_reason:
        lines += ["| Reason | Sources | Inventory cases |", "|---|---|---|"]
        for reason in sorted(by_reason):
            rows = by_reason[reason]
            lines.append(
                f"| `{reason}` | {len(rows)} | "
                f"{_thousands(sum(r['inventoryStaticCaseCount'] for r in rows))} |"
            )
        lines += ["", "| Source | Reason |", "|---|---|"]
        for row in document["unaddressableSources"]:
            lines.append(f"| `{_cell(row['source'])}` | `{row['reason']}` |")
    else:
        lines.append("None.")
    lines += [
        "",
        f"### The {agreement['disagree']} per-source case-count disagreements",
        "",
    ]
    if document["caseCountDisagreements"]:
        lines += ["| Source | Inventory | Surface |", "|---|---|---|"]
        for row in document["caseCountDisagreements"]:
            lines.append(
                f"| `{_cell(row['source'])}` | {row['inventoryStaticCaseCount']} "
                f"| {row['ctTestCaseCount']} |"
            )
    else:
        lines.append("None.")
    lines += [
        "",
        "The reason and detail on every row, and the sites of every colliding "
        "identity, are in the JSON.",
        "",
        MARKDOWN_END,
    ]
    return "\n".join(lines) + "\n"


def splice_markdown(markdown: str, block: str) -> str:
    """Replace the generated block in `markdown`, which must carry both markers."""
    begin = markdown.find(MARKDOWN_BEGIN)
    end = markdown.find(MARKDOWN_END)
    if begin < 0 or end < begin or markdown.count(MARKDOWN_BEGIN) != 1:
        raise ValueError(
            f"{MARKDOWN_RELATIVE} must contain exactly one generated block, "
            f"opened by `{MARKDOWN_BEGIN}` and closed by `{MARKDOWN_END}`"
        )
    tail = end + len(MARKDOWN_END)
    if markdown.startswith("\n", tail):
        tail += 1
    return markdown[:begin] + block + markdown[tail:]


def _load_json(path: Path, problems: list[str]) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf8"))
    except FileNotFoundError:
        problems.append(f"{path} does not exist")
    except (OSError, ValueError) as error:
        problems.append(f"{path} cannot be read as JSON: {error}")
    return None


def check(root: Path) -> list[str]:
    """Hold the checked-in ledger to the tracked inventory and to its markdown.

    Build-free: reads three tracked files and runs nothing. Returns one line
    per problem; empty means current. What each comparison stands for:

    * the recorded `trackedNimSources` against the inventory's Nim sources, in
      both directions. A source the inventory gained was never shown to the
      surface, so nothing says whether the gate will find it; a source it lost
      leaves rows describing a file the suite no longer tracks.
    * each `caseCountDisagreements` row's `inventoryStaticCaseCount` against the
      inventory. A mismatch means the ledger was computed against another
      inventory (regenerated before it, or not since it moved), which is how the
      gate came to fail on a disagreement the inventory itself had removed.
    * the document's own arithmetic and row membership, so a hand edit cannot
      satisfy the first two by changing one field.
    * the markdown's generated block against a re-rendering of the JSON.
    """
    problems: list[str] = []
    ledger = _load_json(root / ARTIFACT_RELATIVE, problems)
    inventory = _load_json(root / INVENTORY_RELATIVE, problems)
    if ledger is None or inventory is None:
        return problems
    if ledger.get("schemaVersion") != SCHEMA_VERSION or not isinstance(
        ledger.get("trackedNimSources"), list
    ):
        return problems + [
            f"{ARTIFACT_RELATIVE} is schemaVersion {ledger.get('schemaVersion')!r}"
            f" without the `trackedNimSources` set version {SCHEMA_VERSION} "
            "records, so it cannot be compared with the inventory"
        ]

    tracked = {
        t["source"]: t.get("staticCaseCount", 0)
        for t in inventory.get("tests", ())
        if t.get("language") == "nim"
    }
    recorded = set(ledger["trackedNimSources"])
    unaddressable = [r["source"] for r in ledger.get("unaddressableSources", ())]
    disagreements = ledger.get("caseCountDisagreements", ())

    added = sorted(set(tracked) - recorded)
    removed = sorted(recorded - set(tracked))
    if added:
        problems.append(
            f"{len(added)} Nim suite source(s) in {INVENTORY_RELATIVE} were never "
            f"measured by the ledger, so nothing says whether `ct test` can "
            f"address them: " + ", ".join(added)
        )
    if removed:
        problems.append(
            f"{len(removed)} source(s) the ledger measured are no longer in "
            f"{INVENTORY_RELATIVE}: " + ", ".join(removed)
        )
    for row in disagreements:
        source = row.get("source", "")
        if source in tracked and row.get("inventoryStaticCaseCount") != tracked[source]:
            problems.append(
                f"caseCountDisagreements row {source} was computed against an "
                f"inventory count of {row.get('inventoryStaticCaseCount')}; the "
                f"inventory now records {tracked[source]}. The ledger must be "
                "regenerated AFTER the inventory"
            )

    summary = ledger.get("reconciliation", {})
    if len(set(unaddressable)) != len(unaddressable):
        problems.append("unaddressableSources names a source more than once")
    stray = sorted(set(unaddressable) - recorded)
    if stray:
        problems.append(
            "unaddressableSources rows outside trackedNimSources: " + ", ".join(stray)
        )
    disagreeing = [r.get("source", "") for r in disagreements]
    misplaced = sorted(s for s in disagreeing if s not in recorded or s in unaddressable)
    if misplaced:
        problems.append(
            "caseCountDisagreements rows that are not addressable tracked "
            "sources: " + ", ".join(misplaced)
        )
    expected_summary = {
        "trackedNimSuiteSources": len(recorded),
        "sourcesNotAddressable": len(unaddressable),
        "sourcesAddressableThroughTheSurface": len(recorded) - len(unaddressable),
    }
    for key, value in expected_summary.items():
        if summary.get(key) != value:
            problems.append(
                f"reconciliation.{key} is {summary.get(key)!r} but the rows give {value}"
            )
    if summary.get("perSourceCaseCountAgreement", {}).get("disagree") != len(disagreements):
        problems.append(
            "reconciliation.perSourceCaseCountAgreement.disagree does not equal "
            "the number of caseCountDisagreements rows"
        )

    try:
        markdown = (root / MARKDOWN_RELATIVE).read_text(encoding="utf8")
    except OSError as error:
        return problems + [f"{MARKDOWN_RELATIVE} cannot be read: {error}"]
    try:
        expected = splice_markdown(markdown, render_markdown_block(ledger))
    except (ValueError, KeyError) as error:
        return problems + [f"{MARKDOWN_RELATIVE}: {error}"]
    if expected != markdown:
        problems.append(
            f"the generated block in {MARKDOWN_RELATIVE} does not match "
            f"{ARTIFACT_RELATIVE}; re-render it with `{MARKDOWN_REGENERATE_COMMAND}`"
        )
    return problems


def require_current_inventory(root: Path, run=subprocess.run) -> None:
    """Refuse to measure against an inventory the tree has moved past.

    The disagreements this script records are computed against the inventory,
    so a ledger written before the inventory is regenerated is wrong in the
    direction the inventory's regeneration then removes. Asking the inventory's
    own gate first makes "the ledger after the inventory" the only order in
    which regeneration succeeds. `run` is injectable so the refusal can be
    tested without the minute-long scan.
    """
    completed = run(
        [
            sys.executable,
            str(root / "scripts" / "reprobuild_suite_inventory.py"),
            "--check-inventory",
        ],
        cwd=str(root),
    )
    if completed.returncode != 0:
        raise SystemExit(
            f"refusing to measure: {INVENTORY_RELATIVE} is stale (see above). "
            "The ledger is computed against it, so regenerate it first and "
            f"then this:\n  {INVENTORY_REGENERATE_COMMAND}\n  {REGENERATE_COMMAND}"
        )


def write_ledger(root: Path, document: dict) -> None:
    """Write the JSON and the markdown block rendered from it, together."""
    markdown_path = root / MARKDOWN_RELATIVE
    markdown = splice_markdown(
        markdown_path.read_text(encoding="utf8"), render_markdown_block(document)
    )
    (root / ARTIFACT_RELATIVE).write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n"
    )
    markdown_path.write_text(markdown, encoding="utf8")


def main(argv: list[str] | None = None, root: Path = REPO_ROOT) -> int:
    parser = argparse.ArgumentParser()
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--print", action="store_true", dest="print_only")
    modes.add_argument(
        "--check",
        action="store_true",
        help="compare the checked-in ledger with the tracked inventory and with "
        "its markdown companion, and exit 1 on any disagreement. Needs no "
        "`ct-test`, no build and no nix",
    )
    modes.add_argument(
        "--write-markdown",
        action="store_true",
        help="re-render the markdown's generated block from the checked-in JSON",
    )
    args = parser.parse_args(argv)

    if args.check:
        problems = check(root)
        if not problems:
            print(f"{ARTIFACT_RELATIVE}: current with {INVENTORY_RELATIVE}")
            return 0
        print(f"{ARTIFACT_RELATIVE} is stale:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        print(
            "Regenerate it after the inventory, from the dev shell (which puts "
            f"`ct-test` on PATH):\n  {REGENERATE_COMMAND}",
            file=sys.stderr,
        )
        return 1

    if args.write_markdown:
        ledger = json.loads((root / ARTIFACT_RELATIVE).read_text(encoding="utf8"))
        path = root / MARKDOWN_RELATIVE
        path.write_text(
            splice_markdown(path.read_text(encoding="utf8"), render_markdown_block(ledger)),
            encoding="utf8",
        )
        return 0

    surface, origin = locate_surface()
    if not args.print_only:
        require_current_inventory(root)
    document = measure(root, surface, origin, discover_workspace(surface, root))
    if args.print_only:
        sys.stdout.write(json.dumps(document, indent=2, sort_keys=True) + "\n")
        return 0
    write_ledger(root, document)
    summary = document["reconciliation"]
    print(
        f"{ARTIFACT_RELATIVE} and {MARKDOWN_RELATIVE.name}: "
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
