## A Nim compile edge built by `repro build` runs no more C compilers than the
## width RunQuota granted it (reprobuild-pm
## `spec/Build-Engine-And-Scheduler.md` "Integration tiers" -> "Sized T0
## actions").
##
## THE DEFECT THIS GUARDS. `nim c` does not compile C itself: it writes one C
## file per module and starts the backend C compiler on them, `--parallelBuild`
## at a time. An edge that asks RunQuota for one slot and lets Nim choose its
## own width is admitted as one process and then runs a compiler per core.
##
## THE CONTRACT. The standard library's typed `nim.c` edge asks for a width
## range and names `--parallelBuild:` as the flag that takes the grant. Here the
## host budget is three slots, so the edge is granted three and the engine
## writes `--parallelBuild:3` into the Nim command line. A recipe that asks for
## more than the grant (`parallelBuild = 16`) is lowered to the grant, as the
## M9 contract says of any width flag.
##
## HOW IT IS OBSERVED. A real `repro build` of a Nim program with sixteen
## modules, under a real `runquotad` with a 3-slot budget. The edge names a
## wrapper as Nim's C compiler (`--gcc.exe`, Nim's own hook). The wrapper runs
## the real gcc unchanged and records when each object compile starts and ends,
## holding each 0.4 s so concurrent compiles overlap. The peak of the log is the
## number of C compiler processes that ran at once: at most 3, and exactly 3 for
## a program with more than three modules.
##
## The `m15.nim.control` edge is the same compile recorded as an inline command
## with `--parallelBuild:8`: it carries no width flag in the declared edge, so
## the engine does not touch it, and the instrument sees eight at once. That is
## the falsifying control: the bound above comes from the grant being written
## into the command, not from Nim or the host.
##
## NO MOCKS: real `repro`, real `runquotad`, real nim and gcc.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import rqe_m15_width_fixture

const
  ModuleCount = 16
  BudgetMilli = 3000

proc writeProgram(root: string) =
  createDir(root / "src")
  var imports: seq[string]
  var sum: seq[string]
  for i in 0 ..< ModuleCount:
    writeFile(root / "src" / ("m" & $i & ".nim"),
      "proc value" & $i & "*(): int = " & $i & "\n")
    imports.add("m" & $i)
    sum.add("value" & $i & "()")
  writeFile(root / "src" / "main.nim",
    "import " & imports.join(", ") & "\n" &
    "echo " & sum.join(" + ") & "\n")

suite "a sized Nim edge stays inside its grant":

  test "test_rqe_m15_nim_edge_bounded: a Nim compile granted 3 slots never " &
      "runs more than 3 C compiler processes":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let reproBin = requireBinary(reproBinaryPath(repoRoot),
      "reprobuild.apps.repro")
    let nim = findExe("nim")
    let gcc = findExe("gcc")
    require nim.len > 0 and gcc.len > 0

    let scratch = createTempDir("rqe-m15-nim-", "")
    defer: removeDir(scratch)
    let project = scratch / "recipe"
    createDir(project)
    writeProgram(project)

    let sizedLog = scratch / "sized.log"
    let controlLog = scratch / "control.log"
    let sizedWrapper = scratch / "gcc-wrapper-sized"
    let controlWrapper = scratch / "gcc-wrapper-control"
    writeLoggingWrapper(sizedWrapper, sizedLog, " -c ", gcc)
    writeLoggingWrapper(controlWrapper, controlLog, " -c ", gcc)

    writeFile(project / "repro.nim", """
import repro_project_dsl

package m15_nim_edge:
  defaultToolProvisioning "path"

  uses:
    "nim"
    "gcc"

  build:
    # The recipe asks for 16-wide; the grant is 3.
    let sized = nim.c(
      source = "src/main.nim",
      binary = "build/sized/main",
      nimcache = "build/sized/cache",
      gccExe = """ & escape(sizedWrapper) & """,
      parallelBuild = 16,
      actionId = "m15.nim.build")
    # The control: the same compile as an inline command, with no declared
    # width flag.
    let control = buildAction("m15.nim.control",
      inlineExecCall(@[""" & escape(nim) & """, "c",
        "--nimcache:build/control/cache", "--out:build/control/main",
        "--gcc.exe:" & """ & escape(controlWrapper) & """,
        "--parallelBuild:8", "src/main.nim"]),
      deps = @["m15.nim.build"],
      outputs = @["build/control/main"],
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
    # More objects than the grant, each compiled once.
    check sized.started > 3
    check sized.ended == sized.started
    # Exactly the grant: used, and not exceeded.
    check sized.peak == 3

    let control = peakConcurrency(controlLog)
    checkpoint "control edge: " & $control
    echo "      measured, control edge: ", control
    # Falsifying control: a width the engine does not manage is not bounded
    # by the budget.
    check control.peak > 3
