## `repro-cmake-dyndep-fragment` is a program described in reprobuild's root
## `repro.nim`: it parses its command line with clispec from that file's
## `cli:` section, in nim-entrypoints' `main:`, and registers the
## self-description entries.
##
## The program (`apps/repro-cmake-dyndep-fragment`) is compiled from this
## checkout, in place, the way `just build` and the `apps` graph edge
## compile it: its main module is in the tree, so this repository's
## `config.nims` (which defines `reproEvalMode`) is read, and the program's
## own `repro_cmake_dyndep_fragment.nims` removes the define again. The
## binary goes to a scratch directory. The cases:
##
##   1. the argv the Reprobuild CMake generator's dyndep wrapper writes
##      (`--out <fragment> --map <map> <ddi>...`) is accepted and writes the
##      exact fragment, printing nothing and exiting 0; a missing input still
##      fails with exit 1 and the program's one-line message on stderr, and
##      writes no fragment. The same compile's `Processing` hints name the
##      root `repro.nim` and none of the recipe's engine-only code
##      (`repro_recipe_support.nim`);
##   2. a command line clispec rejects (no arguments, an unknown flag, a
##      flag without its value, an empty path, no scanner output) exits with
##      clispec's usage code, 2, with clispec's error block on stderr and
##      nothing on stdout, and writes no fragment;
##   3. `--help` prints the description's help on stdout and exits 0; the
##      internal `--entrypoint` parameter is not in it;
##   4. `--entrypoint=list` prints an `entrypoints/1` document naming `main`
##      and the four self-description entries (`complete`, `completion`,
##      `help-json`, `config-schema`);
##   5. a package build gives it round 7's completion files: a scratch
##      package whose `repro.nim` carries this executable's declaration
##      copied verbatim from the root `repro.nim`, built by the real `repro
##      build` from the program's own source, gets the four files under
##      `build/completions/repro-cmake-dyndep-fragment/`, each calling
##      `--entrypoint=complete` and byte-equal to what the built binary
##      prints for `--entrypoint=completion <shell>`.
##
## Negative control (case 6): the same compile with `-d:reproEvalMode` fails
## on the program's own `static` check that `repro.nim` compiles in the thin
## mode, naming the mode, before the root `repro.nim` (and with it the
## engine) is compiled.
##
## clispec and nim-entrypoints are found as this repository's `config.nims`
## finds them (the `../nim-cli-spec` and `../nim-entrypoints` checkouts, else
## `$CLI_SPEC_SRC` and `$ENTRYPOINTS_SRC`; `REPRO_SIBLING_POLICY=pin` takes
## the variables even when the checkouts exist).
##
## MOCKS: none. The real Nim compiles the real program; case 5 runs this
## build's `repro` and `repro-completion-files` under the io monitor. The
## scanner outputs of case 1 are written by the test in the P1689 shape
## CMake's scanner writes; no compiler that scans C++ modules is assumed on
## the host.

