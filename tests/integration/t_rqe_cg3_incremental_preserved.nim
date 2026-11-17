## Reprobuild's delegated cargo edge keeps cargo's incremental state.
##
## THE CONTRACT. cargo's target directory is a TOOL-OWNED CACHE
## (Tool-Owned-Caches.md): cargo writes it for its own
## reuse and reads it back on the next run. The edge therefore declares what
## cargo answers about the build (its final products, discovered from
## `--message-format=json`) and nothing of the target directory, so the engine
## neither records nor clears it. Editing one crate then recompiles that crate
## and nothing else. Declaring the build directory OPAQUE (an output the
## engine removes before every run, BuildXL's exclusive opaque directory)
## clears cargo's state, and every unit is recompiled.
##
## HOW IT IS OBSERVED. A real `repro build` of a project with a build script
## (which sends it to the delegated cargo edge), under a real `runquotad`, with
## a logging `RUSTC_WRAPPER` that records each unit rustc is asked to compile.
##
##   * Build 1 compiles all five units (three libraries, the build script, the
##     binary).
##   * After an edit to the binary's source (nothing depends on it), build 2
##     compiles exactly one unit, `cg3_app`, and the binary shows the edit.
##   * The final product is declared by discovery: the edge's one output is a
##     file listing the executable cargo reported, and that file is the same
##     after the edit.
##   * Falsifying control: the same cargo command as an inline edge whose
##     target directory is declared opaque (an output, and removed before the
##     run). After the same edit it recompiles all five units. This is the
##     mutation the milestone names, performed as a second edge instead of an
##     edit to the convention (the edit was also done and the case observed to
##     fail; see the milestone's record).
##
## NO MOCKS: real repro, real runquotad, real cargo and rustc.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import rqe_m15_width_fixture
import rqe_cg3_fixture

const BudgetMilli = 4000

suite "the delegated cargo edge keeps cargo's incremental state":

  test "test_rqe_cg3_incremental_preserved: editing one leaf crate rebuilds " &
      "exactly one unit":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let reproBin = requireBinary(reproBinaryPath(repoRoot),
      "reprobuild.apps.repro")
    require findExe("cargo").len > 0 and findExe("rustc").len > 0

    let scratch = createTempDir("rqe-cg3-incr-", "")
    defer: removeDir(scratch)
    let logger = scratch / "unit-logger"
    let sizedLog = scratch / "delegated.log"
    let controlLog = scratch / "opaque.log"

    let project = scratch / "delegated"
    createDir(project)
    writeDelegatedCargoProject(project)

    let controlProject = scratch / "opaque"
    createDir(controlProject)
    writeDelegatedCargoProject(controlProject)
    # The control is a recipe, so the project routes to it and not to the
    # convention: the same cargo command with the target directory declared
    # opaque (an output, removed before each run).
    let cargo = findExe("cargo")
    let controlTarget = controlProject / "target"
    writeFile(controlProject / "reprobuild.nim", """
import repro_project_dsl

package cg3_opaque:
  defaultToolProvisioning "path"

  uses:
    "cargo"
    "rustc"
    "gcc"

  build:
    let opaque = buildAction("cg3.opaque.cargo",
      inlineExecCall(@[""" & escape(cargo) & """, "build", "--release",
        "--locked", "--offline", "--target-dir", """ & escape(controlTarget) &
      """], cwd = """ & escape(controlProject) & """),
      outputs = @[""" & escape(controlTarget) & """],
      removeBeforeRun = @[""" & escape(controlTarget) & """],
      inputs = @["Cargo.toml", "Cargo.lock", "build.rs", "src/main.rs",
        "liba/src/lib.rs", "libb/src/lib.rs", "libc/src/lib.rs"],
      cacheable = false)
    discard collect("default", @[opaque])
""")

    var daemon = startPrivateDaemon(repoRoot, BudgetMilli)
    defer: daemon.stop()

    proc build(root, work, logPath: string): string =
      # The log is read per build, so each build starts from an empty one.
      removeFile(logPath)
      let args = @[reproBin, "build", root,
        "--daemon=off", "--tool-provisioning=path",
        "--work-root=" & (scratch / work),
        "--action-cache-root=" & (scratch / (work & "-cache")),
        "--progress=quiet"]
      let res = runShell(shellCommand(args,
        env = [("RUSTC_WRAPPER", logger), ("CARGO_EDGE_UNIT_LOG", logPath)]),
        repoRoot, timeoutMs = 1_500_000)
      checkpoint res.output
      require res.code == 0
      res.output
    writeUnitLogger(logger)

    discard build(project, "work-delegated", sizedLog)
    let first = readUnitLog(sizedLog).crates
    checkpoint "build 1 compiled: " & $first
    check first == @["build_script_build", "cg3_app", "liba", "libb", "libc"]

    # One answer, named after the package the convention picked as the
    # project's name.
    var answers: seq[string]
    for path in walkFiles(project / ".repro" / "build" / "cargo" / "*.products"):
      answers.add path
    require answers.len == 1
    let productsFile = answers[0]
    let productsBefore = readFile(productsFile)
    let lines = productsBefore.splitLines
    check lines[0] == "repro-cargo-products-v1"
    # Exactly one final product: the executable. No library, no build script,
    # nothing from the dependency tree.
    checkpoint "products file: " & productsBefore.replace("\n", " | ")
    check lines.len == 3 and lines[2] == ""
    check lines[1].endsWith("target/release/cg3_app")
    check fileExists(lines[1])

    # Edit the leaf: the binary's own source; nothing depends on it.
    writeFile(project / "src" / "main.rs",
      "fn main() { println!(\"{} {} {} v2\", liba::id(), libb::id(), " &
      "libc::id()); }\n")
    discard build(project, "work-delegated", sizedLog)
    let second = readUnitLog(sizedLog).crates
    checkpoint "build 2 compiled: " & $second
    check second == @["cg3_app"]
    check execCmdEx(quoteShell(lines[1])).output.strip == "liba libb libc v2"
    # The answer about the products did not change, so what consumes it is
    # not invalidated.
    check readFile(productsFile) == productsBefore

    # Falsifying control: the target directory declared opaque.
    discard build(controlProject, "work-opaque", controlLog)
    check readUnitLog(controlLog).crates.len == 5
    writeFile(controlProject / "src" / "main.rs",
      "fn main() { println!(\"{} {} {} v2\", liba::id(), libb::id(), " &
      "libc::id()); }\n")
    discard build(controlProject, "work-opaque", controlLog)
    let opaque = readUnitLog(controlLog).crates
    checkpoint "opaque control compiled: " & $opaque
    # Every unit again: the instrument can see a full rebuild, so the single
    # unit above is the edge's doing and not a quiet host.
    check opaque == @["build_script_build", "cg3_app", "liba", "libb", "libc"]
