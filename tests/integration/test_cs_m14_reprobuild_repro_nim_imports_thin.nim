## A program that imports reprobuild's own root ``repro.nim`` with no mode
## define compiles none of the engine.
##
## The root ``repro.nim`` keeps its engine-only imports and top-level code in
## ``repro_recipe_support.nim``, included under ``when reproDslMode !=
## rdmThin:``, so a program that imports it gets the DSL's thin mode and the
## ``package reprobuild:`` block's ``cli:`` sections only. The program here is
## written to a scratch directory, outside this tree, so this repository's
## ``config.nims`` (which defines ``reproEvalMode``) is not read;
## ``--skipParentCfg`` keeps any other parent configuration out and
## ``--undef:reproEvalMode`` removes the define should something else set it.
## It imports ``repro_project_dsl/mode`` itself, then the root ``repro.nim``
## by its absolute path, and prints the mode.
##
## Each compile runs with only Nim's ``Processing`` hint, in its file-name
## form, which names every module the compilation imports or includes by its
## full path (the reading ``test_cs_m12_thin_import_cost`` uses). The thin
## ``nim c`` may name only Nim's own library, the scratch project, the root
## ``repro.nim`` and ``ThinReprobuildModules`` (what the program imports
## itself and what the thin ``import repro_project_dsl`` of ``repro.nim``
## reaches). Anything else, the included file, any other reprobuild library
## and every out-of-tree engine dependency, is listed in the failure. The
## binary must print ``mode=rdmThin``.
##
## Negative control: the same compile with ``-d:reproEvalMode`` (a
## ``nim check``) must name the included file, ``repro_tests``,
## ``repro_core`` and the DSL's standard library, so the classification is
## seen to find the engine where it is compiled. Mutation (recorded with the change that added the test):
## removing the ``when`` guard, so that ``repro.nim`` includes the file in
## every mode, fails the thin case naming the included file and the engine.

import std/[algorithm, os, osproc, sequtils, strutils, unittest]

# Running a built program is not a compile, so it does not go through the
# call the compiles use.
from repro_core/ambient_execution import uncontrolledExecCmdEx
import repro_interface_artifacts
import repro_test_support
from repro_test_support/process_fixtures import releaseDirAtProcessExit

const
  RootRecipe = ReprobuildRepoRoot / "repro.nim"
  IncludedRecipe = ReprobuildRepoRoot / "repro_recipe_support.nim"
  ThinReprobuildModules = [
    "libs/repro_project_dsl/src/repro_project_dsl.nim",
    "libs/repro_project_dsl/src/repro_project_dsl/mode.nim",
    "libs/repro_project_dsl/src/repro_project_dsl/thin.nim",
    "libs/repro_project_dsl/src/repro_project_dsl/cli_description.nim"]
    ## The reprobuild modules, besides the root ``repro.nim``, a thin compile
    ## of the program may name, relative to the checkout.
  EngineModules = ["libs/repro_core/", "libs/repro_dsl_stdlib/"]
    ## Libraries the evaluation-mode compile must name: the control.
  Program = "src/csm14_imports_reprobuild.nim"

proc scratchProject(label: string): string =
  ## A fresh project directory holding the program, removed when this
  ## process exits (``REPRO_CS_M14_KEEP=1`` keeps it).
  result = getTempDir() / ("cs-m14-reprobuild-repro-nim-" & label & "-" &
    $getCurrentProcessId())
  if getEnv("REPRO_CS_M14_KEEP") != "1":
    releaseDirAtProcessExit(result)
  createDir(result / "src")
  writeFile(result / Program,
    "## Imports reprobuild's root repro.nim and prints the DSL mode.\n" &
    "import repro_project_dsl/mode\n" &
    "import " & RootRecipe.changeFileExt("").escape & "\n" &
    "echo \"mode=\", reproDslMode\n")

proc nimRun(project, modeFlag: string; compile: bool): tuple[ok: bool;
    output: string; modules: seq[string]; binary: string] =
  ## ``nim c`` of the program when ``compile``, else ``nim check`` of it,
  ## with only the ``Processing`` hint.
  let outDir = project / "out"
  createDir(outDir)
  let binary = outDir / "csm14_imports_reprobuild"
  var args = if compile: @["nim", "c"] else: @["nim", "check"]
  args.add(@["--hint:all:off", "--hint:Processing:on",
    "--processing:filenames", "--warnings:off", "--skipParentCfg", modeFlag,
    "--parallelBuild:4", "--nimcache:" & (outDir / "nimcache")])
  if compile:
    args.add("--out:" & binary)
  args.add(consumerCompilePathFlags(ReprobuildRepoRoot))
  args.add(project / Program)
  let (output, code) = execCmdEx(quoteShellCommand(args),
    workingDir = project)
  (code == 0, output, nimProcessedModules(output), binary)

proc errorLines(output: string): string =
  for line in output.splitLines:
    if "Error" in line:
      result.add(line & "\n")

proc outsideThinSet(modules: seq[string]; project: string): seq[string] =
  ## The modules a thin compile of the program must not name.
  var nimLib = ""
  for path in modules:
    if path.extractFilename == "system.nim":
      nimLib = path.parentDir.parentDir
      break
  let allowed = @[RootRecipe] & ThinReprobuildModules.mapIt(
    ReprobuildRepoRoot / it)
  for path in modules:
    if path in allowed or path.startsWith(project & "/"):
      continue
    if nimLib.len > 1 and path.startsWith(nimLib & "/"):
      continue
    result.add(path)

suite "test_cs_m14_reprobuild_repro_nim_imports_thin":

  test "a program importing the root repro.nim names no engine module":
    let project = scratchProject("thin")
    let r = nimRun(project, "--undef:reproEvalMode", compile = true)
    checkpoint(errorLines(r.output))
    check r.ok
    check r.modules.len > 20
    check RootRecipe in r.modules
    check (ReprobuildRepoRoot /
      "libs/repro_project_dsl/src/repro_project_dsl/thin.nim") in r.modules
    check IncludedRecipe notin r.modules
    let outside = outsideThinSet(r.modules, project)
    checkpoint("modules outside the thin set:\n  " &
      outside.sorted.join("\n  "))
    check outside.len == 0
    if r.ok:
      let (output, code) = uncontrolledExecCmdEx(
        quoteShellCommand([r.binary]), workingDir = project)
      checkpoint(output)
      check code == 0
      check output.strip == "mode=rdmThin"

  test "negative control: the evaluation-mode compile names the engine":
    let project = scratchProject("eval")
    let r = nimRun(project, ReproEvalModeFlag, compile = false)
    checkpoint(errorLines(r.output))
    check IncludedRecipe in r.modules
    check (ReprobuildRepoRoot / "repro_tests.nim") in r.modules
    let outside = outsideThinSet(r.modules, project)
    checkpoint($outside.len & " modules outside the thin set in the " &
      "evaluation mode")
    for library in EngineModules:
      check outside.anyIt(it.startsWith(ReprobuildRepoRoot / library))
