## A program that imports its project's ``repro.nim`` compiles none of the
## engine, and costs about what the same program costs with its command line
## written in the program itself.
##
## The program is round 2's fixture
## (``tests/fixtures/cs_m12_program_imports_repro_nim``: ``repro.nim`` and
## ``src/csm12prog_clispec.nim``, which instantiates
## ``csm12ProgCliDescription`` with clispec's ``cliProgram``), copied to a
## scratch directory so it is outside this tree. The baseline,
## ``tests/fixtures/cs_m12_thin_import_cost/src/csm12prog_baseline.nim``, is
## the same program with the ``cli:`` section written in a ``cliProgram``
## call of its own and no ``repro.nim`` import; the test checks that its
## body is the ``cli:`` section verbatim and that both binaries print the
## same results and the same usage error. Every compile is thin the way
## round 2's are: the main module is outside the tree, ``--skipParentCfg``
## keeps parent configuration out and ``--undef:reproEvalMode`` removes the
## define.
##
## The module set. Each compile runs with only Nim's ``Processing`` hint, in
## its file-name form, which names every module the compilation imports or
## includes (system and the standard library too) by its full path, warm
## nimcache or cold. The thin compile may name only:
##
## * Nim's own library (the directory holding the ``system.nim`` it names);
## * clispec (the directory holding the ``clispec.nim`` it names);
## * the scratch project;
## * from reprobuild, only ``ThinReprobuildModules``: the umbrellas and the
##   three standard-library-only modules of the thin mode.
##
## Anything else, any other reprobuild library and every out-of-tree engine
## dependency (``nimcrypto``, ``stint``, ``blake3``, the serialization
## family, ...), is listed in the failure. Against the baseline, the thin
## compile may add only the project's two files, the thin mode's reprobuild
## modules and at most ``StdlibExtraAllowance`` standard-library modules.
## The same classification of the evaluation-mode compile of the program
## must find reprobuild's engine (``repro_core``, ``repro_lock_files``,
## ...): that keeps the check honest, since a parser that found no modules,
## or roots that admitted everything, would pass the thin compile too.
##
## The time budget. Times on a shared host vary by tens of percent from run
## to run, so the budget is relative to compiles made in the same run, each
## the fastest of interleaved repeats; while it is not met, up to
## ``ExtraRounds`` further rounds are measured and added to the first:
##
## * front end: the thin ``nim check`` takes at most ``FrontEndRatio`` times
##   the baseline's plus ``FrontEndSlackSeconds``;
## * whole compile: the thin ``nim c`` with an empty nimcache takes at most
##   ``CompileRatio`` times the baseline's plus ``CompileSlackSeconds``;
## * against the engine: the thin ``nim check`` takes at most
##   ``EngineFraction`` of the evaluation-mode ``nim check`` of the same
##   program (the fixture with its deliberately broken bodies mended).
##
## Recorded when the test was written (nim 2.3.1, 4 C jobs, 5 runs on a host
## with a load average of 5 to 8): thin ``nim check`` median 1.92 s
## (1.76-2.14), baseline 1.86 s (1.70-1.99), evaluation mode 6.65 s
## (6.37-6.87), over 140, 133 and 333 modules; ``nim c`` with an empty
## nimcache thin 6.55 s (6.32-6.80), baseline 6.70 s (6.20-6.71),
## evaluation mode 15.35 s (two runs). The thin mode costs what the
## baseline costs, within the noise, and its front end is under a third of
## the engine's. The margins are set for that noise, so the budget catches
## the engine coming in (its front end alone is 3.5 times the baseline's),
## not a few modules of it: the module set is the precise check. Measured
## by mutation: ``thin.nim`` importing ``repro_lock_files``,
## ``repro_binary_cache_client/cache_key`` and ``repro_core`` added 33
## modules, the front end 2.46 s against 1.76 s and the whole compile
## 9.07 s against 7.24 s, inside the budget and failed by the module set.
##
## Negative control (by mutation, recorded with the change that added the
## test): ``thin.nim`` importing a single engine module
## (``repro_core/link_target``) fails both module-set cases, naming it.

import std/[algorithm, os, osproc, sequtils, strutils, times, unittest]

# Running a built program is not a compile, so it does not go through the
# call the compiles use.
from repro_core/ambient_execution import uncontrolledExecCmdEx
import repro_interface_artifacts
import repro_test_support

