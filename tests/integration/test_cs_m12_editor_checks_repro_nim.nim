## An editor opens a project's ``repro.nim`` cold and checks it against the
## full DSL, with no mode define anywhere; the program that imports the same
## ``repro.nim`` still compiles it thin.
##
## The fixture project (``tests/fixtures/cs_m12_editor_checks_repro_nim``) is
## copied to a scratch directory, outside this tree, so this repository's
## ``config.nims`` (which defines ``reproEvalMode``) is not read; every
## compile passes ``--skipParentCfg`` so no other parent configuration is
## either. The only configuration is the project's ``nim.cfg``, written by
## the test with the ``--path`` entries of the engine's consumer-compile flag
## set (``consumerCompilePathFlags``) and nothing else: what an editor needs
## to find the DSL. Its ``repro.nim`` has a ``build:`` body that names an
## identifier nothing declares, and declares, under
## ``when reproDslMode != rdmThin:``, a procedure returning the engine's
## ``BuildActionDef``.
##
## * ``nim check repro.nim`` reports the planted error: the main file is a
##   DSL file, so ``repro_project_dsl/mode`` selects ``rdmEval`` and the
##   ``build:`` body is type-checked.
## * ``nimsuggest --v3 --tester`` with ``repro.nim`` as its project resolves
##   ``def`` on ``BuildActionDef``, which only the full DSL declares, and its
##   ``chk`` reports the planted error.
## * ``src/csm12editor_prog.nim`` imports ``../repro`` and is compiled with
##   ``nim c`` and run: it asserts at compile time that ``repro.nim`` compiled
##   in ``rdmThin``, and compiles at all only because the thin mode does not
##   compile the broken ``build:`` body.
## * ``editor_helpers.nim`` uses the full DSL and its name is not a DSL
##   file's; ``editor_helpers.nims`` beside it (``switch("define",
##   "reproEvalMode")``) makes ``nim check editor_helpers.nim`` cold compile
##   it in ``rdmEval``. Control: without the ``.nims`` the same check fails
##   on ``BuildActionDef``, so the file is what selected the mode.
##
## Negative control (by mutation, recorded with the change that added the
## rule): with the main-file rule removed from ``mode.nim`` the ``nim check``
## and ``nimsuggest`` cases fail, because ``repro.nim`` then compiles thin.
##
## A missing ``nimsuggest`` is a failure with a remedy, not a skip.

import std/[os, osproc, sequtils, strutils, unittest]

# Running `nim` / `nimsuggest` from PATH is what an editor does, and the
# point of this test.
from repro_core/ambient_execution import uncontrolledExecCmdEx,
  uncontrolledFindExe
import repro_interface_artifacts
import repro_test_support

const
  FixtureDir = ReprobuildRepoRoot / "tests" / "fixtures" /
    "cs_m12_editor_checks_repro_nim"
  LibsRoot = ReprobuildRepoRoot / "libs"
  PlantedError = "undeclared identifier: 'csm12EditorPlantedError'"
  PlantedLine = 27
    ## ``repro.nim``'s line of the planted error, column 5.
  FullOnlyLine = 14
  FullOnlyCol = 30
    ## Inside ``BuildActionDef`` on ``repro.nim``'s line 14.

let scratchRoot = getTempDir() /
  ("cs-m12-editor-checks-repro-nim-" & $getCurrentProcessId())

proc nimExe(): string =
  result = uncontrolledFindExe("nim")
  if result.len == 0:
    raise newException(IOError, "no `nim` on PATH; run inside the dev shell")

proc nimsuggestExe(): string =
  ## ``$NIMSUGGEST``, else the ``nimsuggest`` beside the ``nim`` on ``PATH``
  ## (``libexec/`` or ``bin/``), else one on ``PATH``: the lookup of
  ## ``t_ux_m1_reprobuild_module_hierarchy_and_lsp``.
  let explicit = getEnv("NIMSUGGEST")
  if explicit.len > 0 and fileExists(explicit):
    return explicit
  let nimBin = expandFilename(nimExe()).parentDir
  for candidate in [nimBin.parentDir / "libexec" / "nimsuggest",
                    nimBin / "nimsuggest"]:
    if fileExists(candidate.addFileExt(ExeExt)):
      return candidate.addFileExt(ExeExt)
  result = uncontrolledFindExe("nimsuggest")
  if result.len == 0:
    raise newException(IOError,
      "no nimsuggest found (looked at $NIMSUGGEST, beside " & nimExe() &
      " and on PATH); set NIMSUGGEST to the nimsuggest of this Nim toolchain")

proc discoveryFlags(workDir: string): seq[string] =
  ## The engine's consumer-compile flag set, with ``$REPROBUILD_LIBS_DIR``
  ## naming this checkout's libraries.
  let saved = getEnv("REPROBUILD_LIBS_DIR")
  putEnv("REPROBUILD_LIBS_DIR", LibsRoot)
  try:
    result = consumerCompilePathFlags(workDir)
  finally:
    if saved.len > 0: putEnv("REPROBUILD_LIBS_DIR", saved)
    else: delEnv("REPROBUILD_LIBS_DIR")

proc copyFixture(dest: string; flags: seq[string]) =
  createDir(dest / "src")
  for file in ["repro.nim", "editor_helpers.nim", "editor_helpers.nims"]:
    copyFile(FixtureDir / file, dest / file)
  copyFile(FixtureDir / "src" / "csm12editor_prog.nim",
    dest / "src" / "csm12editor_prog.nim")
  var cfg = ""
  for flag in flags:
    if flag.startsWith("--path:"):
      cfg.add("--path:\"" & flag["--path:".len .. ^1] & "\"\n")
  doAssert "reproEvalMode" notin cfg
  writeFile(dest / "nim.cfg", cfg)

