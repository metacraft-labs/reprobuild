## A package build writes the shell completion files of every executable whose
## `repro.nim` declaration has a `cli:` section, from the description and the
## entry list its compile writes, without running the executable.
##
## The fixture package (`tests/fixtures/cs_m14_completion_files`, copied to a
## scratch directory so it is a project outside this tree) builds three
## programs with `nim.c`, each instantiating its `cli:` section through the
## `<name>CliDescription` template of the thin `repro.nim`:
##
## * `csm14-describe`, with nim-entrypoints' `describeProgram`;
## * `csm14-entries`, with nim-entrypoints' `main:` but no `describeProgram`;
## * `csm14-plain`, without nim-entrypoints.
##
## Each case runs the real `repro build` on it and reads the build report and
## the tree:
##
##   1. each program's compile wrote its entry list when the program uses
##      nim-entrypoints (`build/entrypoints/<program>.entrypoints.json`, so
##      the compile was given `-d:entrypointsManifest`) and none otherwise;
##      its completion edge (`<compile id>.completion-files`) wrote
##      `build/completions/<program>/{<program>.bash,_<program>,
##      <program>.fish,<program>.ps1}`; `csm14-describe`'s call
##      `--entrypoint=complete`, the others' clispec's `__complete`; each
##      file is byte-equal to what the binary itself prints for that shell
##      (`--entrypoint=completion <shell>` for `csm14-describe`, the
##      program's own `completionScript` for the others), on this host; the
##      edge's evidence names no binary, neither declared nor read, and does
##      name the entry list (read when present, probed when absent); a second
##      build serves every completion edge from the cache;
##   2. with `csm14-describe`'s link replaced by a script that writes a text
##      file (not executable, not a program) where the binary goes, the way a
##      binary for another machine cannot run on the build host, the build
##      still writes its four files, byte-equal to those of a project whose
##      `csm14-describe` is a real program; then, with `describeProgram`
##      removed from the program, its compile writes a list without
##      `complete` and the edge reruns: its files now call `__complete`.
##
## Case 1's evidence check catches the edge READING the binary. It cannot
## catch the edge RUNNING it: a child started through `posix_spawn` (what
## Nim's `osproc` uses) reaches the evidence as a spawn record, which names
## the child for attribution but is not an input of the edge. Case 2 is what
## catches that: the binary there cannot be run, so an edge that ran it would
## fail.
##
## Negative control (case 3): the same package with `csm14-describe`'s `cli:`
## section removed (its program then has no description, but still uses
## nim-entrypoints' `main:`) has no completion edge for it, writes no
## completion files and no entry list for it; the other two keep theirs.
##
## Case 4: a second Nim compile writing a file named `csm14-plain` (in
## another directory) makes the build fail before anything runs, naming both
## compiles, since the two would write one set of files. Within one package
## the DSL's implicit-target rule (one target name per file basename) refuses
## it first; the provider's own refusal of two compiles of one `cli:`
## executable stands behind it for a compile that registers no implicit
## target.
##
## clispec and nim-entrypoints are found as this repository's `config.nims`
## finds them (the `../nim-cli-spec` and `../nim-entrypoints` checkouts, else
## `$CLI_SPEC_SRC` and `$ENTRYPOINTS_SRC`; `REPRO_SIBLING_POLICY=pin` takes
## the variables even when the checkouts exist).
##
## MOCKS: none. The real `repro` of this build compiles the fixture's recipe
## and the programs with the real Nim, and runs the real
## `repro-completion-files` under the io monitor. Case 2's linker is a
## shell script (`tools/link-text.sh`) that writes a text file: the binary
## the build host cannot run is what that case varies, and no cross
## toolchain is assumed on the host.

