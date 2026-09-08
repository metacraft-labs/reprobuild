## Named-Runnable-Edges N1 verification — `repro run <run-edge-name>`
## resolves a NAMED run-edge through the same target-export-table resolver
## `repro build` uses, materializes its dependency closure, and EXECUTES
## it. A second `repro run` of the same edge is action-cache warm on the
## build step (the tool is not relaunched).
##
## Spec cite: Named-Runnable-Edges.md §3.1 / §5; the N1 milestone
## Verification `t_e2e_repro_run_named_run_edge`.
##
## The fixture registers an ordinary `app-build` target and a separately
## named `run "app-run", build = "build-app"` run-target via the N0 DSL
## surface (`repro_resources`' `run`). `build-app` is a
## typed-tool edge that copies its input to `build/app` and appends a line
## to a marker file every time it actually fires — so the marker line count
## is an exact witness of how many times the edge was *executed* vs served
## warm from the action cache. `repro run app-run` must route the bare name
## through the `tekRunEdge` export row to that edge and run it; the second
## invocation must reuse the cache (marker stays at one line).

import std/[os, strutils, tempfiles, unittest]

import repro_test_support

proc reproBinary(repoRoot: string): string =
  requireBinary(repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc writeExecutable(path, content: string) =
  createDir(path.splitPath.head)
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc writeRunTool(binDir: string) =
  ## Copies input to output and stamps a marker line each time it fires.
  when defined(windows):
    writeExecutable(binDir / "n1-tool.cmd",
      "@echo off\n" &
      "if \"%~1\"==\"--version\" (echo n1-tool 1.0.0& exit /b 0)\n" &
      "set \"input=\"\nset \"output=\"\nset \"marker=\"\nset \"forwarded=\"\n" &
      ":parse\n" &
      "if \"%~1\"==\"\" goto run\n" &
      "if \"%~1\"==\"--input\" set \"input=%~2\"& shift& shift& goto parse\n" &
      "if \"%~1\"==\"--output\" set \"output=%~2\"& shift& shift& goto parse\n" &
      "if \"%~1\"==\"--marker\" set \"marker=%~2\"& shift& shift& goto parse\n" &
      "if \"%~1\"==\"--forwarded\" set \"forwarded=%~2\"& shift& shift& goto parse\n" &
      "echo unknown arg %~1 1>&2\nexit /b 64\n" &
      ":run\n" &
      "set \"input=%input:/=\\%\"\n" &
      "set \"output=%output:/=\\%\"\n" &
      "set \"marker=%marker:/=\\%\"\n" &
      "for %%I in (\"%output%\") do if not exist \"%%~dpI\" mkdir \"%%~dpI\"\n" &
      "for %%I in (\"%marker%\") do if not exist \"%%~dpI\" mkdir \"%%~dpI\"\n" &
      "copy /Y \"%input%\" \"%output%\" >nul\n" &
      "if errorlevel 1 exit /b %errorlevel%\n" &
      "echo %output% %forwarded%>>\"%marker%\"\n")
  else:
    writeExecutable(binDir / "n1-tool",
      "#!/bin/sh\n" &
      "set -eu\n" &
      "if [ \"${1:-}\" = \"--version\" ]; then echo 'n1-tool 1.0.0'; exit 0; fi\n" &
      "input= output= marker= forwarded=\n" &
      "while [ \"$#\" -gt 0 ]; do\n" &
      "  case \"$1\" in\n" &
      "    --input) input=$2; shift 2 ;;\n" &
      "    --output) output=$2; shift 2 ;;\n" &
      "    --marker) marker=$2; shift 2 ;;\n" &
      "    --forwarded) forwarded=$2; shift 2 ;;\n" &
      "    *) echo \"unknown arg $1\" >&2; exit 64 ;;\n" &
      "  esac\n" &
      "done\n" &
      "mkdir -p \"$(dirname \"$output\")\" \"$(dirname \"$marker\")\"\n" &
      "cp \"$input\" \"$output\"\n" &
      "printf '%s %s\\n' \"$output\" \"$forwarded\" >> \"$marker\"\n")

proc writeRunEdgeProject(path: string; requiredMode = "") =
  ## A typed-tool edge (`build-app`) plus a `run "app-run", build =
  ## "build-app"` run-target naming it. `import repro_resources` brings the
  ## N0 `run` surface into recipe scope.
  let projectRoot = path.splitPath.head
  createDir(projectRoot / "reprobuild" / "packages")
  writeFile(projectRoot / "reprobuild" / "packages" / "n1_tool.nim",
    "import repro_project_dsl\n\n" &
    "defineCliInterface n1Tool, \"n1-tool\":\n" &
    "  call:\n" &
    "    flag input is string, alias = \"--input\", role = input, required = true\n" &
    "    flag output is string, alias = \"--output\", role = output, required = true\n" &
    "    flag marker is string, alias = \"--marker\", required = true\n" &
    "    outputs output\n")
  writeFile(projectRoot / "reprobuild" / "packages" / "unused_tool.nim",
    "import repro_project_dsl\n\n" &
    "defineCliInterface unusedTool, \"unused-tool\":\n" &
    "  call:\n" &
    "    flag output is string, alias = \"--output\", role = output\n" &
    "    outputs output\n")
  var requiredState = ""
  if requiredMode in ["missing-provider", "failed-provider"]:
    # Registered in the recipe, deliberately not linked into the engine.
    requiredState = """
type RequiredAttrs = object
  value: string
registerExtension[RequiredAttrs]("n1.required")
registerResourceProvider(ResourceProviderDef(typeId: "n1.required",
  determinism: rdVolatile))
stateGroup "required-state":
  discard resource("n1.required", "required-member", RequiredAttrs(value: "up"))
"""
    if requiredMode == "failed-provider":
      requiredState.add("""
registerResourceProviderArtifact("n1.required", ResourceProviderArtifactRef(
  binaryPath: "missing-required-provider", providerArtifactId: "n1-required",
  workingDir: "."))
""")
  writeFile(path,
    "import repro_project_dsl\n" &
    "import repro_resources\n\n" & requiredState & "\n" &
    "package n1RunPkg:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"n1-tool >=1.0 <2.0\"\n" &
    "    \"unused-tool >=1.0 <2.0\"\n\n" &
    "  build:\n" &
    "    let marker = \".repro/n1-runs.log\"\n" &
    "    let app = n1Tool(actionId = \"build-app\",\n" &
    "      input = \"src/main.txt\",\n" &
    "      output = \"build/app\",\n" &
    "      marker = marker)\n" &
    "    discard target(\"app-build\", app)\n" &
    "    discard collect(\"lint\", [app])\n" &
    "    run(\"app-run\", build = \"build-app\")\n" &
    "    run(\"required-run\", build = \"build-app\",\n" &
    "      consumes = @[leased(\"required-state\", delayed(minutes = 30))])\n")

proc nonEmptyLines(path: string): seq[string] =
  if not fileExists(path):
    return @[]
  for line in readFile(path).splitLines:
    let stripped = line.strip()
    if stripped.len > 0:
      result.add(stripped)

proc runRun(reproBin, pathValue: string; cwd: string;
            extraArgs: openArray[string]): string =
  ## Run ``repro run <args>`` from ``cwd`` (asserts success). ``--daemon``
  ## is not a ``repro run`` flag; the delegated build inherits the default
  ## direct/daemon behaviour, so we pin determinism the same way the
  ## named-target build test does by forcing tool-provisioning=path via the
  ## environment the delegated ``repro build`` honours.
  var args = @[reproBin, "run"]
  for a in extraArgs:
    args.add(a)
  let entries = @[
    ("PATH", pathValue),
    ("REPRO_TOOL_PROVISIONING", "path"),
    ("REPROBUILD_NO_RUNQUOTA", "1"),
    ("REPRO_DAEMON", "off")
  ]
  requireSuccess(shellCommand(args, entries), cwd)

proc listRunTargets(reproBin, pathValue, cwd: string): string =
  requireSuccess(shellCommand(@[reproBin, "tasks"], @[
    ("PATH", pathValue),
    ("REPRO_TOOL_PROVISIONING", "path"),
    ("REPROBUILD_NO_RUNQUOTA", "1"),
    ("REPRO_DAEMON", "off")
  ]), cwd)

suite "t_e2e_repro_run_named_run_edge":

  test "t_e2e_repro_run_named_run_edge":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-n1-run-edge", "")
    defer: removeDir(tempRoot)

    let reproBin = reproBinary(repoRoot)

    let binDir = tempRoot / "bin"
    writeRunTool(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")

    let projectRoot = tempRoot / "project"
    createDir(projectRoot / "src")
    writeFile(projectRoot / "src" / "main.txt", "main v1\n")
    writeRunEdgeProject(projectRoot / "reprobuild.nim")

    let listing = listRunTargets(reproBin, pathValue, projectRoot)
    check listing.contains("[run-edge]")
    check listing.contains("app-run")

    # First run: `repro run app-run` selects the `tekRunEdge` export name,
    # resolves it to `build-app`, then executes the tool once. The output
    # file + the single marker line are the authoritative witnesses that the
    # edge actually ran (stdout formatting is not asserted — the filesystem
    # effects are the meaningful check).
    let runArgs = ["app-run", "--", "--forwarded", "forwarded-one"]
    let firstRun = runRun(reproBin, pathValue, projectRoot, runArgs)
    checkpoint firstRun
    # ``unused-tool`` is absent from PATH and belongs to no action in this
    # closure. Focused execution must not provision unrelated project tools.
    check not firstRun.contains("unused-tool")
    checkpoint "marker: " & nonEmptyLines(
      projectRoot / ".repro" / "n1-runs.log").join(" | ")
    check fileExists(projectRoot / "build" / "app")
    check nonEmptyLines(projectRoot / ".repro" / "n1-runs.log").len == 1
    check nonEmptyLines(projectRoot / ".repro" / "n1-runs.log")[0].contains(
      "forwarded-one")

    # Second run: the build step is action-cache warm — the tool must NOT
    # be relaunched, so the marker stays at exactly one line. This proves
    # `repro run` delegated to the same action-cached build path.
    let secondRun = runRun(reproBin, pathValue, projectRoot, runArgs)
    checkpoint secondRun
    check nonEmptyLines(projectRoot / ".repro" / "n1-runs.log").len == 1

  test "required consumed state failures prevent the command from starting":
    # Named-Runnable-Edges section 3.2: required state precedes execution.
    # The SAME command without consumes remains runnable in every fixture.
    let reproBin = reproBinary(getCurrentDir())
    let tempRoot = createTempDir("repro-required-run", "")
    defer: removeDir(tempRoot)
    let binDir = tempRoot / "bin"
    writeRunTool(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")
    let home = tempRoot / "home"
    createDir(home)
    for mode in ["missing-group", "missing-provider", "failed-provider"]:
      checkpoint mode
      let projectRoot = tempRoot / mode
      createDir(projectRoot / "src")
      writeFile(projectRoot / "src/main.txt", "required state witness\n")
      writeRunEdgeProject(projectRoot / "reprobuild.nim", mode)
      let env = @[
        ("PATH", pathValue), ("HOME", home), ("USERPROFILE", home),
        ("REPRO_TOOL_PROVISIONING", "path"),
        ("REPROBUILD_NO_RUNQUOTA", "1"), ("REPRO_DAEMON", "off")]
      let failed = runShell(shellCommand(@[reproBin, "run", "required-run"], env),
        projectRoot)
      checkpoint failed.output
      check failed.code != 0
      check failed.output.contains("repro run: error:")
      check failed.output.contains("required-run")
      case mode
      of "missing-group":
        check failed.output.contains("required-state")
        check failed.output.contains("missing, empty, or incomplete")
      of "missing-provider":
        check failed.output.contains("no provider session")
      else:
        check failed.output.contains("missing-required-provider")
      check not fileExists(projectRoot / ".repro" / "n1-runs.log")
      check not fileExists(projectRoot / "build" / "app")
      let control = requireSuccess(shellCommand(@[reproBin, "run", "app-run"], env),
        projectRoot)
      checkpoint control
      check nonEmptyLines(projectRoot / ".repro" / "n1-runs.log").len == 1