const
  ProgramFixtureDir = ReprobuildRepoRoot / "tests" / "fixtures" /
    "cs_m12_program_imports_repro_nim"
  BaselineFixtureDir = ReprobuildRepoRoot / "tests" / "fixtures" /
    "cs_m12_thin_import_cost"
  UsesMarker = "csm12UndeclaredUsesEntry"
  BuildMarker = "csm12UndeclaredBuildStep"
  ThinReprobuildModules = [
    "libs/reprobuild/src/reprobuild.nim",
    "libs/repro_dsl_stdlib/src/repro_dsl_stdlib.nim",
    "libs/repro_project_dsl/src/repro_project_dsl.nim",
    "libs/repro_project_dsl/src/repro_project_dsl/mode.nim",
    "libs/repro_project_dsl/src/repro_project_dsl/thin.nim",
    "libs/repro_project_dsl/src/repro_project_dsl/cli_description.nim"]
    ## The reprobuild modules a thin compile may name, relative to the
    ## checkout. ``repro_project_dsl.nim`` is allowed though a program that
    ## imports ``reprobuild`` does not reach it.
  EngineModules = ["libs/repro_core/", "libs/repro_lock_files/",
    "libs/repro_binary_cache_client/"]
    ## Libraries the evaluation-mode compile must name: the control.
  FrontEndRatio = 1.25
  FrontEndSlackSeconds = 0.5
  CompileRatio = 1.25
  CompileSlackSeconds = 1.0
  EngineFraction = 0.5
  StdlibExtraAllowance = 5
    ## Standard-library modules the thin mode may add to the baseline's.
  Repeats = 3
    ## Interleaved repeats of each ``nim check`` in a round; ``nim c`` runs
    ## twice.
  ExtraRounds = 2
    ## Further rounds measured, each added to the earlier ones, while the
    ## budget is not met: a burst of load that slowed one side of a round
    ## is unlikely to slow it again, and the engine coming in slows the thin
    ## side every round.
  GivenArgv = ["--jobs", "7", "--color", "blue", "--verbose", "--greeting",
    "hi"]

let scratchRoot = getTempDir() /
  ("cs-m12-thin-import-cost-" & $getCurrentProcessId())

type NimRun = tuple[ok: bool; output: string; seconds: float;
                    modules: seq[string]]

proc processedModules(output: string): seq[string] =
  ## The paths ``--hint:Processing:on --processing:filenames`` names, each
  ## once: ``Hint: >> <importer>: import: <path> [Processing]`` (or
  ## ``include:``).
  const Suffix = " [Processing]"
  for line in output.splitLines:
    if not line.endsWith(Suffix):
      continue
    for marker in [": import: ", ": include: "]:
      let at = line.find(marker)
      if at >= 0:
        let path = line[at + marker.len ..< line.len - Suffix.len]
        if path notin result:
          result.add(path)
        break

proc nimRun(project, main, modeFlag: string; outDir = ""): NimRun =
  ## ``nim c`` of ``project/<main>`` into ``outDir`` (a fresh nimcache and
  ## the binary), or ``nim check`` of it when ``outDir`` is empty: timed,
  ## with the module list.
  var args = if outDir.len > 0: @["nim", "c"] else: @["nim", "check"]
  args.add(@["--hint:all:off", "--hint:Processing:on",
    "--processing:filenames", "--warnings:off", "--skipParentCfg", modeFlag,
    "--parallelBuild:4"])
  if outDir.len > 0:
    createDir(outDir)
    args.add("--nimcache:" & (outDir / "nimcache"))
    args.add("--out:" & (outDir / main.splitFile.name))
  args.add(consumerCompilePathFlags(ReprobuildRepoRoot))
  args.add(project / main)
  let started = epochTime()
  let (output, code) = execCmdEx(quoteShellCommand(args),
    workingDir = project)
  (code == 0, output, epochTime() - started, processedModules(output))

proc errorLines(output: string): string =
  for line in output.splitLines:
    if "Error" in line:
      result.add(line & "\n")

proc rootOf(modules: seq[string]; fileName: string): string =
  ## The directory holding the module named ``fileName``: Nim's ``lib`` for
  ## ``system.nim`` (its parent), clispec's for ``clispec.nim``.
  for path in modules:
    if path.extractFilename == fileName:
      return path.parentDir
  ""

