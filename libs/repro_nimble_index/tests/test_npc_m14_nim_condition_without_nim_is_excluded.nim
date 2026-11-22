## NPC-M14 verification `test_npc_m14_nim_condition_without_nim_is_excluded`
## (A3; NPC-AREQ7).
##
## A solve with no `nim` toolchain package cannot decide a Nim-version
## condition, so it excludes a candidate with an active requirement under
## one as `nim-version-unknown`. The failure names the record, the condition
## and the remedy (declare `uses: nim`). No candidate is offered with the
## condition taken as false (the `else` branch's `testutils`) or as true (no
## `testutils`). A candidate without such a condition stays offered, and a
## condition the platform alone decides (`defined(windows) and NimMajor >= 2`
## on Linux) excludes nothing.
##
## Falsifying mutation (recorded in the plan): treating an undecided
## Nim-version term as false offers the candidate with the `else` branch's
## requirements, and fails the test.

import std/[strutils, tables, unittest]

import repro_nimble_index
import repro_nimble_reader

import ./resolution_fixtures
import ./m14_fixtures

suite "NPC-M14: without a declared nim, a Nim-version condition excludes":
  test "the candidate is excluded as nim-version-unknown, naming the remedy":
    let r = resolve(chroniclesIdiomPackages(), @[("chronicles", "")])
    check r.failure != ""
    check r.chosen.len == 0
    let pi = r.input.packageOf("chronicles")
    require pi >= 0
    let c = r.input.packages[pi].candidates[0]
    check not c.offered
    require c.exclusions.len == 1
    check c.exclusions[0].kind == exNimVersionUnknown
    # The failure: the record, the condition and the remedy.
    checkpoint r.failure
    check "nimble:chronicles: 0 candidate(s) offered" in r.failure
    check "0.11.0 -- nim-version-unknown" in r.failure
    check "`testutils` when `not (NimMajor >= 2)`" in r.failure
    check "declare `uses: nim`" in r.failure

  test "neither branch is offered in its place":
    # Not as false: no candidate requires testutils; not as true: no
    # candidate is offered without it.
    let r = resolve(chroniclesIdiomPackages(), @[("chronicles", "")])
    let pi = r.input.packageOf("chronicles")
    require pi >= 0
    for c in r.input.packages[pi].candidates:
      check not c.offered
    check "nimble:testutils" notin r.chosen
    check "nimble:chronicles" notin r.chosen

  test "a candidate without the condition is still chosen":
    var pkgs = chroniclesIdiomPackages()
    pkgs[0].versions.insert(record("chronicles", "v0.10.3",
      @[req("json_serialization")]), 0)
    let r = resolve(pkgs, @[("chronicles", "")])
    checkpoint r.failure
    check r.failure == ""
    check r.chosen["nimble:chronicles"] == "0.10.3"
    check "nimble:testutils" notin r.chosen

  test "a condition the platform decides excludes nothing":
    let text = "requires \"json_serialization\"\n" &
      "when defined(windows) and NimMajor >= 2:\n" &
      "  requires \"testutils\"\n"
    let pkgs = @[package("lib", @[recordFromNimble("lib", "1.0.0", text)]),
      package("json_serialization", @[record("json_serialization", "1.0.0")]),
      package("testutils", @[record("testutils", "1.0.0")])]
    let onLinux = resolve(pkgs, @[("lib", "")])
    checkpoint onLinux.failure
    check onLinux.failure == ""
    check onLinux.chosen["nimble:lib"] == "1.0.0"
    check "nimble:testutils" notin onLinux.chosen
