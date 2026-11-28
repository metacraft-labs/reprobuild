## The Rust convention's registry lift is gated: only
## `REPRO_CARGO_MODE_A_REGISTRY=on` brings a workspace with crates.io
## dependencies into Mode A, and the switch is part of the decision's key.
##
## THE CONTRACT. Rust.md § Recognition item 6 keeps a workspace with a
## registry dependency out of Mode A. The lift of that condition for
## crates.io crates builds such a workspace from cargo's plan instead: its
## graph-production edges fetch each crate into the store, plan the build
## without compiling, and turn every library and binary unit, members and
## registry crates alike, into a rustc edge while the build runs. Until the check of the
## variables a compile reads exists, the lift is behind a switch that is off
## by default and that only the exact value `on` turns on. The convention
## reads it where it decides the workspace's mode, and records it as an
## evaluation input of the fragment it emits (an environment host fact,
## keyed by a digest of its value), so turning it on or off re-decides.
##
## THE FIXTURE (`writeRegistryWorkspace`): members `app` and `util` with no
## feature, build script or proc-macro, depending on the crates.io crates
## `regleaf` and `regmid` (`regmid` depends on `regleaf` and has default
## features). The crates are made by `cargo package` and fetched from a
## local mirror directory into a private store root, which the workspace's
## fetch edges then find them in; nothing contacts the network.
##
## THE CASES, one workspace, in order:
##
## 1. Switch unset. The decision is Mode B and its reason names item 6's
##    registry condition and the switch. The fragment is Mode B's: one
##    action, which runs cargo; no rustc edge; no record run (no plan file).
##    It records the switch, with the digest of an unset variable.
## 2. Switch `On` (not the exact value). The same: Mode B. Its recorded
##    digest differs from case 1's, so the change re-decides the workspace.
## 3. Switch `on`. The decision is Mode A from the plan. The fragment holds
##    the graph-production edges (a fetch edge per locked crate, the plan
##    edge, the Mode B record, the units edge and the collector) and no
##    rustc edge, and the switch is recorded with a third digest. Built with
##    `repro build`, the units edge creates one rustc edge per unit (five:
##    `app`, `util`'s library and binary, `regleaf`, `regmid`), none runs
##    cargo, each is launched from its declared environment alone, every
##    one succeeds, the binaries print `util:5 51` and `util:5`, and no
##    rlib of the build comes from cargo: every rlib a binary is given, and
##    every rlib in the workspace, is the output of one of these edges; the
##    record run's scratch holds only empty placeholders; there is no
##    `target` directory.
##
## Case 3's build runs in an environment that exports `RUSTFLAGS`,
## `CARGO_BUILD_RUSTFLAGS`, `CARGO_ENCODED_RUSTFLAGS`,
## `CARGO_PROFILE_RELEASE_OPT_LEVEL` and `CARGO_TARGET_DIR`: the plan edge's
## environment is closed, so none of them reaches a unit's command line,
## and the toolchain the edges are made with is keyed (the `PATH` it was
## resolved on and each tool's content).
## The fragment's `test` target is Mode B's (`cargo test`), outside the
## default target.
##
## Falsifying mutations (applied, observed to fail, reverted; see the
## change's report): accepting any non-empty switch value fails case 2;
## declaring the plan edge without `isolateHostEnvironment` fails case 3's
## steering check; leaving the toolchain out of the evaluation inputs fails
## case 3's keying check;
## dropping the switch from a Mode B fragment's evaluation inputs fails
## cases 1 and 2; dropping the registry condition (routing the workspace to
## the plan whatever the switch) fails case 1; dropping
## `isolateHostEnvironment` from the `create-action` record fails case 3.
##
## MOCKS: none. The real emitter, CLI, engine and monitor, cargo and rustc.