proc nimCheck(dir, file: string): tuple[ok: bool; output: string] =
  ## ``nim check`` run from ``dir``: the search path comes from its
  ## ``nim.cfg`` alone, and no mode is defined.
  let command = @[nimExe(), "check", "--hints:off", "--warnings:off",
    "--colors:off", "--skipParentCfg",
    "--nimcache:" & (dir / "nimcache" / file.splitFile.name), file]
  let (output, code) = uncontrolledExecCmdEx(quoteShellCommand(command),
    options = {poStdErrToStdOut}, workingDir = dir)
  (code == 0, output)

proc nimsuggest(dir, project: string; queries: openArray[string]):
    tuple[output: string; exitCode: int] =
  ## A cold ``nimsuggest --v3 --tester`` session on ``project``, fed
  ## ``queries`` (``"<cmd> <line>:<col>"``, against ``project``) and ``quit``.
  let abs = dir / project
  var input = ""
  for q in queries:
    let parts = q.split(' ', 1)
    input.add(parts[0] & " " & abs & ":" & parts[1] & "\n")
  input.add("quit\n")
  let command = @[nimsuggestExe(), "--v3", "--tester", "--skipParentCfg",
    project]
  uncontrolledExecCmdEx(quoteShellCommand(command),
    options = {poStdErrToStdOut}, workingDir = dir, input = input)

proc suggestRecords(output, command: string): seq[seq[string]] =
  ## The tab-separated ``nimsuggest`` answers of ``command``: command,
  ## symkind, qualified name, type (for ``chk``: the severity), file, line,
  ## column, doc, quality.
  for line in output.splitLines:
    let fields = line.split('\t')
    if fields.len >= 7 and fields[0] == command:
      result.add(fields)

proc errorLines(output: string): string =
  ## The lines of a compile's output that report an error.
  for line in output.splitLines:
    if "Error" in line:
      result.add(line & "\n")

removeDir(scratchRoot)
createDir(scratchRoot)
let project = scratchRoot / "project"
copyFixture(project, discoveryFlags(project))

suite "test_cs_m12_editor_checks_repro_nim":

  test "nim check repro.nim checks the build: body with no mode define":
    let checked = nimCheck(project, "repro.nim")
    checkpoint(checked.output)
    check not checked.ok
    check ("repro.nim(" & $PlantedLine & ", 5) Error: " & PlantedError) in
      checked.output
    # Every error is the planted one (the DSL expands the body more than
    # once, so it is reported more than once): the full DSL resolved
    # everything else, ``BuildActionDef`` included.
    for line in checked.output.splitLines:
      if ") Error: " in line:
        check ("repro.nim(" & $PlantedLine & ", ") in line
        check "'csm12EditorPlantedError'" in line

  test "nimsuggest with repro.nim as its project uses the full DSL":
    let (output, _) = nimsuggest(project, "repro.nim",
      ["def " & $FullOnlyLine & ":" & $FullOnlyCol, "chk 1:1"])
    # The answers, without the ``chk`` hints that list every module.
    checkpoint(output.splitLines.filterIt(it.startsWith("def\t") or
      "\tError\t" in it).join("\n"))
    let defs = suggestRecords(output, "def")
    check defs.len == 1
    if defs.len == 1:
      check defs[0][2].endsWith("BuildActionDef")
      check defs[0][1] == "skType"
      # Declared in the engine's libraries, not in the fixture.
      check not defs[0][4].startsWith(project)
      check defs[0][4].startsWith(LibsRoot)
    # The planted error, and only errors about it.
    let errors = suggestRecords(output, "chk").filterIt(it[3] == "Error")
    check errors.anyIt(PlantedError.replace("'", "\\'") in it[7])
    for error in errors:
      check error[4].endsWith("repro.nim")
      check error[5] == $PlantedLine
      check "csm12EditorPlantedError" in error[7]

  test "the program importing repro.nim compiles it thin":
    let outDir = scratchRoot / "program"
    createDir(outDir)
    let binary = outDir / "csm12editor_prog"
    var command = @[nimExe(), "c", "--hints:off", "--warnings:off",
      "--skipParentCfg", "--parallelBuild:4",
      "--nimcache:" & (outDir / "nimcache"), "--out:" & binary]
    command.add(discoveryFlags(project))
    command.add(project / "src" / "csm12editor_prog.nim")
    let (output, code) = execCmdEx(quoteShellCommand(command),
      workingDir = project)
    checkpoint(errorLines(output))
    check code == 0
    if code == 0:
      let (ran, runCode) = uncontrolledExecCmdEx(quoteShellCommand([binary]))
      check runCode == 0
      check ran.strip == "mode=rdmThin"

  test "a helper module with <helper>.nims is checked in the full DSL":
    let checked = nimCheck(project, "editor_helpers.nim")
    checkpoint(checked.output)
    check checked.ok
    # Control: the .nims is what selected the mode.
    let bare = scratchRoot / "helper-without-nims"
    copyFixture(bare, discoveryFlags(bare))
    removeFile(bare / "editor_helpers.nims")
    let thin = nimCheck(bare, "editor_helpers.nim")
    checkpoint(thin.output)
    check not thin.ok
    check "editor_helpers.nim compiled in rdmThin" in thin.output or
      "undeclared identifier: 'BuildActionDef'" in thin.output

if getEnv("REPRO_CS_M12_KEEP") != "1":
  removeDirEventually(scratchRoot)
