## Shared helpers for the `repro home compare` gates
## (`t_e2e_compare_reports_each_category.nim`,
## `t_e2e_compare_unmapped_is_not_different.nim`,
## `t_e2e_compare_allowlist_requires_reasons.nim`): run the real
## `build/bin/repro home compare` on documents written to a temporary
## directory, and read the fixture pair under `tests/fixtures/host-facts/`.
##
## No mocks: the gates drive the built CLI as a user does; the only inputs
## are JSON / TOML files on the real filesystem.

import std/[json, os, tempfiles]
from repro_core/paths import extendedPath

import repro_test_support

import ./profile_compile_edge_harness

const FixtureDir* = ProjectRoot / "tests" / "fixtures" / "host-facts"

type
  CompareRun* = object
    exitCode*: int
    stdout*, stderr*: string

proc fixture*(name: string): JsonNode =
  parseJson(readFile(extendedPath(FixtureDir / name)))

proc newScratch*(label: string): string =
  createTempDir("repro-gm6-" & label & "-", "")

proc writeDoc*(dir, name: string; doc: JsonNode): string =
  result = dir / name
  writeFile(extendedPath(result), pretty(doc))

proc writeText*(dir, name, text: string): string =
  result = dir / name
  writeFile(extendedPath(result), text)

proc runCompare*(args: openArray[string]): CompareRun =
  var full = @["home", "compare"]
  for a in args: full.add a
  let res = runProgramSplit(reproBinary(), full)
  CompareRun(exitCode: res.code, stdout: res.stdout, stderr: res.stderr)

proc asSide*(doc: JsonNode; side: string): JsonNode =
  ## `doc` re-labelled as the other side's document, unmapped and
  ## uncategorized lists emptied: the "identical facts" negative control.
  result = doc.copy()
  result["side"] = %side
  result["unmapped"] = newJArray()
  result["uncategorized"] = newJArray()

proc statusIds*(report: JsonNode; category, status: string): seq[string] =
  for e in report["categories"][category][status]:
    result.add e["id"].getStr
