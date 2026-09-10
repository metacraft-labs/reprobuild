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

import std/[strutils]

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
