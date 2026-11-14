## A cargo edge built by `repro build` stays inside the width RunQuota grants
## it (reprobuild-pm `spec/Build-Engine-And-Scheduler.md`
## "Integration tiers" -> "Sized T0 actions").
##
## THE DEFECT THIS GUARDS. An edge for a parallel tool that asks RunQuota for
## the one-slot default is admitted as one slot, and cargo then starts one
## rustc per core. Moving a project to `repro` would not bound it: the host
## budget says two slots and the host runs thirty-two compiles.
##
## THE CONTRACT. The standard library's typed `cargo.build` edge asks for a
## width RANGE and names `-j` as the flag that takes the grant. RunQuota
## grants the widest free width in the range (here: the whole 2-slot budget)
## and the engine writes it after `-j` at launch. cargo is then the jobserver
## of its own rustc processes and build scripts, so the tree stays inside two.
##
## HOW IT IS OBSERVED. A real `repro build` of a recipe with twelve independent
## crates, under a real `runquotad` whose whole budget is two slots. A
## `RUSTC_WRAPPER` in front of the real rustc records when each crate's
## compile starts and ends (and holds each for 0.4 s so concurrent compiles
## overlap in time); the peak of the log is the number of rustc processes that
## ran at once.
##
##   * `m15.cargo.build` (the typed constructor): peak is exactly 2, all
##     twelve crates compiled.
##   * `m15.cargo.control` (the falsifying control): the same cargo command,
##     recorded as an inline command, so it is the one-slot default with no
##     width flag and no jobserver. Its peak is above 2: the instrument sees
##     an unbounded cargo, so the bound above is the sizing's, not an
##     accident of a quiet host. This is the mutation the milestone names
##     (a one-slot default lets cargo run all cores) performed as a second
##     edge instead of an edit; the same result was also obtained by editing
##     `sized_tools.sizedWidthFor` to return nothing for cargo.
##
## NO MOCKS: real `repro`, real `runquotad`, real cargo/rustc/gcc. The wrapper
## runs the real rustc unchanged.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import rqe_m15_width_fixture

const
  CrateCount = 12
  BudgetMilli = 2000

proc writeWorkspace(root: string) =
  writeFile(root / "Cargo.toml",
    "[workspace]\nresolver = \"2\"\nmembers = [\"crates/*\"]\n")
  for i in 0 ..< CrateCount:
    let dir = root / "crates" / ("c" & $i)
    createDir(dir / "src")
    writeFile(dir / "Cargo.toml",
      "[package]\nname = \"m15_c" & $i & "\"\nversion = \"0.1.0\"\n" &
      "edition = \"2021\"\n")
    writeFile(dir / "src" / "lib.rs",
      "pub fn id() -> u32 { " & $i & " }\n")

suite "a sized cargo edge stays inside its grant":

  test "test_rqe_m15_recorder_cargo_edge_bounded: twelve crates under a " &
      "2-slot host budget never show more than 2 concurrent rustc":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let reproBin = requireBinary(reproBinaryPath(repoRoot),
      "reprobuild.apps.repro")
    let cargo = findExe("cargo")
    let rustc = findExe("rustc")
    require cargo.len > 0 and rustc.len > 0 and findExe("gcc").len > 0

    let scratch = createTempDir("rqe-m15-cargo-", "")
    defer: removeDir(scratch)
    let project = scratch / "recipe"
    createDir(project)
    writeWorkspace(project)

    let sizedLog = scratch / "sized.log"
    let controlLog = scratch / "control.log"
    let sizedWrapper = scratch / "rustc-wrapper-sized"
    let controlWrapper = scratch / "rustc-wrapper-control"
    writeLoggingWrapper(sizedWrapper, sizedLog, " --crate-name m15_c", "$1")
    writeLoggingWrapper(controlWrapper, controlLog, " --crate-name m15_c", "$1")

    writeFile(project / "repro.nim", """
import repro_project_dsl

package m15_cargo_recorder:
  defaultToolProvisioning "path"

  uses:
    "cargo"
    "rustc"
    "gcc"

  build:
    let sized = cargo.build(
      actionId = "m15.cargo.build",
      extraInputs = @["Cargo.toml"],
      extraOutputs = @["target/debug/libm15_c0.rlib"],
      extraEnv = @[("RUSTC_WRAPPER", """ & escape(sizedWrapper) & """)])
    # The control: the same cargo command as an inline command. It carries no
    # width flag, so it is the one-slot default with no jobserver.
    let control = buildAction("m15.cargo.control",
      inlineExecCall(@[""" & escape(cargo) & """, "build",
        "--target-dir", "target-control"]),
      deps = @["m15.cargo.build"],
      outputs = @["target-control/debug/libm15_c0.rlib"],
      env = @[("RUSTC_WRAPPER", """ & escape(controlWrapper) & """)],
      cacheable = false)
    discard collect("default", @[sized, control])
""")

    var daemon = startPrivateDaemon(repoRoot, BudgetMilli)
    defer: daemon.stop()

    let args = @[reproBin, "build", project,
      "--daemon=off", "--tool-provisioning=path",
      "--work-root=" & (scratch / "work"),
      "--action-cache-root=" & (scratch / "cache"),
      "--progress=quiet"]
    let build = runShell(shellCommand(args), repoRoot, timeoutMs = 1_500_000)
    checkpoint build.output
    require build.code == 0

    let sized = peakConcurrency(sizedLog)
    checkpoint "sized edge: " & $sized
    echo "      measured, sized edge: ", sized
    # Every crate was compiled, and each compile's end was recorded.
    check sized.started == CrateCount
    check sized.ended == CrateCount
    # The grant is the whole 2-slot budget: cargo used it (more than one at a
    # time) and stayed inside it.
    check sized.peak == 2

    let control = peakConcurrency(controlLog)
    checkpoint "control edge: " & $control
    echo "      measured, control edge: ", control
    check control.started == CrateCount
    # Falsifying control: without the width flag cargo is not bounded by the
    # 2-slot budget.
    check control.peak > 2