import std/[json, os, strtabs, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/process_fixtures

const
  FixtureDir = ReprobuildRepoRoot / "tests" / "fixtures" /
    "cs_m14_completion_files"
  Programs = ["csm14-describe", "csm14-entries", "csm14-plain"]
  Describe = "csm14-describe"
  Shells = ["bash", "zsh", "fish", "powershell"]
  DescribeEntry = "--entrypoint=complete"
  ClispecEntry = "__complete"
  DescribeCli = """    cli:
      help "The fixture's program that describes itself"
      flag jobs is int, default = 2, help = "How many jobs to run"
      subcmd "greet", help = "Print a greeting":
        pos who is string, help = "Whom to greet"
"""
  DescribeProgramLine = "  describeProgram(Csm14Describe)\n"
  NotABinary = "not a program: the completion edge must not need one\n"
  BuildLoopEnd = "        actionId = \"csm14.compile.\" & program)\n"
  DuplicateCompile = """    discard nim.c(
      source = "src/csm14_plain.nim",
      binary = "build/other/csm14-plain",
      paths = @[ClispecSrc, EntrypointsSrc, ReproDslSrc],
      nimcache = "build/nimcache/csm14-plain-other",
      skipUserCfg = true,
      actionId = "csm14.compile.csm14-plain-other")
"""

proc siblingSrc(sibling, variable, marker: string): string =
  ## A sibling's `src/`, as this repository's `config.nims` finds it: the
  ## `../<sibling>` checkout, else `$<variable>`, and `$<variable>` first
  ## under `REPRO_SIBLING_POLICY=pin`.
  let pinned = getEnv(variable)
  if getEnv("REPRO_SIBLING_POLICY") == "pin" and pinned.len > 0:
    return pinned
  let checkout = ReprobuildRepoRoot.parentDir / sibling / "src"
  if fileExists(checkout / marker):
    return checkout
  pinned

proc fileName(shell, program: string): string =
  ## The completion file of `shell` for `program`, as reprobuild's own
  ## release names its scripts.
  case shell
  of "bash": program & ".bash"
  of "zsh": "_" & program
  of "fish": program & ".fish"
  else: program & ".ps1"

type Project = object
  scratch: string
  root: string
  reportDir: string

proc completionDir(p: Project; program: string): string =
  p.root / "build" / "completions" / program

proc entryList(p: Project; program: string): string =
  p.root / "build" / "entrypoints" / (program & ".entrypoints.json")

proc binary(p: Project; program: string): string =
  p.root / "build" / "bin" / addFileExt(program, ExeExt)

proc completionId(program: string): string =
  "csm14.compile." & program & ".completion-files"

proc projectWith(describeCli = true; textLink = false;
                 duplicate = false): Project =
  ## A scratch copy of the fixture with its placeholders filled in; without
  ## `describeCli`, `csm14-describe`'s `cli:` section is removed; with
  ## `textLink`, `csm14-describe`'s link writes a text file; with
  ## `duplicate`, a second compile writes `build/other/csm14-plain`.
  let clispec = siblingSrc("nim-cli-spec", "CLI_SPEC_SRC", "clispec.nim")
  let entrypoints = siblingSrc("nim-entrypoints", "ENTRYPOINTS_SRC",
    "entrypoints.nim")
  doAssert fileExists(clispec / "clispec.nim"), "nim-cli-spec not found: " &
    "no ../nim-cli-spec beside this checkout and no $CLI_SPEC_SRC"
  doAssert fileExists(entrypoints / "entrypoints" / "describe.nim"),
    "nim-entrypoints not found: no ../nim-entrypoints beside this checkout " &
    "and no $ENTRYPOINTS_SRC"
  result.scratch = expandFilename(createTempDir("cs-m14-completion-", ""))
  releaseDirAtProcessExit(result.scratch)
  result.root = result.scratch / "project"
  result.reportDir = result.scratch / "reports"
  createDir(result.root / "src")
  createDir(result.reportDir)
  let backend = when defined(macosx): "clang" else: "gcc"
  var recipe = readFile(FixtureDir / "repro.nim")
    .replace("__CLISPEC_SRC__", clispec)
    .replace("__ENTRYPOINTS_SRC__", entrypoints)
    .replace("__REPRO_DSL_SRC__",
      ReprobuildRepoRoot / "libs" / "repro_project_dsl" / "src")
    .replace("__NATIVE_BACKEND__", backend)
    .replace("__DESCRIBE_LINKER__",
      if textLink: result.root / "tools" / "link-text.sh" else: "")
  doAssert DescribeCli in recipe
  if not describeCli:
    recipe = recipe.replace(DescribeCli, "")
  if duplicate:
    doAssert BuildLoopEnd in recipe
    recipe = recipe.replace(BuildLoopEnd, BuildLoopEnd & DuplicateCompile)
  writeFile(result.root / "repro.nim", recipe)
  for kind, path in walkDir(FixtureDir / "src"):
    if kind == pcFile:
      copyFile(path, result.root / "src" / path.extractFilename)
  createDir(result.root / "tools")
  let linker = result.root / "tools" / "link-text.sh"
  copyFile(FixtureDir / "tools" / "link-text.sh", linker)
  setFilePermissions(linker, {fpUserRead, fpUserWrite, fpUserExec})

proc reproBuild(p: Project; label: string; selectors: openArray[string] = []):
    tuple[code: int; report: JsonNode; output: string] =
  ## `repro build [selectors]` in the project, with this checkout's `repro`
  ## and DSL, and the report it writes.
  let repoRoot = ReprobuildRepoRoot
  let reproBin = requireBinary(reproBinaryPath(repoRoot),
    "reprobuild.apps.repro")
  discard requireBinary(repoRoot / "build" / "bin" /
    addFileExt("repro-completion-files", ExeExt),
    "reprobuild.apps.repro-completion-files")
  let shim = requireBinary(monitorShimPath(repoRoot),
    "reprobuild.test_fixtures.monitor_shim")
  let env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  env["REPROBUILD_REPO_ROOT"] = repoRoot
  env["REPROBUILD_LIBS_DIR"] = repoRoot / "libs"
  env["REPRO_MONITOR_SHIM_LIB"] = shim
  env.del("LD_PRELOAD")
  let reportPath = p.reportDir / (label & ".json")
  var args = @["build", "--daemon=off", "--tool-provisioning=path",
    "--no-runquota", "--progress=quiet",
    "--work-root=" & (p.scratch / "work"),
    "--action-cache-root=" & (p.scratch / "cache"),
    "--write-report=" & reportPath]
  args.add(@selectors)
  let run = runProgramSplit(reproBin, args, p.root, env)
  checkpoint("repro " & args.join(" ") & " -> exit " & $run.code)
  if run.code != 0:
    checkpoint(run.stdout & run.stderr)
  result.code = run.code
  result.output = run.stdout & run.stderr
  result.report =
    if fileExists(reportPath): parseFile(reportPath) else: newJNull()

proc action(report: JsonNode; id: string): JsonNode =
  if report.kind == JObject:
    for entry in report{"actions"}:
      if entry{"id"}.getStr() == id:
        return entry
  newJNull()

proc evidencePaths(entry: JsonNode; channel: string): seq[string] =
  for path in entry{"evidence"}{channel}:
    result.add(path.getStr())

proc names(paths: openArray[string]; tail: string): bool =
  ## Whether a path in `paths` ends with `tail` (a path below the project).
  for path in paths:
    if path.replace('\\', '/').endsWith("/" & tail):
      return true
  false

proc printedScript(p: Project; program, shell: string): string =
  ## What `program`'s binary prints as its completion script for `shell`.
  let args =
    if program == Describe: @["--entrypoint=completion", shell]
    else: @["--printCompletion=" & shell]
  let run = runProgramSplit(p.binary(program), args, p.root,
    newStringTable(modeCaseSensitive))
  checkpoint(program & " " & args.join(" ") & " -> exit " & $run.code &
    " " & run.stderr)
  doAssert run.code == 0
  run.stdout

proc checkFiles(p: Project; program, entry: string) =
  ## `program`'s four files exist, each calls `entry` and not the other
  ## word.
  let other = if entry == DescribeEntry: ClispecEntry else: DescribeEntry
  for shell in Shells:
    let path = p.completionDir(program) / fileName(shell, program)
    checkpoint(path)
    check fileExists(path)
    if fileExists(path):
      let text = readFile(path)
      check entry in text
      check other notin text
      check program in text

suite "test_cs_m14_package_build_generates_completion_files":

  test "each cli: executable gets four files from its description":
    let p = projectWith()
    let first = p.reproBuild("first")
    check first.code == 0

    # The compile wrote an entry list exactly when the program uses
    # nim-entrypoints: it was given the define.
    check fileExists(p.entryList(Describe))
    check fileExists(p.entryList("csm14-entries"))
    check not fileExists(p.entryList("csm14-plain"))
    check "\"complete\"" in readFile(p.entryList(Describe))
    check "\"complete\"" notin readFile(p.entryList("csm14-entries"))

    p.checkFiles(Describe, DescribeEntry)
    p.checkFiles("csm14-entries", ClispecEntry)
    p.checkFiles("csm14-plain", ClispecEntry)

    for program in Programs:
      # Byte-equal, on this host, to what the binary prints.
      for shell in Shells:
        let path = p.completionDir(program) / fileName(shell, program)
        checkpoint(program & " " & shell)
        check fileExists(path) and
          readFile(path) == p.printedScript(program, shell)
      let edge = first.report.action(completionId(program))
      checkpoint(program & " edge: " & $edge)
      check edge{"status"}.getStr() == "asSucceeded"
      check edge{"launched"}.getBool()
      # The edge never names the binary: not as a declared input and not as
      # anything the monitor saw it read or probe.
      let binaryTail = "build/bin/" & addFileExt(program, ExeExt)
      for channel in ["declaredInputs", "monitorReads", "monitorProbes"]:
        checkpoint(channel & ": " & $edge.evidencePaths(channel))
        check not edge.evidencePaths(channel).names(binaryTail)
      # It does name the entry list: read when the compile wrote one,
      # found absent otherwise, so either way the list is in its key.
      let listTail = "build/entrypoints/" & program & ".entrypoints.json"
      if program == "csm14-plain":
        check edge.evidencePaths("monitorProbes").names(listTail) or
          edge.evidencePaths("monitorReads").names(listTail)
      else:
        check edge.evidencePaths("monitorReads").names(listTail)

    # Nothing changed: every completion edge is served from the cache.
    let second = p.reproBuild("second")
    check second.code == 0
    for program in Programs:
      let edge = second.report.action(completionId(program))
      checkpoint(program & " second: " & $edge)
      check edge{"status"}.getStr() in ["asUpToDate", "asCacheHit"]
      check not edge{"launched"}.getBool(true)

  test "the edge needs no binary, and follows the entry list":
    # A project whose `csm14-describe` is a real program: the files it
    # should get.
    let real = projectWith()
    check real.reproBuild("real").code == 0
    var expected: seq[string]
    for shell in Shells:
      expected.add(real.printedScript(Describe, shell))
    # The same project, with a binary that cannot run.
    let p = projectWith(textLink = true)
    let built = p.reproBuild("text-binary")
    check built.code == 0
    check readFile(p.binary(Describe)) == NotABinary
    check fpUserExec notin getFilePermissions(p.binary(Describe))
    let edge = built.report.action(completionId(Describe))
    checkpoint("text-binary edge: " & $edge)
    check edge{"status"}.getStr() == "asSucceeded"
    check edge{"launched"}.getBool()
    for i, shell in Shells:
      let path = p.completionDir(Describe) / fileName(shell, Describe)
      checkpoint(path)
      check fileExists(path) and readFile(path) == expected[i]

    # Without `describeProgram` the compile lists no `complete` entry, and
    # the edge, keyed on what it read, writes `__complete` files.
    let source = real.root / "src" / "csm14_describe.nim"
    let program = readFile(source)
    doAssert DescribeProgramLine in program
    writeFile(source, program.replace(DescribeProgramLine, ""))
    let edited = real.reproBuild("no-describe")
    check edited.code == 0
    check "\"complete\"" notin readFile(real.entryList(Describe))
    let rerun = edited.report.action(completionId(Describe))
    checkpoint("no-describe edge: " & $rerun)
    check rerun{"launched"}.getBool()
    real.checkFiles(Describe, ClispecEntry)

  test "negative control: without a cli: section there is no edge and no file":
    let p = projectWith(describeCli = false)
    let built = p.reproBuild("no-cli")
    check built.code == 0
    check built.report.action("csm14.compile." & Describe){"status"}.getStr() ==
      "asSucceeded"
    check built.report.action(completionId(Describe)).kind == JNull
    check not dirExists(p.completionDir(Describe))
    check not fileExists(p.entryList(Describe))
    # Control: the other two still get theirs.
    p.checkFiles("csm14-entries", ClispecEntry)
    p.checkFiles("csm14-plain", ClispecEntry)
    check fileExists(p.entryList("csm14-entries"))

  test "two compiles of one cli: executable are refused, naming both":
    let p = projectWith(duplicate = true)
    let built = p.reproBuild("duplicate")
    check built.code != 0
    check "'csm14.compile.csm14-plain'" in built.output or
      "csm14.compile.csm14-plain," in built.output
    check "csm14.compile.csm14-plain-other" in built.output
    # Refused while the graph is built: nothing ran, nothing was written.
    check not dirExists(p.completionDir("csm14-plain"))
    check not fileExists(p.binary("csm14-plain"))