proc outsideThinSet(modules: seq[string]; project: string): seq[string] =
  ## The modules a thin compile must not name.
  let nimLib = rootOf(modules, "system.nim").parentDir
  let clispecRoot = rootOf(modules, "clispec.nim")
  let allowed = ThinReprobuildModules.mapIt(ReprobuildRepoRoot / it)
  for path in modules:
    if path in allowed:
      continue
    if nimLib.len > 1 and path.startsWith(nimLib & "/"):
      continue
    if clispecRoot.len > 0 and path.startsWith(clispecRoot & "/") and
        not path.startsWith(ReprobuildRepoRoot & "/"):
      continue
    if path.startsWith(project & "/"):
      continue
    result.add(path)

proc fmt(seconds: float): string = seconds.formatFloat(ffDecimal, 2)

proc cliBody(source, marker: string): seq[string] =
  ## The lines indented deeper than ``marker``'s line that follow it.
  let lines = source.splitLines
  var start = -1
  for i, line in lines:
    if line.strip == marker or line.strip.startsWith(marker):
      start = i
      break
  if start < 0:
    return
  let indent = lines[start].len - lines[start].strip(trailing = false).len
  for line in lines[start + 1 .. ^1]:
    if line.strip.len > 0 and
        line.len - line.strip(trailing = false).len <= indent:
      break
    result.add(line)
  while result.len > 0 and result[^1].strip.len == 0:
    result.setLen(result.len - 1)

proc run(binary: string; args: openArray[string]): tuple[code: int;
                                                         output: string] =
  let (output, code) = uncontrolledExecCmdEx(
    quoteShellCommand(@[binary] & @args), workingDir = binary.parentDir)
  (code, output.strip())

removeDir(scratchRoot)
createDir(scratchRoot)
let project = scratchRoot / "project"
createDir(project / "src")
copyFile(ProgramFixtureDir / "repro.nim", project / "repro.nim")
copyFile(ProgramFixtureDir / "src" / "csm12prog_clispec.nim",
  project / "src" / "csm12prog_clispec.nim")
copyFile(BaselineFixtureDir / "src" / "csm12prog_baseline.nim",
  project / "src" / "csm12prog_baseline.nim")

# The evaluation-mode variant: the broken bodies mended, the program
# expecting that mode (as in test_cs_m12_program_imports_repro_nim).
let evalProject = scratchRoot / "eval"
createDir(evalProject / "src")
block:
  let source = readFile(project / "repro.nim")
  doAssert ("    " & UsesMarker & "\n") in source
  doAssert (BuildMarker & "(42)") in source
  writeFile(evalProject / "repro.nim", source.replace("    " & UsesMarker &
    "\n", "").replace(BuildMarker & "(42)", "discard"))
  let program = readFile(project / "src" / "csm12prog_clispec.nim")
  doAssert "\"rdmThin\"" in program
  writeFile(evalProject / "src" / "csm12prog_clispec.nim",
    program.replace("\"rdmThin\"", "\"rdmEval\""))

const
  ThinMain = "src/csm12prog_clispec.nim"
  BaselineMain = "src/csm12prog_baseline.nim"
  Thin = "--undef:reproEvalMode"

var thinC, baseC, thinCheck, baseCheck, evalChecks: seq[NimRun]

proc measureRound() =
  ## One round of compiles, interleaved so that a burst of load on the host
  ## falls on both sides: `nim c` with an empty nimcache twice each, then
  ## `nim check`, then the evaluation-mode `nim check`.
  for i in 0 ..< 2:
    let n = $thinC.len
    thinC.add nimRun(project, ThinMain, Thin, scratchRoot / ("thin" & n))
    baseC.add nimRun(project, BaselineMain, Thin,
      scratchRoot / ("base" & n))
  for i in 0 ..< Repeats:
    thinCheck.add nimRun(project, ThinMain, Thin)
    baseCheck.add nimRun(project, BaselineMain, Thin)
  evalChecks.add nimRun(evalProject, ThinMain, ReproEvalModeFlag)

proc fastest(runs: seq[NimRun]): float =
  runs.mapIt(it.seconds).min

proc withinBudget(): bool =
  ## The budget, each side its fastest compile over every round so far.
  let thinFront = fastest(thinCheck)
  fastest(thinC) <= fastest(baseC) * CompileRatio + CompileSlackSeconds and
    thinFront <= fastest(baseCheck) * FrontEndRatio + FrontEndSlackSeconds and
    thinFront <= fastest(evalChecks) * EngineFraction

measureRound()
var rounds = 1
while rounds <= ExtraRounds and thinC.allIt(it.ok) and baseC.allIt(it.ok) and
    not withinBudget():
  measureRound()
  inc rounds
let evalCheck = evalChecks[0]

proc times(runs: seq[NimRun]): string =
  runs.mapIt(fmt(it.seconds)).join(", ")

