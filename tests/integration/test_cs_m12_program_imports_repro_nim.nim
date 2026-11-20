## A program imports its project's ``repro.nim`` and parses its command line
## from the ``cli:`` section the file declares for it.
##
## The fixture project (``tests/fixtures/cs_m12_program_imports_repro_nim``,
## copied to a scratch directory so it is a project outside this tree) has a
## ``repro.nim`` whose ``executable "csm12-prog"`` declares a ``cli:``
## section with a default read from an exported constant, a default read
## from an exported procedure, a closed value set and an environment
## variable. Its ``uses:`` and ``build:`` bodies each name an identifier
## nothing declares, and an engine-only import sits under
## ``when reproDslMode != rdmThin:``. Two programs import that ``repro.nim``
## with no mode define, so it compiles in the DSL's thin mode, and
## instantiate ``csm12ProgCliDescription`` (the ``package`` macro's template
## for ``csm12-prog``): ``src/csm12prog_clispec.nim`` with clispec's
## ``cliProgram``, ``src/csm12prog_confutils.nim`` with confutils'
## ``cliConfiguration``. The test compiles both, runs them and checks what
## they parsed. Each program asserts at compile time, and prints, the mode
## ``repro.nim`` compiled in.
##
## The compiles are thin by construction as well as by assertion: the main
## modules are outside this tree, so this repository's ``config.nims``
## (which defines ``reproEvalMode``) is not read, ``--skipParentCfg`` keeps
## any other parent configuration out, and ``--undef:reproEvalMode`` removes
## the define should something else set it.
##
## Names a ``cli:`` section uses must be exported from ``repro.nim``: a
## variant with the constant unexported must fail to compile, naming the
## parameter. The evaluation mode (``-d:reproEvalMode``, what reprobuild's
## own tests compile in) emits the same template: a variant with the broken
## bodies mended, compiled in that mode, parses the same command line.
##
## The template's name for an executable whose name is not an identifier
## (punctuation, a leading digit), and the compile errors when two
## executables of one module would get the same name, are checked with
## ``nim check`` of small recipes in the thin mode.
##
## Negative control: the thin compile skips the two broken bodies, which is
## the point; that is meaningful only if they are really broken. The fixture
## is compiled in the evaluation mode (``-d:reproEvalMode``), once as it is
## and once with the ``uses:`` entry removed, and each compile must fail on
## the identifier its body names. So a thin ``package`` that compiled its
## ``uses:`` or ``build:`` body would make the programs fail to compile.

import std/[os, osproc, strtabs, strutils, unittest]

import repro_interface_artifacts
import repro_test_support

const
  FixtureDir = ReprobuildRepoRoot / "tests" / "fixtures" /
    "cs_m12_program_imports_repro_nim"
  UsesMarker = "csm12UndeclaredUsesEntry"
  BuildMarker = "csm12UndeclaredBuildStep"

let scratchRoot = getTempDir() /
  ("cs-m12-program-imports-repro-nim-" & $getCurrentProcessId())

proc confutilsRoot(): string =
  ## Where confutils is, as this repository's ``config.nims`` finds it: the
  ## ``../nim-confutils`` checkout, else ``$CONFUTILS_SRC``.
  let sibling = ReprobuildRepoRoot.parentDir / "nim-confutils"
  if fileExists(sibling / "confutils.nim"):
    return sibling
  getEnv("CONFUTILS_SRC")

proc compileFlags(): seq[string] =
  result = consumerCompilePathFlags(ReprobuildRepoRoot)
  let confutils = confutilsRoot()
  if confutils.len == 0 or not fileExists(confutils / "confutils.nim"):
    raise newException(IOError, "confutils not found: no ../nim-confutils " &
      "beside this checkout and no $CONFUTILS_SRC")
  result.add("--path:" & confutils)

proc copyFixture(dest: string) =
  createDir(dest / "src")
  copyFile(FixtureDir / "repro.nim", dest / "repro.nim")
  for program in ["csm12prog_clispec.nim", "csm12prog_confutils.nim"]:
    copyFile(FixtureDir / "src" / program, dest / "src" / program)

proc compileProgram(project, program, outDir: string;
                    modeFlag = "--undef:reproEvalMode"):
    tuple[ok: bool; output, binary: string] =
  ## ``nim c`` of ``src/<program>.nim`` in ``project``, with no mode define
  ## unless ``modeFlag`` gives one.
  createDir(outDir)
  let binary = outDir / program
  var command = @["nim", "c", "--hints:off", "--warnings:off",
    "--skipParentCfg", modeFlag, "--parallelBuild:4",
    "--nimcache:" & (outDir / "nimcache"), "--out:" & binary]
  command.add(compileFlags())
  command.add(project / "src" / (program & ".nim"))
  let (output, code) = execCmdEx(quoteShellCommand(command),
    workingDir = project)
  (code == 0, output, binary)