import std/[json, os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/process_fixtures

const
  Program = "repro-cmake-dyndep-fragment"
  AppDir = ReprobuildRepoRoot / "apps" / Program
  Source = AppDir / "repro_cmake_dyndep_fragment.nim"
  ProgramCfg = AppDir / "repro_cmake_dyndep_fragment.nims"
  RootRecipe = ReprobuildRepoRoot / "repro.nim"
  IncludedRecipe = ReprobuildRepoRoot / "repro_recipe_support.nim"
  UsageExitCode = 2
  Shells = ["bash", "zsh", "fish", "powershell"]
  DescribeEntries = ["complete", "completion", "help-json", "config-schema"]
  ThinCheckMessage = "must import reprobuild's repro.nim in the DSL's thin mode"
  ExecutableLine = "  executable reproCmakeDyndepFragment:"
  CompileId = "csm14.idiomatic.compile"

proc siblingSrc(sibling, variable, marker: string): string =
  ## A sibling's `src/`, as this repository's `config.nims` finds it.
  let pinned = getEnv(variable)
  if getEnv("REPRO_SIBLING_POLICY") == "pin" and pinned.len > 0:
    return pinned
  let checkout = ReprobuildRepoRoot.parentDir / sibling / "src"
  if fileExists(checkout / marker):
    return checkout
  pinned

proc scratchDir(label: string): string =
  ## A fresh scratch directory, removed when this process exits.
  result = expandFilename(createTempDir("cs-m14-idiomatic-" & label & "-", ""))
  releaseDirAtProcessExit(result)

type Compiled = object
  ok: bool
  output: string
  modules: seq[string]
  binary: string

proc compileProgram(scratch: string; extra: openArray[string] = []):
    Compiled =
  ## `nim c` of the program in place (its directory as the working
  ## directory, as the `apps` edge runs it), into `scratch`, with only the
  ## `Processing` hint.
  result.binary = scratch / "bin" / addFileExt(Program, ExeExt)
  var args = @["nim", "c", "--hint:all:off", "--hint:Processing:on",
    "--processing:filenames", "--warnings:off", "--define:release",
    "--parallelBuild:4", "--nimcache:" & (scratch / "nimcache"),
    "--out:" & result.binary]
  args.add(@extra)
  args.add(Source)
  let (output, code) = execCmdEx(quoteShellCommand(args), workingDir = AppDir)
  result.ok = code == 0
  result.output = output
  result.modules = nimProcessedModules(result.output)
  if not result.ok:
    checkpoint(result.output)

proc builtProgram(scratch: string): string =
  ## The program compiled into `scratch`; the case fails if it does not
  ## compile.
  let c = compileProgram(scratch)
  doAssert c.ok, "the program did not compile:\n" & c.output
  c.binary

proc run(binary: string; args: openArray[string]; cwd: string):
    CmdSplitResult =
  result = runProgramSplit(binary, args, cwd)
  checkpoint(Program & " " & args.join(" ") & " -> exit " & $result.code &
    "\nstdout: " & result.stdout & "\nstderr: " & result.stderr)

proc writeInputs(dir: string) =
  ## An action map and two scanner outputs: `a.ddi` provides module `A`,
  ## `b.ddi` (its primary output spelled with Windows separators, as CMake
  ## writes it there) requires it.
  writeFile(dir / "actions.map",
    "obj/a.o\tcompile-a\nobj/b.o\tcompile-b\n")
  writeFile(dir / "a.ddi", $(%*{"version": 1, "rules": [{
    "primary-output": "obj/a.o",
    "provides": [{"logical-name": "A",
                  "compiled-module-path": "mods\\A.pcm"}],
    "requires": []}]}))
  writeFile(dir / "b.ddi", $(%*{"version": 0, "rules": [{
    "primary-output": "obj\\b.o",
    "requires": [{"logical-name": "A"}]}]}))

const ExpectedFragment = "repro-dynamic-graph-v1\n" &
  "output\tcompile-a\tmods/A.pcm\n" &
  "dep\tcompile-b\tcompile-a\n"

proc executableBlock(): string =
  ## This executable's declaration in the root `repro.nim`, verbatim: its
  ## `executable` line and every line indented deeper that follows it.
  let lines = readFile(RootRecipe).splitLines()
  let at = lines.find(ExecutableLine)
  doAssert at >= 0, "no `" & ExecutableLine.strip & "` in " & RootRecipe
  var kept = @[lines[at]]
  for i in at + 1 ..< lines.len:
    let line = lines[i]
    if line.len > 0 and not line.startsWith("    "):
      break
    kept.add(line)
  while kept[^1].len == 0:
    kept.setLen(kept.len - 1)
  kept.join("\n") & "\n"

suite "test_cs_m14_idiomatic_program":

  test "the CMake wrapper's argv is accepted, with the same behaviour":
    let scratch = scratchDir("argv")
    let c = compileProgram(scratch)
    check c.ok
    # Thin: the root repro.nim is compiled, its engine-only part is not.
    check RootRecipe in c.modules
    check IncludedRecipe notin c.modules
    check (ReprobuildRepoRoot / "libs" / "repro_dsl_stdlib") notin
      c.modules.join("\n")
    if c.ok:
      let work = scratch / "work"
      createDir(work)
      writeInputs(work)
      let fragment = work / "out" / "dyndep" / "app-CXX.rbdyn"
      let ok = run(c.binary, ["--out", fragment, "--map", "actions.map",
        "a.ddi", "b.ddi"], work)
      check ok.code == 0
      check ok.stdout == ""
      check ok.stderr == ""
      check fileExists(fragment) and readFile(fragment) == ExpectedFragment

      # An input the program cannot read: exit 1, its message, no fragment.
      let noMap = work / "no-map.rbdyn"
      let missing = run(c.binary, ["--out", noMap, "--map", "absent.map",
        "a.ddi"], work)
      check missing.code == 1
      check missing.stdout == ""
      check missing.stderr == Program & ": action map missing: absent.map\n"
      check not fileExists(noMap)

      let noProvider = work / "no-provider.rbdyn"
      let unresolved = run(c.binary, ["--out", noProvider, "--map",
        "actions.map", "b.ddi"], work)
      check unresolved.code == 1
      check unresolved.stdout == ""
      check unresolved.stderr == Program & ": module requirement has no " &
        "provider in selected scanner output: A\n"
      check not fileExists(noProvider)

  test "a command line clispec rejects is a usage error":
    let scratch = scratchDir("usage")
    let binary = builtProgram(scratch)
    let work = scratch / "work"
    createDir(work)
    writeInputs(work)
    let fragment = work / "frag.rbdyn"
    for (args, message) in [
        (newSeq[string](), "error: missing required parameter"),
        (@["--bogus", "--out", fragment, "--map", "actions.map", "a.ddi"],
         "error: unknown flag '--bogus' for '" & Program & "'"),
        (@["--map", "actions.map", "a.ddi", "--out"],
         "error: flag '--out' of '" & Program & "' needs a value"),
        (@["--out", "", "--map", "actions.map", "a.ddi"],
         "error: invalid value '' for '--out' of '" & Program &
           "'; expected a non-empty path"),
        (@["--out", fragment, "--map", "actions.map"],
         "error: missing required parameter")]:
      let r = run(binary, args, work)
      check r.code == UsageExitCode
      check r.stdout == ""
      check r.stderr.startsWith(message)
      check ("Usage: " & Program) in r.stderr
      check not fileExists(fragment)

  test "--help prints the description's help":
    let scratch = scratchDir("help")
    let binary = builtProgram(scratch)
    let r = run(binary, ["--help"], scratch)
    check r.code == 0
    check r.stderr == ""
    check ("Writes the dynamic graph fragment of CMake's module scanner " &
      "output") in r.stdout
    for word in ["--out", "--map", "<fragment>", "<map>", "<ddi>",
                 "The scanner outputs (.ddi) to convert"]:
      checkpoint(word)
      check word in r.stdout
    check "entrypoint" notin r.stdout

  test "--entrypoint=list names main and the describe entries":
    let scratch = scratchDir("list")
    let binary = builtProgram(scratch)
    let r = run(binary, ["--entrypoint=list"], scratch)
    check r.code == 0
    check r.stderr == ""
    let doc = parseJson(r.stdout)
    check doc{"schema"}.getStr() == "entrypoints/1"
    check doc{"default"}.getStr() == "main"
    var names: seq[string]
    for entry in doc{"entries"}:
      names.add(entry{"name"}.getStr())
    check names == @["main"] & @DescribeEntries

  test "a package build writes its completion files":
    let clispec = siblingSrc("nim-cli-spec", "CLI_SPEC_SRC", "clispec.nim")
    let entrypoints = siblingSrc("nim-entrypoints", "ENTRYPOINTS_SRC",
      "entrypoints.nim")
    doAssert fileExists(clispec / "clispec.nim"), "nim-cli-spec not found"
    doAssert fileExists(entrypoints / "entrypoints" / "describe.nim"),
      "nim-entrypoints not found"
    let scratch = scratchDir("completion")
    let root = scratch / "project"
    let appDir = root / "apps" / Program
    createDir(appDir)
    createDir(scratch / "reports")
    # The program's own source, beside a repro.nim that declares it as the
    # root repro.nim does, so its `import ../../repro` is that file.
    copyFile(Source, appDir / Source.extractFilename)
    copyFile(ProgramCfg, appDir / ProgramCfg.extractFilename)
    let backend = when defined(macosx): "clang" else: "gcc"
    let paths = [clispec, entrypoints,
      ReprobuildRepoRoot / "libs" / "repro_project_dsl" / "src",
      ReprobuildRepoRoot / "libs" / "repro_core" / "src"]
    var pathList: seq[string]
    for path in paths:
      pathList.add(path.escape)
    writeFile(root / "repro.nim",
      "import repro_project_dsl\n\n" &
      "when reproDslMode != rdmThin:\n" &
      "  import reprobuild/dsl/packages/nim as nimTool\n\n" &
      "package cs_m14_idiomatic_program:\n" &
      "  defaultToolProvisioning \"path\"\n\n" &
      "  uses:\n    \"nim\"\n    \"" & backend & "\"\n\n" &
      executableBlock() & "\n" &
      "  build:\n" &
      "    discard nim.c(\n" &
      "      source = \"apps/" & Program & "/" & Source.extractFilename &
        "\",\n" &
      "      binary = \"build/bin/" & Program & "\",\n" &
      "      paths = @[" & pathList.join(", ") & "],\n" &
      "      nimcache = \"build/nimcache/" & Program & "\",\n" &
      "      skipUserCfg = true,\n" &
      "      actionId = \"" & CompileId & "\")\n")
    checkpoint(readFile(root / "repro.nim"))

    let reproBin = requireBinary(reproBinaryPath(ReprobuildRepoRoot),
      "reprobuild.apps.repro")
    discard requireBinary(ReprobuildRepoRoot / "build" / "bin" /
      addFileExt("repro-completion-files", ExeExt),
      "reprobuild.apps.repro-completion-files")
    let shim = requireBinary(monitorShimPath(ReprobuildRepoRoot),
      "reprobuild.test_fixtures.monitor_shim")
    let env = newStringTable(modeCaseSensitive)
    for key, value in envPairs():
      env[key] = value
    env["REPROBUILD_REPO_ROOT"] = ReprobuildRepoRoot
    env["REPROBUILD_LIBS_DIR"] = ReprobuildRepoRoot / "libs"
    env["REPRO_MONITOR_SHIM_LIB"] = shim
    env.del("LD_PRELOAD")
    let reportPath = scratch / "reports" / "build.json"
    let args = @["build", "--daemon=off", "--tool-provisioning=path",
      "--no-runquota", "--progress=quiet",
      "--work-root=" & (scratch / "work"),
      "--action-cache-root=" & (scratch / "cache"),
      "--write-report=" & reportPath]
    let built = runProgramSplit(reproBin, args, root, env)
    checkpoint("repro " & args.join(" ") & " -> exit " & $built.code &
      "\n" & built.stdout & built.stderr)
    check built.code == 0

    let report = if fileExists(reportPath): parseFile(reportPath)
                 else: newJNull()
    var edge = newJNull()
    if report.kind == JObject:
      for entry in report{"actions"}:
        if entry{"id"}.getStr() == CompileId & ".completion-files":
          edge = entry
    checkpoint("completion edge: " & $edge)
    check edge{"status"}.getStr() == "asSucceeded"

    let entryList = root / "build" / "entrypoints" /
      (Program & ".entrypoints.json")
    check fileExists(entryList) and "\"complete\"" in readFile(entryList)
    let binary = root / "build" / "bin" / addFileExt(Program, ExeExt)
    let dir = root / "build" / "completions" / Program
    for shell in Shells:
      let file = case shell
        of "bash": Program & ".bash"
        of "zsh": "_" & Program
        of "fish": Program & ".fish"
        else: Program & ".ps1"
      checkpoint(dir / file)
      check fileExists(dir / file)
      if fileExists(dir / file) and fileExists(binary):
        let text = readFile(dir / file)
        check "--entrypoint=complete" in text
        check "__complete" notin text
        let printed = run(binary, ["--entrypoint=completion", shell], root)
        check printed.code == 0
        check text == printed.stdout

  test "negative control: an evaluation-mode compile fails the thin check":
    let scratch = scratchDir("eval")
    let c = compileProgram(scratch, [ReproEvalModeFlag])
    check not c.ok
    check ThinCheckMessage in c.output
    check "rdmEval" in c.output
    # The check stops the compile before the root repro.nim is imported.
    check RootRecipe notin c.modules
    check IncludedRecipe notin c.modules
    check not fileExists(c.binary)
