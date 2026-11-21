## NPC-M6 verification `test_npc_m6_module_collision_reported` (NPC-AREQ18,
## threat model G16): two packages of one solved closure that both export
## `utils` at their top level are a reported collision naming both; Nim
## would otherwise take whichever `--path` comes first and say nothing.
##
## Falsifying mutation (recorded in the plan): `moduleCollisions` returning
## nothing lets the collision pass silently, and the first case fails.
##
## The collision is computed over what the SOLVE chose (the production
## lowering and clingo), so a package that only an unchosen version
## requires cannot collide -- the second case is that control. The lock
## verbs refuse to write a lock with a collision (`applyNimbleRows` in
## `repro_cli_support/nimble_lock`, a thin caller of this check).

import std/[strutils, tables, unittest]

import repro_nimble_index

import ./resolution_fixtures

proc exporting(package, tag: string; modules: seq[string];
               requires: seq[RequirementEntry] = @[]): VersionRecord =
  result = tagged(package, tag, requires)
  result.layout.modules = modules

suite "NPC-M6: a top-level module exported twice is reported":
  test "two chosen packages exporting `utils` produce an error naming both":
    let r = resolve(@[
      package("alpha", @[exporting("alpha", "1.0.0", @["alpha", "utils"])]),
      package("beta", @[exporting("beta", "2.1.0", @["beta", "utils"])])],
      @[("alpha", ""), ("beta", "")])
    check r.failure == ""
    let chosen = chosenNimblePackages(r.input, r.chosen)
    check chosen.len == 2
    let collisions = moduleCollisions(chosen)
    checkpoint collisions.join("\n")
    check collisions.len == 1
    check "module `utils`" in collisions[0]
    check "nimble:alpha 1.0.0" in collisions[0]
    check "nimble:beta 2.1.0" in collisions[0]

  test "a package only an unchosen version requires does not collide":
    let r = resolve(@[
      package("alpha", @[
        exporting("alpha", "1.0.0", @["alpha"], @[req("beta")]),
        exporting("alpha", "2.0.0", @["alpha"])]),
      package("beta", @[exporting("beta", "1.0.0", @["alpha"])])],
      @[("alpha", ">= 2.0.0")])
    check r.failure == ""
    check moduleCollisions(chosenNimblePackages(r.input, r.chosen)).len == 0

  test "distinct modules do not collide":
    let r = resolve(@[
      package("alpha", @[exporting("alpha", "1.0.0", @["alpha"])]),
      package("beta", @[exporting("beta", "1.0.0", @["beta"])])],
      @[("alpha", ""), ("beta", "")])
    check moduleCollisions(chosenNimblePackages(r.input, r.chosen)).len == 0
