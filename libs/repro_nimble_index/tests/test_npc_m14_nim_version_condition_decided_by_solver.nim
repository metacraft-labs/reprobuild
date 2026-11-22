## NPC-M14 verification `test_npc_m14_nim_version_condition_decided_by_solver`
## (A3; NPC-AREQ7).
##
## A record carries the `chronicles` v0.11.0 idiom
##
##   when NimMajor >= 2:
##     taskRequires "test", "testutils"
##   else:
##     requires "testutils"
##
## read by the static reader into a requirement under `not (NimMajor >= 2)`.
## Solved with `uses: nim` at 2.2.4, `testutils` is not in the closure;
## solved at 1.6.20, it is. The record is statically readable, has no
## `unreadable` flag and needs no override. With both Nims offered and the
## project pinning one, the Nim the solve chooses decides it.
##
## Falsifying mutation (recorded in the plan): evaluating every Nim-version
## term as false puts `testutils` in the 2.2.4 closure, and fails the test.

import std/[strutils, tables, unittest]

import repro_nimble_index

import ./resolution_fixtures
import ./m14_fixtures

suite "NPC-M14: a Nim-version condition is decided by the solve's Nim":
  test "the record is read statically, with the condition as data":
    let pkgs = chroniclesIdiomPackages()
    let r = pkgs[0].versions[0]
    check r.readerClass == rrcClosedWhen
    check flUnreadable notin r.flags
    check flOverrideApplied notin r.flags
    var testutils = 0
    for e in r.requires:
      if e.target == "testutils":
        inc testutils
        check renderCondition(e.condition) == "not (NimMajor >= 2)"
    check testutils == 1
    # The shard holding it round-trips through the codec (schema 3).
    let built = buildIndex(buildInput(pkgs))
    var idx = openIndex(memorySource(objectTable(built)), built.rootId)
    let found = lookupPackage(idx, "chronicles")
    check found.found
    check found.package.versions[0] == r

  test "at Nim 2.2.4 testutils is not in the closure":
    let r = resolve(chroniclesIdiomPackages(), @[("chronicles", "")],
      nimVersions = @["2.2.4"])
    checkpoint r.failure
    check r.failure == ""
    check r.chosen["nim"] == "2.2.4"
    check r.chosen["nimble:chronicles"] == "0.11.0"
    check r.chosen["nimble:json_serialization"] == "0.2.9"
    check "nimble:testutils" notin r.chosen
    # The lock's rows: chronicles depends on json_serialization only, and
    # no solver device (feature or Nim gate) is a chosen package of it.
    let chosen = chosenNimblePackages(r.input, r.chosen)
    var names: seq[string]
    for c in chosen: names.add c.identity
    check names == @["nimble:chronicles", "nimble:json_serialization"]
    check chosen[0].depends == @["nimble:json_serialization"]

  test "at Nim 1.6.20 testutils is in the closure":
    let r = resolve(chroniclesIdiomPackages(), @[("chronicles", "")],
      nimVersions = @["1.6.20"])
    checkpoint r.failure
    check r.failure == ""
    check r.chosen["nim"] == "1.6.20"
    check r.chosen["nimble:chronicles"] == "0.11.0"
    check r.chosen["nimble:testutils"] == "0.5.0"
    let chosen = chosenNimblePackages(r.input, r.chosen)
    check chosen[0].name == "chronicles"
    check chosen[0].depends == @["nimble:json_serialization",
      "nimble:testutils"]

  test "with both Nims offered, the chosen one decides":
    for (pin, wantTestutils) in [("=2.2.4", false), ("=1.6.20", true)]:
      checkpoint pin
      let r = resolve(chroniclesIdiomPackages() & @[package("app-nim-pin",
        @[tagged("app-nim-pin", "1.0.0", nim = pin)])],
        @[("chronicles", ""), ("app-nim-pin", "")],
        nimVersions = @["1.6.20", "2.2.4"])
      checkpoint r.failure
      check r.failure == ""
      check r.chosen["nim"] == pin[1 .. ^1]
      check ("nimble:testutils" in r.chosen) == wantTestutils

  test "several candidates over a Nim range spanning both branches":
    # Each version of `x` requires `new` (which needs Nim >= 2.0) when its
    # condition holds and `old` (which needs Nim < 2.0) otherwise, so a solve
    # that took one branch's requirements with the other branch's Nim has no
    # solution. x 1.1.0 switches at 2.2, x 1.0.0 at 2.0: at Nim 2.0.16 the
    # newest `x` would need `old`, which Nim 2.0.16 rules out, so the solve
    # must fall back to x 1.0.0 and `new`.
    let at20 = "requires \"nim >= 1.6.0\"\n" &
      "when NimMajor >= 2:\n  requires \"new\"\nelse:\n  requires \"old\"\n"
    let at22 = "requires \"nim >= 1.6.0\"\n" &
      "when (NimMajor, NimMinor) >= (2, 2):\n  requires \"new\"\n" &
      "else:\n  requires \"old\"\n"
    let pkgs = @[package("x", @[recordFromNimble("x", "1.0.0", at20),
        recordFromNimble("x", "1.1.0", at22)]),
      package("new", @[tagged("new", "1.0.0", nim = ">= 2.0.0")]),
      package("old", @[tagged("old", "1.0.0", nim = "< 2.0.0")])]
    let nims = @["1.6.20", "2.0.16", "2.2.4"]
    for (pin, wantNim, wantX, wantNew) in [
        ("", "", "", false),
        ("=1.6.20", "1.6.20", "1.1.0", false),
        ("=2.0.16", "2.0.16", "1.0.0", true),
        ("=2.2.4", "2.2.4", "1.1.0", true)]:
      checkpoint "pin " & pin
      var all = pkgs
      var roots = @[("x", "")]
      if pin.len > 0:
        all.add package("app-nim-pin", @[tagged("app-nim-pin", "1.0.0",
          nim = pin)])
        roots.add ("app-nim-pin", "")
      let r = resolve(all, roots, nimVersions = nims)
      checkpoint r.failure
      check r.failure == ""
      # Whatever Nim the solve chose (unpinned: its own choice), the chosen
      # branch is the one that Nim decides, and the row's `depends` agrees.
      let x = r.chosen.getOrDefault("nimble:x")
      let nim = r.chosen.getOrDefault("nim")
      let takesNew = if x == "1.1.0": nim == "2.2.4" else: nim != "1.6.20"
      if wantNim.len > 0:
        check nim == wantNim
        check x == wantX
        check takesNew == wantNew
      check ("nimble:new" in r.chosen) == takesNew
      check ("nimble:old" in r.chosen) == not takesNew
      var rows = 0
      for c in chosenNimblePackages(r.input, r.chosen):
        if c.name == "x":
          inc rows
          check c.depends == @[if takesNew: "nimble:new" else: "nimble:old"]
      check rows == 1
    # When the branch the chosen Nim takes cannot be satisfied, the solve
    # fails: it never takes the other branch instead. Here no `new` admits
    # any offered Nim and `old` admits every Nim, so at a pinned 2.2.4 no
    # `x` can be chosen, and at a pinned 1.6.20 `old` is.
    let blocked = @[package("x", @[recordFromNimble("x", "1.0.0", at20),
        recordFromNimble("x", "1.1.0", at22)]),
      package("new", @[tagged("new", "1.0.0", nim = ">= 3.0.0")]),
      package("old", @[tagged("old", "1.0.0")])]
    for (pin, solvable) in [("=2.2.4", false), ("=1.6.20", true)]:
      checkpoint "blocked, pin " & pin
      let r = resolve(blocked & @[package("app-nim-pin", @[tagged(
        "app-nim-pin", "1.0.0", nim = pin)])],
        @[("x", ""), ("app-nim-pin", "")], nimVersions = nims)
      checkpoint r.failure
      check (r.failure == "") == solvable
      if solvable:
        check r.chosen["nimble:old"] == "1.0.0"
        check "nimble:new" notin r.chosen
      else:
        check "nimble:old" notin r.chosen

  test "a feature's requirement under the condition binds by the chosen Nim":
    # `lib[extra]` requires `old` before Nim 2.0 only; `top` names the
    # feature, so the feature's Nim gate decides it.
    let text = "requires \"nim >= 1.6.0\"\n" &
      "feature \"extra\":\n" &
      "  when (NimMajor, NimMinor) < (2, 0):\n" &
      "    requires \"old\"\n"
    let pkgs = @[package("lib", @[recordFromNimble("lib", "1.0.0", text)]),
      package("top", @[tagged("top", "1.0.0",
        @[req("lib", features = @["extra"])])]),
      package("old", @[record("old", "1.0.0")])]
    for (nim, wantOld) in [("2.2.4", false), ("1.6.20", true)]:
      checkpoint nim
      let r = resolve(pkgs, @[("top", "")], nimVersions = @[nim])
      checkpoint r.failure
      check r.failure == ""
      check r.chosen["nimble:lib"] == "1.0.0"
      check ("nimble:old" in r.chosen) == wantOld
      let chosen = chosenNimblePackages(r.input, r.chosen)
      for c in chosen:
        if c.name == "lib":
          check ("nimble:old" in c.depends) == wantOld
    # Without a declared `nim`, the named feature excludes the candidate.
    let none = resolve(pkgs, @[("top", "")])
    check none.failure != ""
    check "feature extra of 1.0.0 of lib" in none.failure
    check "declare `uses: nim`" in none.failure