proc run(binary: string; args: openArray[string];
         env: openArray[(string, string)] = []): tuple[code: int; output: string] =
  let table = newStringTable(modeCaseSensitive)
  for name, value in envPairs():
    table[name] = value
  table.del("CSM12_JOBS")
  for (name, value) in env:
    table[name] = value
  let (output, code) = execCmdEx(quoteShellCommand(@[binary] & @args),
    env = table, workingDir = binary.parentDir)
  (code, output.strip())

proc errorLines(output: string): string =
  for line in output.splitLines:
    if "Error" in line:
      result.add(line & "\n")

const
  Defaults = "mode=rdmThin jobs=4 greeting=hello color=red verbose=false"
  Given = "mode=rdmThin jobs=7 greeting=hi color=blue verbose=true"
  GivenArgv = ["--jobs", "7", "--color", "blue", "--verbose", "--greeting",
    "hi"]
  BadValue = "invalid value 'purple' for '--color' of 'csm12prog'; " &
    "expected one of: red, green, blue"

removeDir(scratchRoot)
createDir(scratchRoot)
let project = scratchRoot / "project"
copyFixture(project)

suite "test_cs_m12_program_imports_repro_nim":

  test "clispec's cliProgram parses the description repro.nim declares":
    let built = compileProgram(project, "csm12prog_clispec",
      scratchRoot / "clispec")
    checkpoint(errorLines(built.output))
    check built.ok
    if built.ok:
      check run(built.binary, []) == (0, Defaults)
      check run(built.binary, GivenArgv) == (0, Given)
      # The environment is confutils' to read, not clispec's.
      check run(built.binary, [], {"CSM12_JOBS": "5"}) == (0, Defaults)
      let bad = run(built.binary, ["--color", "purple"])
      checkpoint(bad.output)
      check bad.code == 2
      check BadValue in bad.output

  test "confutils' cliConfiguration loads the same description":
    let built = compileProgram(project, "csm12prog_confutils",
      scratchRoot / "confutils")
    checkpoint(errorLines(built.output))
    check built.ok
    if built.ok:
      check run(built.binary, []) == (0, Defaults)
      check run(built.binary, GivenArgv) == (0, Given)
      check run(built.binary, [], {"CSM12_JOBS": "5"}) ==
        (0, Defaults.replace("jobs=4", "jobs=5"))
      let bad = run(built.binary, ["--color", "purple"])
      checkpoint(bad.output)
      check bad.code == 2
      check BadValue in bad.output

  test "a name the cli: section uses must be exported from repro.nim":
    let variant = scratchRoot / "unexported"
    copyFixture(variant)
    let source = readFile(variant / "repro.nim")
    require "const DefaultJobs* = 4" in source
    writeFile(variant / "repro.nim",
      source.replace("const DefaultJobs* = 4", "const DefaultJobs = 4"))
    let built = compileProgram(variant, "csm12prog_clispec",
      scratchRoot / "unexported-out")
    checkpoint(errorLines(built.output))
    check not built.ok
    check "clispec: parameter 'jobs': default `DefaultJobs` is not a " &
      "valid int" in built.output

  test "the evaluation mode emits the same template":
    # A reprobuild test compiles in the evaluation mode, and must find the
    # description too. The fixture's broken bodies are mended for it, and
    # the program is a copy of the clispec one that expects that mode.
    let variant = scratchRoot / "evaluation"
    copyFixture(variant)
    let source = readFile(variant / "repro.nim")
    require ("    " & UsesMarker & "\n") in source
    require (BuildMarker & "(42)") in source
    writeFile(variant / "repro.nim", source.replace("    " & UsesMarker &
      "\n", "").replace(BuildMarker & "(42)", "discard"))
    let program = readFile(variant / "src" / "csm12prog_clispec.nim")
    require "\"rdmThin\"" in program
    writeFile(variant / "src" / "csm12prog_eval.nim",
      program.replace("\"rdmThin\"", "\"rdmEval\""))
    let built = compileProgram(variant, "csm12prog_eval",
      scratchRoot / "evaluation-out", ReproEvalModeFlag)
    checkpoint(errorLines(built.output))
    check built.ok
    if built.ok:
      check run(built.binary, GivenArgv) ==
        (0, Given.replace("mode=rdmThin", "mode=rdmEval"))

  test "the template's name: punctuation, digits and collisions":
    # `nim check` of small recipes in the thin mode: what name each
    # executable's template gets, and the refusals when two executables of
    # one module would get the same one.
    let dir = scratchRoot / "names"
    createDir(dir)
    proc thinCheck(name, source: string): tuple[ok: bool; output: string] =
      writeFile(dir / (name & ".nim"), source)
      var command = @["nim", "check", "--hints:off", "--warnings:off",
        "--skipParentCfg", "--undef:reproEvalMode"]
      command.add(compileFlags())
      command.add(dir / (name & ".nim"))
      let (output, code) = execCmdEx(quoteShellCommand(command),
        workingDir = dir)
      (code == 0, output)

    let named = thinCheck("named", """
import reprobuild
package names:
  executable "csm12-prog":
    cli:
      flag x is int
  executable "7z":
    cli:
      flag x is int
  executable `create-dmg`:
    cli:
      flag x is int
  executable plain:
    cli:
      flag x is int
  executable noCli:
    name: "nocli"
static:
  doAssert declared(csm12_progCliDescription)
  doAssert declared(csm12ProgCliDescription)
  doAssert declared(exe_7zCliDescription)
  doAssert declared(createDmgCliDescription)
  doAssert declared(plainCliDescription)
  doAssert not declared(noCliCliDescription)
""")
    checkpoint(errorLines(named.output))
    check named.ok

    let samePackage = thinCheck("same_package", """
import reprobuild
package names:
  executable "my-prog":
    cli:
      flag x is int
  executable my_prog:
    cli:
      flag y is int
""")
    checkpoint(errorLines(samePackage.output))
    check not samePackage.ok
    check "same_package.nim(6, 14) Error: executables `my-prog` and " &
      "`my_prog` would both describe their command line as " &
      "`my_progCliDescription`" in samePackage.output

    let twoPackages = thinCheck("two_packages", """
import reprobuild
package first:
  executable "my-prog":
    cli:
      flag x is int
package second:
  executable myProg:
    cli:
      flag y is int
""")
    checkpoint(errorLines(twoPackages.output))
    check not twoPackages.ok
    check "two_packages.nim(7, 14) Error: executable `myProg`: " &
      "`myProgCliDescription`, the template that describes its command " &
      "line, is already declared in this module" in twoPackages.output

    # A module importing another's template of the same name declares its
    # own: no collision.
    discard thinCheck("first_module", """
import reprobuild
package first:
  executable "my-prog":
    cli:
      flag x is int
""")
    let imported = thinCheck("imports_first", """
import reprobuild
import first_module
package second:
  executable myProg:
    cli:
      flag y is int
""")
    checkpoint(errorLines(imported.output))
    check imported.ok

  test "negative control: the bodies the thin mode skips do not compile":
    # In the evaluation mode the fixture's `uses:` entry fails, and with it
    # removed, its `build:` body does: each body is broken, so the programs
    # compile only because the thin mode does not compile them.
    proc evalCheck(dir: string): tuple[ok: bool; output: string] =
      var command = @["nim", "check", "--hints:off", "--warnings:off",
        "--skipParentCfg", ReproEvalModeFlag]
      command.add(compileFlags())
      command.add(dir / "repro.nim")
      let (output, code) = execCmdEx(quoteShellCommand(command),
        workingDir = dir)
      (code == 0, output)

    let asIs = evalCheck(project)
    checkpoint(errorLines(asIs.output))
    check not asIs.ok
    check ("undeclared identifier: '" & UsesMarker & "'") in asIs.output
    check "cannot open file" notin asIs.output

    let usesRemoved = scratchRoot / "uses-removed"
    copyFixture(usesRemoved)
    let source = readFile(usesRemoved / "repro.nim")
    require ("    " & UsesMarker & "\n") in source
    writeFile(usesRemoved / "repro.nim",
      source.replace("    " & UsesMarker & "\n", ""))
    let buildOnly = evalCheck(usesRemoved)
    checkpoint(errorLines(buildOnly.output))
    check not buildOnly.ok
    check ("undeclared identifier: '" & BuildMarker & "'") in buildOnly.output
    check "cannot open file" notin buildOnly.output

if getEnv("REPRO_CS_M12_KEEP") != "1":
  removeDirEventually(scratchRoot)
