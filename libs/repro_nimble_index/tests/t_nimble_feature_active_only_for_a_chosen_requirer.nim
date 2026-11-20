## NPC-AREQ7: a `feature "x":` block of a Nimble package is "active only when
## the requirer names it (`requires "pkg[x]"`)". In a solve, the requirer is
## a version that is CHOSEN: a version the solver rejected names nothing.
##
## Found in the NPC-M6 review: the closure collected every feature any
## reached version named and applied it to every version of the package, so
## a feature named only by an unchosen version still bound -- here making a
## closure with an answer unsatisfiable, because the feature requires a
## package the index does not hold.
##
## Falsifying mutation: merging a feature's requirements into the package's
## own per-version requirements whenever any reached version names it (the
## lowering before the fix) fails the first case.

import std/[strutils, tables, unittest]

import repro_domain_types/nimble_index
import repro_nimble_index/resolution
import ./resolution_fixtures

proc libWithExtra(): PackageEnvelope =
  var lib = tagged("lib", "1.0.0")
  lib.features = @[RecordFeature(name: "extra", requires: @[req("heavy")])]
  package("lib", @[lib])

suite "a Nimble feature is active only for a chosen requirer (NPC-AREQ7)":
  test "a feature only an unchosen version names does not bind":
    let old1 = tagged("old", "1.0.0", @[req("lib", features = @["extra"])])
    let old2 = tagged("old", "2.0.0", @[req("lib")])
    let r = resolve(@[libWithExtra(), package("old", @[old1, old2])],
      @[("old", ">=2.0.0"), ("lib", "")])
    checkpoint r.failure
    check r.failure.len == 0
    check r.chosen.getOrDefault("nimble:old") == "2.0.0"
    check r.chosen.getOrDefault("nimble:lib") == "1.0.0"
    check "nimble:lib[extra]" notin r.chosen

  test "a chosen version naming the feature binds its requirements":
    # heavy is not in the index: the version naming the feature cannot be
    # chosen, so the closure falls back to the one that does not.
    let old1 = tagged("old", "1.0.0", @[req("lib")])
    let old2 = tagged("old", "2.0.0", @[req("lib", features = @["extra"])])
    let r = resolve(@[libWithExtra(), package("old", @[old1, old2])],
      @[("old", "")])
    checkpoint r.failure
    check r.chosen.getOrDefault("nimble:old") == "1.0.0"
    # Required outright, it is unsatisfiable and says what is missing.
    let forced = resolve(@[libWithExtra(), package("old", @[old1, old2])],
      @[("old", ">=2.0.0")])
    check forced.failure.len > 0
    check "nimble:heavy is not in the index" in forced.failure

  test "an active feature's requirements are the version's depends":
    var heavy = package("heavy", @[tagged("heavy", "3.0.0")])
    let app = tagged("old", "2.0.0", @[req("lib", features = @["extra"])])
    let r = resolve(@[libWithExtra(), heavy, package("old", @[app])],
      @[("old", "")])
    checkpoint r.failure
    check r.failure.len == 0
    check r.chosen.getOrDefault("nimble:heavy") == "3.0.0"
    check r.chosen.getOrDefault("nimble:lib[extra]") == "1.0.0"
    let rows = chosenNimblePackages(r.input, r.chosen)
    var names: seq[string]
    for c in rows:
      names.add c.identity
      if c.identity == "nimble:lib":
        check c.depends == @["nimble:heavy"]
    check names == @["nimble:heavy", "nimble:lib", "nimble:old"]