import std/[json, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_build_engine
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/conventions/rust as rust_convention
import repro_standard_provider/conventions/rust_plan_mode

import ./rqe_cg5_plan_fixture
import ./rqe_cg5_mode_a_support
import ./rqe_cg5_repro_build_support

suite "the registry lift's gate":

  test "test_rqe_cg5_registry_lift_is_gated: off keeps a crates.io " &
      "workspace in Mode B naming item 6; on builds it in Mode A with no " &
      "cargo-built rlib":
    let work = createTempDir("cg5-gate-", "")
    defer: removeTestTree(work)
    let ws = work / "ws"
    writeRegistryWorkspace(ws)
    let reg = setupRegistry(work, smReal, withRegmid = true)
    lockWorkspace(ws, work, reg)
    let env = prepareModeAEnv(work, "cg5-gate")
    putEnv("REPRO_STORE_ROOT", reg.store)
    let switchId = EnvironmentHostFactPrefix & ModeARegistrySwitch

    # 1. Unset.
    delEnv(ModeARegistrySwitch)
    let off = rustModeDecision(ws)
    checkpoint off.reason
    check off.kind == rmkModeB
    check off.readSwitch
    check "item 6" in off.reason and "registry condition" in off.reason
    check ModeARegistrySwitch in off.reason
    let offFragment = emitWorkspace(ws)
    let offDefs = actionDefs(offFragment)
    check offDefs.anyIt(it.runsCargo)
    check not offDefs.anyIt(it.id.startsWith("cargo.rustc/"))
    check not fileExists(ws / PlanFileRel)
    let offDigest = switchInputDigest(offFragment)
    check offDigest == hostFactDigest(switchId)
    check offDigest != "<absent>"

    # 2. A value other than exactly `on`.
    putEnv(ModeARegistrySwitch, "On")
    check rustModeDecision(ws).kind == rmkModeB
    let wrongFragment = emitWorkspace(ws)
    check actionDefs(wrongFragment).anyIt(it.runsCargo)
    check not actionDefs(wrongFragment).anyIt(
      it.id.startsWith("cargo.rustc/"))
    let wrongDigest = switchInputDigest(wrongFragment)
    check wrongDigest == hostFactDigest(switchId)
    check wrongDigest notin [offDigest, "<absent>"]

    # 3. On, in a process that exports variables which would steer cargo.
    putEnv(ModeARegistrySwitch, "on")
    exportCargoSteering()
    let on = rustModeDecision(ws)
    check on.kind == rmkPlan
    check on.reason.len == 0
    let onFragment = emitWorkspace(ws)
    let allDefs = actionDefs(onFragment)
    # Graph production is edges: the fetch edge of each locked crate, the
    # plan edge, the Mode B record, the units edge and the collector. No
    # unit edge exists until the build runs.
    let production = allDefs.filterIt(it.isGraphProductionEdge)
    var ids = production.mapIt(it.id)
    checkpoint "graph production: " & ids.join(" ")
    check ids.filterIt(it.startsWith("cargo.fetch/")).len == 2  # regleaf, regmid: the fixture's regbs is not locked
    for prefix in ["cargo.plan/", "cargo.mode-b-record/", "cargo.plan-units/",
                   "cargo.workspace/"]:
      check ids.filterIt(it.startsWith(prefix)).len == 1
    check not allDefs.anyIt(it.isPlanEdge)
    # The `test` target stays Mode B's: cargo runs the tests, outside the
    # default target.
    let others = allDefs.filterIt(not it.isGraphProductionEdge)
    checkpoint "other actions: " & others.mapIt(it.id).join(" ")
    check others.len == 2
    check others.anyIt(it.runsCargo and "test" in inlineArgvOf(it))
    # The toolchain the edges are made with is keyed: the PATH it was
    # resolved on and each tool's content.
    let keyed = onFragment.evaluationInputs.mapIt(it.identity)
    check (EnvironmentHostFactPrefix & "PATH") in keyed
    for tool in ["cargo", "rustc"]:
      checkpoint tool
      check keyed.anyIt(it.isAbsolute and extractFilename(it) == tool)
    let onDigest = switchInputDigest(onFragment)
    check onDigest == hostFactDigest(switchId)
    check onDigest notin [offDigest, wrongDigest, "<absent>"]

    # Built with `repro build`, from a shell that exports the steering
    # variables: the plan's unit edges are created and run.
    var benv = reproBuildEnv(work / "build", reg)
    benv.vars.add cargoSteering()
    let built = reproBuild(benv, ws)
    checkpoint built.describe
    require built.code == 0
    let units = unitRecords(ws)
    let unitIds = units.mapIt(it.id)
    checkpoint "units: " & unitIds.join(" ")
    check unitIds.len == 5
    check unitIds.allIt(it.startsWith("cargo.rustc/"))
    for name in ["app@0.1.0-", "util@0.1.0-", "regleaf@0.1.0-",
                 "regmid@0.1.0-"]:
      check unitIds.anyIt(("cargo.rustc/" & name) in it)
    for id in unitIds:
      checkpoint id
      check built.action(id){"status"}.getStr() == "asSucceeded"
    # Nothing the host exported reached a unit: the plan edge's environment
    # is closed.
    let steered = steeredUnits(units.mapIt(it.argv))
    checkpoint "steered: " & steered.join(" | ")
    check steered.len == 0
    for u in units:
      checkpoint u.id
      check u.isolateHostEnvironment
      check u.env.filterIt(it.startsWith("PATH=")).len == 1
    for (crate, expected) in [("app", "util:5 51"), ("util", "util:5")]:
      var bin = ""
      for u in units:
        if "bin" in u.argv and ("cargo.rustc/" & crate & "@") in u.id:
          for o in u.outputs:
            if extractFilename(o).startsWith(crate & "-") and
                not o.endsWith(".rlib"):
              bin = o
      checkpoint crate & ": " & bin
      require bin.len > 0
      check execProcess(bin, options = {}).strip() == expected

    let p = rlibProvenance(units, ws)
    checkpoint "linked: " & p.linked.join(" ")
    checkpoint "foreign: " & p.foreign.join(" ")
    check p.cargoEdges.len == 0
    check p.linked.len >= 3
    check p.foreign.len == 0
    check p.scratchCompiled.len == 0
    check not dirExists(ws / "target")
