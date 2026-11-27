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
##    the convention emits one rustc edge per unit of cargo's plan and
##    nothing that runs cargo; built through the real engine and monitor,
##    every rlib each binary edge is given (its `--extern` files and the
##    rlibs in its `-L dependency=` directories) and every rlib in the
##    workspace is the declared output of one of those edges, each of which
##    ran in this build; the record run's scratch directory holds only the
##    empty placeholders it writes in place of compiling; and there is no
##    cargo `target` directory.
##
## Falsifying mutation (applied, observed to fail, reverted; see the
## change's report): adding Mode B's delegated cargo edge to the plan's
## fragment beside the rustc edges (cargo then builds its own rlibs in the
## workspace's `target` directory) fails the second half.
##
## MOCKS: none. See `rqe_cg5_mode_a_support` for the one step re-done here
## (turning an emitted `BuildActionDef` into an engine action).

import std/[os, sequtils, strutils, tempfiles, unittest]

import repro_build_engine
import repro_test_support/reasoned_skip
import repro_standard_provider/conventions/rust as rust_convention

import ./rqe_cg5_plan_fixture
import ./rqe_cg5_mode_a_support

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
    let env = prepareModeAEnv(work, "cg5-no-mixed")
    putEnv("REPRO_STORE_ROOT", reg.store)
    putEnv(ModeARegistrySwitch, "on")
    defer: delEnv(ModeARegistrySwitch)

    let fragment = emitWorkspace(ws)
    let defs = actionDefs(fragment)
    checkpoint "actions: " & defs.mapIt(it.id).join(" ")
    check defs.len == 5
    check defs.allIt(it.id.startsWith("cargo.rustc/"))
    let run = buildFragment(env, fragment, ws, work / "engine-cache")
    var ran: seq[string]
    for r in run.results:
      checkpoint r.id & ": " & $r.status & " " & r.reason &
        (if r.stderr.len > 0: "\nstderr: " & r.stderr else: "")
      check r.status == asSucceeded
      if r.status == asSucceeded: ran.add r.id
    check ran.len == defs.len

    let p = rlibProvenance(fragment, ws)
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
      for def in defs:
        if path in def.outputs: owner = def.id
      check owner in ran
    check p.scratchCompiled.len == 0
    check not dirExists(ws / "target")
