## Shared fixtures for the ``t_packaging_*`` suites.
##
## NOT named ``t_*`` / ``test_*`` on purpose: ``scripts/generate_test_edges.nim``
## discovers tests by file-name stem, so a helper carrying either prefix
## would be compiled and run as its own (empty) test binary. See the same
## note on ``lock_file_compile_probe.nim``.
##
## Every assertion helper below uses ``doAssert``, never ``check``.
## Stock Nim 2.2.8's ``unittest.fail`` takes the ``setProgramResult 1``
## branch when it fires outside a ``test`` body, so a ``check`` in a
## helper proc prints "Check failed" and the case still reports ``[OK]``
## — a silently passing test, which is worse than no test.

import std/[os, strutils]

import repro_project_dsl
import repro_dsl_stdlib/packaging

const
  SampleUpgradeCode* = "{6E2A9B84-3C1D-4F57-9A20-7D5E8C41B0F3}"

proc argvOf*(act: BuildActionDef): seq[string] =
  ## Render the recorded CLI call the way the engine does: a ``concat``
  ## flag joins its alias to its value, a bool flag contributes its alias
  ## alone, a positional contributes its value alone, and a ``repeated``
  ## seq flag contributes one occurrence per element (``cliArgSeq`` packs
  ## them into a single ``\x1f``-joined ``encodedValue``).
  ##
  ## Copied in shape from ``t_nim_c_cpu_flag.nim``'s helper, and for the
  ## same reason: the wrapper's PARAMETERS are what the caller asked
  ## for, argv is what the tool will actually receive, and only the
  ## second one can be wrong.
  for arg in act.call.arguments:
    var values = @[arg.encodedValue]
    if arg.nimType == "seq[string]":
      values = arg.encodedValue.split('\x1f')
      if values.len == 1 and values[0].len == 0:
        values = @[]
    for value in values:
      case arg.format
      of cafConcat:
        result.add(arg.alias & value)
      else:
        if arg.alias.len == 0:
          result.add(value)
        elif arg.nimType == "bool":
          result.add(arg.alias)
        else:
          result.add(arg.alias)
          result.add(value)

proc edgesInvoking*(pkg: string): seq[BuildActionDef] =
  ## Every recorded edge whose typed-tool call names ``pkg``.
  for act in registeredBuildActions():
    if act.call.packageName == pkg: result.add(act)

proc writtenText*(outputSubstring: string): string =
  ## The text a ``fs.writeText`` edge was asked to write, located by a
  ## substring of its output path.
  ##
  ## Reading the recorded EDGE rather than re-calling the renderer is
  ## what makes a case a test of the staging path: a bug that rendered
  ## correctly but staged the result at the wrong path, or for the wrong
  ## component, would still let a direct call to the renderer pass.
  for act in registeredBuildActions():
    if act.call.subcommand != "writeText": continue
    var matches = false
    var text = ""
    for arg in act.call.arguments:
      if arg.name == "output" and arg.encodedValue.contains(outputSubstring):
        matches = true
      if arg.name == "text":
        text = arg.encodedValue
    if matches: return text
  ""

proc sampleDistribution*(targetOs: TargetOs;
                         withService = true): Distribution =
  ## The M0 gate's shape: two binaries, the §5 contract, one service.
  ##
  ## Deliberately mirrors ``tests/fixtures/packaging/two-binary-dist/repro.nim``
  ## rather than importing it. The fixture is a RECIPE — evaluating it
  ## registers a package and compiles two binaries — and a unit suite
  ## that had to do either would be an integration test wearing a unit
  ## test's clothes.
  let sfx = (if targetOs == toWindows: ".exe" else: "")
  result = newDistribution("sampletool", "0.2.0", targetOs,
    prefix = (if targetOs == toWindows: "" else: "/usr"),
    layout = (if targetOs == toWindows: plWindowsTree else: plUnix))
  result.runtime.envDefaults = @[
    ("SAMPLETOOL_DATA_DIR", "@PREFIX@/share/sampletool"),
    ("SAMPLETOOL_MODE", "packaged")
  ]
  result.runtime.privateLibSubdir = "lib/sampletool"
  result.runtime.wrapExecutables = true
  result.components = @[
    executableComponent("build/bin/hello" & sfx),
    executableComponent("build/bin/adder" & sfx)
  ]
  if withService:
    result.services = @[
      ServiceDef(
        name: "sampletool-daemon",
        displayName: "Sample Tool Daemon",
        description: "M0 packaging fixture service",
        scope: ssSystem,
        execComponent: "hello" & sfx,
        execArgs: @["--serve"],
        environment: @[("SAMPLETOOL_ROLE", "daemon")],
        startAtBoot: false,
        restartOnFailure: true,
        after: @["network.target"])
    ]
  result.metadata = DistMetadata(
    summary: "Reprobuild packaging-layer sample tool",
    description: "A trivial two-binary distribution.\nSecond paragraph.",
    maintainer: "Reprobuild Developers <dev@reprobuild.invalid>",
    vendor: "Reprobuild",
    license: "MIT",
    homepage: "https://github.com/metacraft-labs/reprobuild",
    section: "devel",
    priority: "optional",
    upgradeCode: SampleUpgradeCode)