suite "test_cs_m12_thin_import_cost":

  test "every compile succeeds":
    for (name, runs) in [("thin nim c", thinC), ("baseline nim c", baseC),
                         ("thin nim check", thinCheck),
                         ("baseline nim check", baseCheck),
                         ("evaluation nim check", evalChecks)]:
      for r in runs:
        checkpoint(name & ":\n" & errorLines(r.output))
        check r.ok

  test "the baseline is the same program":
    let fromRepro = cliBody(readFile(project / "repro.nim"), "cli:")
    let fromBaseline = cliBody(readFile(project / BaselineMain),
      "cliProgram(Csm12Prog,")
    check fromRepro.len > 5
    check fromRepro == fromBaseline
    let thinBin = scratchRoot / "thin0" / "csm12prog_clispec"
    let baseBin = scratchRoot / "base0" / "csm12prog_baseline"
    if thinC[0].ok and baseC[0].ok:
      # The programs differ only in the mode they print first.
      for argv in [newSeq[string](), @GivenArgv, @["--color", "purple"]]:
        let thin = run(thinBin, argv)
        let base = run(baseBin, argv)
        checkpoint(thin.output & "\n" & base.output)
        check thin.code == base.code
        check thin.output.replace("mode=rdmThin ", "") ==
          base.output.replace("mode=none ", "")
        check "mode=rdmThin " in thin.output or thin.code == 2

  test "the thin compile names none of the engine's modules":
    for r in thinC & thinCheck:
      let modules = r.modules
      check modules.len > 50
      check (ReprobuildRepoRoot /
        "libs/repro_project_dsl/src/repro_project_dsl/thin.nim") in modules
      check (project / "repro.nim") in modules
      check rootOf(modules, "clispec.nim").len > 0
      let outside = outsideThinSet(modules, project)
      checkpoint("modules outside the thin set:\n  " &
        outside.sorted.join("\n  "))
      check outside.len == 0
    # The control: the same classification finds the engine in the
    # evaluation-mode compile of the same program.
    let engine = outsideThinSet(evalCheck.modules, evalProject)
    checkpoint($engine.len & " modules outside the thin set in the " &
      "evaluation mode")
    for library in EngineModules:
      check engine.anyIt(it.startsWith(ReprobuildRepoRoot / library))
    check evalCheck.modules.len > 2 * baseCheck[0].modules.len

  test "the thin mode adds only its own modules to the baseline's":
    # Beyond what the same program imports with its command line written
    # in it: the project's two files, the thin mode's reprobuild modules and
    # at most `StdlibExtraAllowance` standard-library modules (measured: one,
    # `std/compilesettings`, which `mode` reads the main file with).
    let nimLib = rootOf(thinCheck[0].modules, "system.nim").parentDir
    let extra = thinCheck[0].modules.filterIt(it notin baseCheck[0].modules)
    let stdlib = extra.filterIt(it.startsWith(nimLib & "/"))
    checkpoint("modules the baseline does not import:\n  " &
      extra.sorted.join("\n  "))
    check stdlib.len <= StdlibExtraAllowance
    check (project / "repro.nim") in extra
    for path in extra:
      if path notin stdlib:
        check path.startsWith(project & "/") or
          path in ThinReprobuildModules.mapIt(ReprobuildRepoRoot / it)

  test "the thin compile stays within its time budget":
    let thinFront = fastest(thinCheck)
    let baseFront = fastest(baseCheck)
    let thinWhole = fastest(thinC)
    let baseWhole = fastest(baseC)
    let report = $rounds & " round(s)\n" &
      "nim check: thin " & times(thinCheck) & " s (" &
      $thinCheck[0].modules.len & " modules), baseline " & times(baseCheck) &
      " s (" & $baseCheck[0].modules.len & "), evaluation mode " &
      times(evalChecks) & " s (" & $evalCheck.modules.len & ")\n" &
      "nim c, empty nimcache: thin " & times(thinC) & " s, baseline " &
      times(baseC) & " s"
    checkpoint(report)
    if getEnv("REPRO_CS_M12_COST_REPORT") == "1":
      echo report
    check thinFront <= baseFront * FrontEndRatio + FrontEndSlackSeconds
    check thinWhole <= baseWhole * CompileRatio + CompileSlackSeconds
    check thinFront <= fastest(evalChecks) * EngineFraction

if getEnv("REPRO_CS_M12_KEEP") != "1":
  removeDirEventually(scratchRoot)
