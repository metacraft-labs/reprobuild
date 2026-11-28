## Graph production for a crates.io workspace (the registry lift, switch on)
## is the declaration of edges: evaluating the workspace runs nothing, and
## what evaluation alone can tell sends the whole workspace to Mode B, with
## its reason.
##
## THE CASES.
##
## 1. Evaluation runs nothing. The fragment of a crates.io workspace holds its
##    graph-production edges (the fetch edges, the plan edge, the Mode B
##    record, the units edge, the collector) and no unit; nothing is
##    written under the workspace's `.repro/build/cargo-plan`, and the
##    fragment is keyed on `Cargo.lock`, from which the fetch edges come.
##    (A plan the units edge refuses at execution falls back to Mode B
##    there: `test_rqe_cg5_refused_plan_builds_through_mode_b`.)
## 2. A git dependency. A member depends on a git source as well as on a
##    crates.io crate: the decision is Mode B before anything runs, naming
##    item 6 and the git source class, and the fragment is Mode B's.
## 3. No record wrapper. `REPRO_RUSTC_WRAPPER_PATH` names a file that does
##    not exist: no plan edge can be declared, the fragment is Mode B's, and
##    it carries an input that is never fresh, naming the reason, so the
##    next evaluation tries again.
##
## Falsifying mutations (applied, observed to fail, reverted; see the
## change's report): running the record run at evaluation (the inline form
## this replaced) writes under `.repro/build/cargo-plan` and fails case 1;
## taking every dependency source for crates.io fails case 2; leaving out
## the never-fresh input fails case 3.
##
## MOCKS: none. Real cargo metadata and the real emitter; nothing contacts
## the network.

import std/[os, sequtils, strutils, tempfiles, unittest]

import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/conventions/rust as rust_convention
import repro_standard_provider/conventions/rust_plan_mode

import ./rqe_cg5_plan_fixture
import ./rqe_cg5_mode_a_support

proc tools(): PlanToolchain =
  PlanToolchain(cargo: findExe("cargo"), rustc: findExe("rustc"),
    cc: findExe("cc"))

proc isModeB(fragment: GraphFragment): bool =
  let defs = actionDefs(fragment)
  defs.anyIt(it.runsCargo) and not defs.anyIt(it.isGraphProductionEdge)

suite "the registry lift's graph production":

  test "evaluation declares the graph-production edges and runs nothing":
    let work = createTempDir("cg5-gp-edges-", "")
    defer: removeTestTree(work)
    let ws = work / "ws"
    writeRegistryWorkspace(ws)
    let reg = setupRegistry(work, smReal, withRegmid = true)
    lockWorkspace(ws, work, reg)
    discard prepareModeAEnv(work, "cg5-gp-edges")
    putEnv("REPRO_STORE_ROOT", reg.store)
    putEnv(ModeARegistrySwitch, "on")
    defer: delEnv(ModeARegistrySwitch)
    let fragment = emitWorkspace(ws)
    let defs = actionDefs(fragment)
    checkpoint defs.mapIt(it.id).join(" ")
    check defs.filterIt(it.id.startsWith("cargo.fetch/")).len == 2  # regleaf, regmid: the fixture's regbs is not locked
    check defs.filterIt(it.id.startsWith("cargo.plan/")).len == 1
    check defs.filterIt(it.id.startsWith("cargo.workspace/")).len == 1
    check not defs.anyIt(it.isPlanEdge)
    check not dirExists(ws / PlanDirRel)
    check fragment.evaluationInputs.anyIt(
      it.identity.endsWith("/Cargo.lock"))
    check switchInputDigest(fragment) != "<absent>"

  test "a git dependency keeps the workspace in Mode B, naming it":
    let work = createTempDir("cg5-gp-git-", "")
    defer: removeTestTree(work)
    let ws = work / "ws"
    writeRegistryWorkspace(ws)
    writeFileIn(ws, "util/Cargo.toml",
      "[package]\nname = \"util\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" &
      "\n[dependencies]\nregleaf = \"0.1.0\"\n" &
      "gitdep = { git = \"https://example.invalid/gitdep.git\" }\n")
    discard prepareModeAEnv(work, "cg5-gp-git")
    putEnv(ModeARegistrySwitch, "on")
    defer: delEnv(ModeARegistrySwitch)
    let d = rustModeDecision(ws)
    checkpoint d.reason
    check d.kind == rmkModeB
    check "item 6" in d.reason and "git" in d.reason
    check emitWorkspace(ws).isModeB
    check not dirExists(ws / PlanDirRel)

  test "no record wrapper sends the workspace to Mode B, retried next time":
    let work = createTempDir("cg5-gp-wrapper-", "")
    defer: removeTestTree(work)
    let ws = work / "ws"
    writeRegistryWorkspace(ws)
    let reg = setupRegistry(work, smReal, withRegmid = true)
    lockWorkspace(ws, work, reg)
    discard prepareModeAEnv(work, "cg5-gp-wrapper")
    putEnv("REPRO_STORE_ROOT", reg.store)
    putEnv("REPRO_RUSTC_WRAPPER_PATH", work / "no-such-wrapper")
    putEnv(ModeARegistrySwitch, "on")
    defer: delEnv(ModeARegistrySwitch)
    check rustModeDecision(ws).kind == rmkPlan
    let g = planWorkspace(ws, tools(), getAppFilename())
    checkpoint g.reason
    check not g.ok
    check "record wrapper" in g.reason
    let fragment = emitWorkspace(ws)
    check fragment.isModeB
    let unobserved = fragment.evaluationInputs.filterIt(
      it.digest == UnobservedEvaluationDigest)
    checkpoint unobserved.mapIt(it.identity).join(" | ")
    check unobserved.anyIt("record wrapper" in it.identity)
    check switchInputDigest(fragment) != "<absent>"
