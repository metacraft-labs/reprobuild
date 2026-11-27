## Graph production for a crates.io workspace (the registry lift, switch on):
## concurrent runs do not share state, and each way it cannot complete sends
## the whole workspace to Mode B, with its reason.
##
## THE CASES.
##
## 1. Two plans of one workspace at once. Each record run has a directory of
##    its own (scratch, capture files, temporary directory, plan) under
##    `.repro/build/cargo-plan`, removed when it is done, so two evaluations
##    at once (two `repro` processes over one checkout) never empty each
##    other's state. The case forks: the child and the parent each call
##    `planWorkspace` at the same moment; both must succeed with the same
##    edges, and no run directory may be left behind.
## 2. A git dependency. A member depends on a git source as well as on a
##    crates.io crate: the decision is Mode B before anything runs, naming
##    item 6 and the git source class, and the fragment is Mode B's.
## 3. No record wrapper. `REPRO_RUSTC_WRAPPER_PATH` names a file that does
##    not exist: graph production stops before the record run, the fragment
##    is Mode B's, and it carries an input that is never fresh, naming the
##    reason, so the next evaluation tries again.
## 4. A refused plan. A member depends on the crates.io crate `regbs`, which
##    has a build script: the plan holds a build-script compile and run,
##    which these edges do not build, so `planWorkspace` refuses it naming
##    them, and the fragment is Mode B's, keyed on what the record run read.
##
## Falsifying mutations (applied, observed to fail, reverted; see the
## change's report): one fixed record-run directory, emptied before each run
## as before, fails case 1; taking every dependency source for crates.io
## fails case 2; raising instead of falling back to Mode B fails cases 3
## and 4.
##
## MOCKS: none. Real cargo, rustc, the record wrapper, the io monitor and the
## fetch wave over a local mirror; nothing contacts the network.

import std/[os, posix, sequtils, strutils, tempfiles, unittest]

import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/conventions/rust as rust_convention
import repro_standard_provider/conventions/rust_plan_mode

import ./rqe_cg5_plan_fixture
import ./rqe_cg5_mode_a_support

proc tools(): PlanToolchain =
  PlanToolchain(cargo: findExe("cargo"), rustc: findExe("rustc"),
    cc: findExe("cc"))

proc edgeIds(g: PlanGraph): string =
  ## The edges' ids (a loop: `PlanUnitEdge` has no default value, which
  ## `mapIt` needs).
  var ids: seq[string]
  for e in g.edges: ids.add e.action.id
  ids.join(" ")

proc isModeB(fragment: GraphFragment): bool =
  let defs = actionDefs(fragment)
  defs.anyIt(it.runsCargo) and not defs.anyIt(it.isPlanEdge)

suite "the registry lift's graph production":

  test "two plans of one workspace at once keep their own state":
    let work = createTempDir("cg5-gp-concurrent-", "")
    defer: removeTestTree(work)
    let ws = work / "ws"
    writeRegistryWorkspace(ws)
    let reg = setupRegistry(work, smReal, withRegmid = true)
    lockWorkspace(ws, work, reg)
    discard prepareModeAEnv(work, "cg5-gp-concurrent")
    putEnv("REPRO_STORE_ROOT", reg.store)
    # Fetch once first, so the two runs below contend for the record run's
    # directories, not for the fetch wave's first store write.
    require planWorkspace(ws, tools()).ok
    let childReport = work / "child-report"
    let pid = fork()
    require pid >= 0
    if pid == 0:
      let g = planWorkspace(ws, tools())
      writeFile(childReport, (if g.ok: "ok\n" else: "failed\n") & g.reason &
        "\n" & edgeIds(g))
      exitnow(if g.ok: 0 else: 1)
    let mine = planWorkspace(ws, tools())
    var status: cint
    discard waitpid(pid, status, 0)
    checkpoint "parent: " & mine.reason
    checkpoint "child: " & (if fileExists(childReport): readFile(childReport)
                            else: "<no report>")
    check mine.ok
    check WIFEXITED(status) and WEXITSTATUS(status) == 0
    check readFile(childReport).splitLines()[2] == edgeIds(mine)
    var left: seq[string]
    for kind, path in walkDir(ws / PlanDirRel):
      if extractFilename(path).startsWith("run-"): left.add path
    checkpoint "left: " & left.join(" ")
    check left.len == 0
    check fileExists(ws / PlanFileRel)

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
    let g = planWorkspace(ws, tools())
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

  test "a plan holding a registry build script is refused as a whole":
    let work = createTempDir("cg5-gp-refused-", "")
    defer: removeTestTree(work)
    let ws = work / "ws"
    writeRegistryWorkspace(ws)
    writeFileIn(ws, "util/Cargo.toml",
      "[package]\nname = \"util\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" &
      "\n[dependencies]\nregleaf = \"0.1.0\"\nregbs = \"0.1.0\"\n")
    let reg = setupRegistry(work, smReal, withRegmid = true)
    lockWorkspace(ws, work, reg)
    discard prepareModeAEnv(work, "cg5-gp-refused")
    putEnv("REPRO_STORE_ROOT", reg.store)
    putEnv(ModeARegistrySwitch, "on")
    defer: delEnv(ModeARegistrySwitch)
    check rustModeDecision(ws).kind == rmkPlan
    let g = planWorkspace(ws, tools())
    checkpoint g.reason
    check not g.ok
    check g.edges.len == 0
    check "regbs" in g.reason and "build script" in g.reason
    check g.observed.files.len > 0
    let fragment = emitWorkspace(ws)
    check fragment.isModeB
    check switchInputDigest(fragment) != "<absent>"
    check fragment.evaluationInputs.anyIt(
      it.identity.endsWith("/Cargo.lock"))
