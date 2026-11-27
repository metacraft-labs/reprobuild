## A workspace is built either wholly by Reprobuild's rustc edges or wholly
## by cargo: rlibs cargo built are never linked beside rlibs Reprobuild
## built.
##
## THE CONTRACT. The Rust convention decides per workspace. A workspace whose
## crates the plan's edges can all build is built by them alone, and one with
## a crate they cannot build goes to Mode B as a whole: there is no per-crate
## fallback, in which the offending crate would be built by cargo and linked
## into binaries beside Reprobuild-built rlibs.
##
## TWO HALVES.
##
## 1. A workspace with one crate the edges cannot build (a build script that
##    prints a directive the interpreter does not model) builds wholly in
##    Mode B: no rlib of the build comes from a Reprobuild rustc edge. That
##    needs the build-script edges, the refusal at execution and the
##    workspace's fallback within one build, none of which exists yet, so the
##    case is skipped with that reason until the change that implements the
##    fallback (the per-workspace decision at execution) fills it in.
## 2. The same workspace without that crate (`writeRegistryWorkspace`:
##    members `app` and `util`, and the crates.io crates `regleaf` and
##    `regmid`) builds with no cargo-built rlib. With the registry lift on,
##    `repro build` creates one rustc edge per unit of cargo's plan (the
##    units edge's fragment) and nothing that runs cargo; every rlib each
##    binary edge is given (its `--extern` files and the
##    rlibs in its `-L dependency=` directories) and every rlib in the
##    workspace is the declared output of one of those edges, each of which
##    ran in this build; no record run's directory is left with a compiled
##    rlib; and there is no cargo `target` directory. (The fragment's `test`
##    target is Mode B's `cargo test`, outside the default target built
##    here.)
##
## Falsifying mutation (applied, observed to fail, reverted; see the
## change's report): the units edge writing Mode B's delegated cargo edge
## beside the rustc edges (cargo then builds its own rlibs in the
## workspace's `target` directory) fails the second half.
##
## MOCKS: none. The real CLI, engine and monitor, cargo and rustc.

import std/[json, os, sequtils, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip

import ./rqe_cg5_plan_fixture
import ./rqe_cg5_mode_a_support
import ./rqe_cg5_repro_build_support

suite "no mixed rlibs":

  test "test_rqe_cg5_no_mixed_rlibs: a workspace with a crate the edges " &
      "cannot build builds wholly in Mode B":
    skip("the per-workspace fallback at execution (a build-script refusal " &
      "sending the whole workspace to Mode B within one build) is not " &
      "implemented yet; this half is filled in by the change that adds it, " &
      "after the build-script compile and run edges")

  test "test_rqe_cg5_no_mixed_rlibs: the workspace without the offending " &
      "crate builds with no cargo-built rlib":
    let work = createTempDir("cg5-no-mixed-", "")
    defer: removeTestTree(work)
    let ws = work / "ws"
    writeRegistryWorkspace(ws)
    let reg = setupRegistry(work, smReal, withRegmid = true)
    lockWorkspace(ws, work, reg)
    let built = reproBuild(reproBuildEnv(work, reg), ws)
    checkpoint built.describe
    require built.code == 0
    let units = unitRecords(ws)
    checkpoint "units: " & units.mapIt(it.id).join(" ")
    check units.len == 5
    check units.allIt(it.id.startsWith("cargo.rustc/"))
    var ran: seq[string]
    for u in units:
      let r = built.action(u.id)
      checkpoint u.id & ": " & r{"status"}.getStr()
      check r{"status"}.getStr() == "asSucceeded"
      if r{"launched"}.getBool(): ran.add u.id
    check ran.len == units.len
    check built.idsWithPrefix("crude-build-").len == 0

    let p = rlibProvenance(units, ws)
    checkpoint "edge rlibs: " & p.edgeOutputs.join(" ")
    checkpoint "linked: " & p.linked.join(" ")
    checkpoint "foreign: " & p.foreign.join(" ")
    check p.cargoEdges.len == 0
    # `app` links `util`, `regmid` and `regleaf`; `util`'s binary links
    # `util` and `regleaf`.
    check p.linked.len == 3
    check p.foreign.len == 0
    for path in p.linked:
      checkpoint path
      check fileExists(path) and getFileSize(path) > 0
      var owner = ""
      for u in units:
        if path in u.outputs: owner = u.id
      check owner in ran
    check p.scratchCompiled.len == 0
    check not dirExists(ws / "target")
