## GM5: the shared built-in predicate fixtures (`tests/fixtures/predicates/`,
## README there) evaluated by Reprobuild's own predicate implementation.
##
## The built-in predicate grammar has two implementations: this one
## (`repro_home_intent/predicate.nim` — `validateBuiltinPredicate`, the
## validator a data file's `when` goes through, and `predicateHolds`, THE
## guard rule the planner and `repro home export --target` apply), and the
## Nix helper library's (`nix/lib/predicate.nix`), which the Nix boundary
## forces (reprobuild-pm spec Gradual-Nix-To-Reprobuild-Migration.md
## §Platform-neutral intent). Both read the same `cases.json`; the flake
## check `lib-tests` runs the Nix side. A case both sides pass cannot drift
## on one side only.
##
## Each evaluation is run for EVERY target system, with the facts
## `repro home export --target` uses (`targetHostContext` over
## `ProfileTargetPlatforms`, so the system-to-platform table is pinned by
## the fixtures too): it must hold exactly on `holdsOn`. Each rejection must
## make `validateBuiltinPredicate` raise — `EUnknownPredicate` naming the
## identifier, or `EUnstructured`.
##
## Vacuity: the fixture lists every target system, has evaluations that
## hold nowhere, everywhere and on a strict subset, and both rejection
## classes.
##
## No mocks; no subprocesses. Platforms: every host (the evaluation targets
## are named, not the host's).

import std/[algorithm, json, os, sequtils, unittest]

import repro_home_intent
import repro_profile_compile

const FixtureFile = currentSourcePath().parentDir().parentDir().parentDir().
  parentDir() / "tests" / "fixtures" / "predicates" / "cases.json"

proc cases(): JsonNode = parseFile(FixtureFile)

suite "GM5: shared built-in predicate fixtures":

  test "the fixture covers every target system and both outcomes":
    let doc = cases()
    var systems = doc["systems"].getElems.mapIt(it.getStr)
    var known = targetSystemNames()
    systems.sort()
    known.sort()
    check systems == known
    let evaluations = doc["evaluations"].getElems
    check evaluations.anyIt(it["holdsOn"].len == 0)
    check evaluations.anyIt(it["holdsOn"].len == systems.len)
    check evaluations.anyIt(it["holdsOn"].len > 0 and
      it["holdsOn"].len < systems.len)
    let rejections = doc["rejections"].getElems
    check rejections.anyIt(it["error"].getStr == "unknown-identifier")
    check rejections.anyIt(it["error"].getStr == "invalid")

  test "evaluations: a predicate holds exactly on its holdsOn systems":
    let doc = cases()
    for evaluation in doc["evaluations"]:
      let source = evaluation["predicate"].getStr
      let host = evaluation["host"].getStr
      let ast = validateBuiltinPredicate(source)
      var holds: seq[string]
      for system in doc["systems"]:
        let index = findTargetPlatform(system.getStr)
        check index >= 0
        let ctx = targetHostContext(ProfileTargetPlatforms[index], host)
        if predicateHolds(ast, ctx):
          holds.add system.getStr
      holds.sort()
      var expected = evaluation["holdsOn"].getElems.mapIt(it.getStr)
      expected.sort()
      checkpoint(repr(source) & " @ host " & host & " -> " & $holds &
        " (expected " & $expected & ")")
      check holds == expected

  test "rejections: the validator refuses each with its error class":
    let doc = cases()
    for rejection in doc["rejections"]:
      let source = rejection["predicate"].getStr
      var got = "accepted"
      var identifier = ""
      try:
        discard validateBuiltinPredicate(source)
      except EUnknownPredicate as e:
        got = "unknown-identifier"
        identifier = e.identifier
      except EUnstructured:
        got = "invalid"
      checkpoint(repr(source) & " -> " & got & " " & identifier)
      check got == rejection["error"].getStr
      if rejection.hasKey("identifier"):
        check identifier == rejection["identifier"].getStr