proc stagedRelPaths*(tree: StagedTree): seq[string] =
  for f in tree.files: result.add(f.rootRelPath)

proc repoRootFromTest*(): string =
  ## Path to the repository root, derived from this module's own source
  ## location rather than from the working directory.
  ##
  ## A test binary's cwd is not guaranteed: the suite runner, a direct
  ## invocation and an IDE all differ. ``currentSourcePath`` is fixed at
  ## compile time and this file's depth below the root is a fact of the
  ## repository layout, so the derivation cannot drift with the runner.
  var dir = currentSourcePath()
  # .../libs/repro_dsl_stdlib/tests/packaging_test_support.nim
  for _ in 0 .. 3:
    let cut = max(dir.rfind('/'), dir.rfind('\\'))
    doAssert cut > 0,
      "cannot derive the repository root from " & currentSourcePath()
    dir = dir[0 ..< cut]
  dir

# ---------------------------------------------------------------------------
# The reprobuild derivation, read as text -- ONCE, for every suite.
# ---------------------------------------------------------------------------
#
# The ``--set-default`` wrapper contract used to live inline in
# ``flake.nix``, and three readers transcribed that path separately:
# ``t_packaging_wrapper_vars_match_flake``, ``t_packaging_reprobuild_dist``
# and ``scripts/check_repo_requirements.sh``. Distribution-And-Packaging
# M4 moved the contract into the nixpkgs-format derivation and repointed
# two of the three. The third went on reading ``flake.nix``, found two
# comments where twenty operands used to be, and went red on a contract
# that had not changed at all.
#
# The shell gate keeps its own copy because it is a different language.
# The two Nim suites do not, and no longer do: the path is a constant
# here and the extractor is a proc here, so the next move is one edit
# rather than a scavenger hunt with a red test at the end of it.

const PackageNixPath* = "/nix/pkgs/by-name/re/reprobuild/package.nix"
  ## Where the reprobuild derivation lives, relative to the repository
  ## root. If it moves again, it moves HERE, once.

proc packageNixText*(): string =
  ## The text of the reprobuild derivation.
  let path = repoRootFromTest() & PackageNixPath
  doAssert fileExists(path),
    "the reprobuild derivation is not at " & path &
    "; if it moved, change PackageNixPath in packaging_test_support " &
    "rather than in each suite that reads it"
  result = readFile(path)
  doAssert result.len > 0,
    "the reprobuild derivation at " & path & " is empty"

proc packageNixWrapperVariables*(): seq[string] =
  ## The ``--set-default NAME`` operands of the derivation's
  ## ``postFixup`` ``wrapProgram`` loop, in source order, without
  ## repeats.
  ##
  ## NON-VACUITY IS THE EXTRACTOR'S OWN POST-CONDITION, deliberately,
  ## rather than something each caller remembers to guard. This is a text
  ## scan, so the failure it is likeliest to have is matching NOTHING --
  ## the loop moved again, or an unrelated reformat broke the shape --
  ## and every caller either iterates the result or compares its length,
  ## so every caller would pass over an empty seq exactly as quietly as
  ## over a correct one. That is the false green the guard exists to make
  ## impossible, and stating it here is what extends it to the reader
  ## that has not been written yet.
  for line in packageNixText().splitLines():
    let trimmed = line.strip()
    if not trimmed.startsWith("--set-default "):
      continue
    let rest = trimmed["--set-default ".len .. ^1].strip()
    var name = ""
    for ch in rest:
      if ch == ' ' or ch == '\t': break
      name.add(ch)
    if name.len > 0 and name notin result:
      result.add(name)
  doAssert result.len > 0,
    "no '--set-default NAME' operand was found in " &
    repoRootFromTest() & PackageNixPath &
    "; the wrapper contract has moved or been reformatted, and every " &
    "suite that reads it would otherwise pass over an empty list"
