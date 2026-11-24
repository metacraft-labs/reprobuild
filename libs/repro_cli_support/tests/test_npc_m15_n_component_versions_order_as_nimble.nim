## Verification `test_npc_m15_n_component_versions_order_as_nimble`
## (NPC-AREQ5, NPC-AREQ6 "Versions with any number of components", § 4.4
## "Version field"): a Nimble version has as many components as its tag,
## and the solve, the lock and `repro lock diff` order versions as Nimble
## 0.20.1 does.
##
## 1. A table of version pairs that differ in length and in trailing zeros
##    is compared, and each answer of `<` and `==` equals Nimble's own. The
##    expected answers (`fixtures/npc_m15_nimble_version_order/
##    nimble_answers.tsv`) were printed by `nim e` of
##    `nimble_answers.nims`, which imports `nimblepkg/version` from Nimble
##    0.20.1, tag `v0.20.1` = commit `9207e8b2bbdf66b5a4d1020214cff44d2d30df92`.
##    They are checked against the solver's Nimble order and against its
##    range admission (`<` and `==` ranges, ``rangeAdmits`` with
##    ``vsNimble``).
## 2. A package with tags `v0.6.0.3.0`, `v0.6.0.3.1` and `v0.7.0.8.0` is
##    solved under requirements read by the static reader: `>= 0.6.0.3.1`
##    chooses 0.7.0.8.0, `--lowest` 0.6.0.3.1, `~= 0.6.0.3.1` (bound
##    `< 0.6.0.4.0`) 0.6.0.3.1 and `^= 0.6.0.3.1` (bound `< 0.7.0.0.0`)
##    0.6.0.3.1. No candidate is excluded as `version-shape`, and each
##    requirement reads without an error (so its `.nimble` is not
##    needs-override).
## 3. Through the lock verbs: the lock row spells every component
##    (`0.6.0.3.1`), and `repro lock diff` of a refresh to 0.7.0.8.0 orders
##    the move as an upgrade.
##
## Falsifying mutation (recorded in the plan): comparing only the first
## three components makes `0.6.0.3.0` and `0.6.0.3.1` one solver version
## (`equal-version`), and fails the test.

import std/[os, sequtils, strutils, tables, unittest]

import repro_nimble_index
import repro_nimble_reader
import repro_solver/[nimble_versions, version_encoder]

import ./nimble_m6_fixtures
import ../../repro_nimble_index/tests/resolution_fixtures

const AnswersFile = currentSourcePath().parentDir / "fixtures" /
  "npc_m15_nimble_version_order" / "nimble_answers.tsv"

proc readRange(text: string): string =
  ## The normalized range of `secp <text>` as the static reader reads it;
  ## a reading error fails the test (it would make the `.nimble`
  ## needs-override).
  let r = readRequirements("secp " & text)
  check r.errors.len == 0
  check r.requirements.len == 1
  check r.requirements[0].version.kind == vkRange
  r.requirements[0].version.normalized

proc secpTags(): PackageEnvelope =
  package("secp", @[tagged("secp", "v0.6.0.3.0"),
    tagged("secp", "v0.6.0.3.1"), tagged("secp", "v0.7.0.8.0")])

proc topRequiring(range: string): PackageEnvelope =
  package("top", @[tagged("top", "1.0.0", @[req("secp", range)])])

suite "NPC-M15: versions with any number of components order as Nimble":
  test "each `<` and `==` answer equals Nimble 0.20.1's":
    var rows = 0
    for line in readFile(AnswersFile).splitLines():
      if line.strip.len == 0: continue
      let f = line.split('\t')
      check f.len == 5
      let (a, b) = (f[0], f[1])
      let lt = f[2] == "true"
      let eq = f[3] == "true"
      let gt = f[4] == "true"
      checkpoint a & " vs " & b
      let c = cmpNimbleText(a, b)
      check (c < 0) == lt
      check (c == 0) == eq
      check (c > 0) == gt
      # The solve's range admission answers the same.
      check rangeAdmits("<" & b, a, vsNimble) == lt
      check rangeAdmits("==" & b, a, vsNimble) == eq
      check rangeAdmits(">" & b, a, vsNimble) == gt
      inc rows
    check rows == 12

  test "the solve orders and bounds the components as Nimble does":
    let atLeast = readRange(">= 0.6.0.3.1")
    check atLeast == ">= 0.6.0.3.1"
    let tilde = readRange("~= 0.6.0.3.1")
    check tilde == ">= 0.6.0.3.1, < 0.6.0.4"
    let caret = readRange("^= 0.6.0.3.1")
    check caret == ">= 0.6.0.3.1, < 0.7.0"

    let r = resolve(@[secpTags(), topRequiring(atLeast)], @[("top", "")])
    checkpoint r.failure
    check r.failure == ""
    check r.chosen.getOrDefault("nimble:secp") == "0.7.0.8.0"
    # Every tag is a candidate in its own right: none is excluded for its
    # shape, and 0.6.0.3.0 is not the same version as 0.6.0.3.1.
    let secp = r.input.packages[r.input.packageOf("secp")]
    check secp.candidates.mapIt(it.version) ==
      @["0.6.0.3.0", "0.6.0.3.1", "0.7.0.8.0"]
    for c in secp.candidates:
      checkpoint c.version & " " & $c.exclusions
      check c.offered

    let lowest = resolve(@[secpTags(), topRequiring(atLeast)], @[("top", "")],
      preference = vpLowest)
    checkpoint lowest.failure
    check lowest.chosen.getOrDefault("nimble:secp") == "0.6.0.3.1"

    let t = resolve(@[secpTags(), topRequiring(tilde)], @[("top", "")])
    checkpoint t.failure
    check t.chosen.getOrDefault("nimble:secp") == "0.6.0.3.1"

    let c = resolve(@[secpTags(), topRequiring(caret)], @[("top", "")])
    checkpoint c.failure
    check c.chosen.getOrDefault("nimble:secp") == "0.6.0.3.1"

  test "the lock spells every component and the diff orders the move":
    var w = newWorld("ncomp")
    discard w.publish(@[package("secp", @[tagged("secp", "v0.6.0.3.0"),
      tagged("secp", "v0.6.0.3.1")]), topRequiring(readRange(">= 0.6.0.3.1"))],
      daysAgo(3), "generation 1")
    let dir = w.newProject(@[("top", "")])
    let first = refreshProvisioning(dir)
    checkpoint first.output
    check first.rc == 0
    check nimbleRows(dir)["nimble:secp"].version == "0.6.0.3.1"
    let before = dir / "before.lock"
    copyFile(dir / "repro.lock", before)
    discard w.publish(@[secpTags(), topRequiring(readRange(">= 0.6.0.3.1"))],
      daysAgo(1), "generation 2")
    let moved = refreshProvisioning(dir)
    checkpoint moved.output
    check moved.rc == 0
    check nimbleRows(dir)["nimble:secp"].version == "0.7.0.8.0"
    let diff = lockDiff(before, dir / "repro.lock")
    checkpoint diff.output
    check "~ nimble:secp: version 0.6.0.3.1 -> 0.7.0.8.0 (upgrade)" in
      diff.output
    # And back: the same comparison calls it a downgrade.
    let back = lockDiff(dir / "repro.lock", before)
    checkpoint back.output
    check "~ nimble:secp: version 0.7.0.8.0 -> 0.6.0.3.1 (downgrade)" in
      back.output
