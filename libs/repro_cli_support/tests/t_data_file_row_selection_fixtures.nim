## GM4: the shared row-selection fixtures under
## `tests/fixtures/data-files/` (README there) evaluated by the profile
## planner. GM5's Nix `reprobuild.lib.readData` is tested against the same
## directories; equal selections on both sides is how the two
## implementations of the data-file semantics are held together (the Nix
## side is a second implementation forced by the Nix boundary, spec
## §The Nix helper library).
##
## Each `row-selection` case is evaluated through the real chain, not a
## re-statement of the rule: the data file is read and merged by
## `expandProfileData` (what `repro home plan` / `apply` / `export` call),
## the expanded intent is put into an export document and evaluated by
## `evaluateHomeExport` (what `repro home export --target` runs: the
## planner's `enabledActivitiesFor` + `buildPlan` under the target's
## predicate facts). Each `row-rejection` case must make `expandProfileData`
## raise `EDataFile` naming every listed substring.
##
## Vacuity: the fixture tree is non-empty in both groups, and every
## selection case has at least one evaluation with a non-empty and one with
## a different package set (so a constant answer cannot pass).
##
## Falsifying mutations (performed when this test was written, see the
## milestone file): `mergeDataRows` dropping the `when` guard (rows become
## unconditional) — red in platform-guards, host-guards, combined-guards;
## `decodeRow` not validating `when` — red in every guard rejection case;
## `constructResourceRow` dropping the row's guard — red in resource-rows.
##
## No mocks; no subprocesses. Platforms: every host (the evaluation targets
## are named, not the host's).

import std/[algorithm, json, os, sequtils, strutils, unittest]

import repro_profile
import repro_home_intent
import repro_profile_compile
import repro_cli_support/home_export

const FixtureRoot = currentSourcePath().parentDir().parentDir().parentDir().
  parentDir() / "tests" / "fixtures" / "data-files"

proc caseDirs(group: string): seq[string] =
  for kind, path in walkDir(FixtureRoot / group):
    if kind == pcDir:
      result.add path
  result.sort()

proc intentFor(caseDir: string; caseJson: JsonNode): ProfileIntent =
  result.name = "fixture"
  result.dataFiles = @["data.toml"]
  if caseJson.hasKey("hosts"):
    for host, acts in caseJson["hosts"]:
      result.hosts[host] = acts.getElems.mapIt(it.getStr)

proc exportDocument(intent: ProfileIntent; host: string): JsonNode =
  ## A minimal export document around an expanded intent: every platform
  ## `same` (the fixtures are data only, there is no compile-time branch).
  var platforms = newJObject()
  for name in targetSystemNames():
    platforms[name] = %"same"
  %*{"format": HomeExportFormat, "schemaVersion": HomeExportSchemaVersion,
    "selection": {"host": host}, "intent": parseJson(
      emitProfileIntentJson(intent)), "platforms": platforms,
    "provenance": {"profile": {"root": "home.nim"},
      "compile": {"target": compilingPlatformSystem()}}}

suite "GM4: shared data-file row-selection fixtures":

  test "the fixture tree is populated":
    check caseDirs("row-selection").len >= 6
    check caseDirs("row-rejection").len >= 10

  test "row-selection: the planner selects the expected rows":
    for dir in caseDirs("row-selection"):
      let name = dir.extractFilename
      let caseJson = parseFile(dir / "case.json")
      let expanded = expandProfileData(intentFor(dir, caseJson),
        dir / "home.nim")
      check expanded.intent.dataFiles.len == 0
      check expanded.dataFiles.len == 1
      var answers: seq[seq[string]]
      for evaluation in caseJson["evaluations"]:
        let host = evaluation["host"].getStr
        let system = evaluation["system"].getStr
        let evaluated = evaluateHomeExport(
          exportDocument(expanded.intent, host), system, host)
        var got = evaluated["packages"].getElems.mapIt(it["name"].getStr)
        got = got.deduplicate()
        got.sort()
        let expected = evaluation["packages"].getElems.mapIt(it.getStr)
        checkpoint(name & ": " & host & " @ " & system & " -> " & $got &
          " (expected " & $expected & ")")
        check got == expected
        var answer = got
        if evaluation.hasKey("resources"):
          var addresses = evaluated["resources"].getElems.mapIt(
            it["address"].getStr)
          addresses.sort()
          let expectedResources = evaluation["resources"].getElems.mapIt(
            it.getStr)
          checkpoint(name & ": resources " & $addresses & " (expected " &
            $expectedResources & ")")
          check addresses == expectedResources
          answer.add "|"
          answer.add addresses
        answers.add answer
      # Vacuity: the case discriminates.
      check answers.anyIt(it.len > 0)
      check answers.deduplicate().len >= 2

  test "row-rejection: the file is refused with the expected diagnostic":
    for dir in caseDirs("row-rejection"):
      let name = dir.extractFilename
      let caseJson = parseFile(dir / "case.json")
      var message = ""
      try:
        discard expandProfileData(intentFor(dir, caseJson), dir / "home.nim")
      except EDataFile as e:
        message = e.msg
      checkpoint(name & ": " & message)
      check message.len > 0
      check message.contains("data.toml")
      for needle in caseJson["error"]:
        check message.contains(needle.getStr)
