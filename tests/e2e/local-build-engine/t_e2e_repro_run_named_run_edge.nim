## Named-Runnable-Edges N1 verification — `repro run <run-edge-name>`
## resolves a NAMED run-edge through the same target-export-table resolver
## `repro build` uses, materializes its dependency closure, and EXECUTES
## it. A second `repro run` of the same edge is action-cache warm on the
## build step (the tool is not relaunched).
##
## Spec cite: Named-Runnable-Edges.md §3.1 / §5; the N1 milestone
## Verification `t_e2e_repro_run_named_run_edge`.
##
## The fixture registers a `run "app-run", build = "build-app"` run-target
## via the N0 DSL surface (`repro_resources`' `run`). `build-app` is a
## typed-tool edge that copies its input to `build/app` and appends a line
## to a marker file every time it actually fires — so the marker line count
## is an exact witness of how many times the edge was *executed* vs served
## warm from the action cache. `repro run app-run` must route the bare name
## through the `tekRunEdge` export row to that edge and run it; the second
## invocation must reuse the cache (marker stays at one line).

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc pathExists(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc ensureRunQuotaDaemon(repoRoot: string): tuple[process: owned(Process);
    socket: string] =
  let daemonBin = requireRunQuotaDaemonBin(repoRoot)
  let socketPath = "/tmp/repro-n1-run-edge-rq-" & $getCurrentProcessId() &
    ".sock"
  if fileExists(socketPath):
    removeFile(socketPath)
  let daemon = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--cpu-milli", "16000",
    "--memory-bytes", "17179869184"
  ], options = {poUsePath})
  putEnv("RUNQUOTA_SOCKET", socketPath)
  for _ in 0 ..< 200:
    if pathExists(socketPath):
      return (process: daemon, socket: socketPath)
    sleep(25)
  daemon.terminate()
  raise newException(OSError, "runquotad socket did not appear")

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
  writeExecutable(binDir / "n1-tool",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'n1-tool 1.0.0'; exit 0; fi\n" &
    "input= output= marker=\n" &
    "while [ \"$#\" -gt 0 ]; do\n" &
    "  case \"$1\" in\n" &
    "    --input) input=$2; shift 2 ;;\n" &
    "    --output) output=$2; shift 2 ;;\n" &
    "    --marker) marker=$2; shift 2 ;;\n" &
    "    *) echo \"unknown arg $1\" >&2; exit 64 ;;\n" &
    "  esac\n" &
    "done\n" &
    "mkdir -p \"$(dirname \"$output\")\" \"$(dirname \"$marker\")\"\n" &
    "cp \"$input\" \"$output\"\n" &
    "printf '%s\\n' \"$output\" >> \"$marker\"\n")

proc writeRunEdgeProject(path: string) =
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
  writeFile(path,
    "import repro_project_dsl\n" &
    "import repro_resources\n\n" &
    "package n1RunPkg:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"n1-tool >=1.0 <2.0\"\n\n" &
    "  build:\n" &
    "    let marker = \".repro/n1-runs.log\"\n" &
    "    n1Tool(actionId = \"build-app\",\n" &
    "      input = \"src/main.txt\",\n" &
    "      output = \"build/app\",\n" &
    "      marker = marker)\n" &
    "    run(\"app-run\", build = \"build-app\")\n")

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
    ("REPRO_TOOL_PROVISIONING", "path")
  ]
  requireSuccess(shellCommand(args, entries), cwd)

suite "t_e2e_repro_run_named_run_edge":

  test "t_e2e_repro_run_named_run_edge":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-n1-run-edge", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    let reproBin = reproBinary(repoRoot)

    let binDir = tempRoot / "bin"
    writeRunTool(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")

    let projectRoot = tempRoot / "project"
    createDir(projectRoot / "src")
    writeFile(projectRoot / "src" / "main.txt", "main v1\n")
    writeRunEdgeProject(projectRoot / "reprobuild.nim")

    # First run: `repro run app-run` resolves the `tekRunEdge` export row to
    # the `build-app` edge and executes it (the tool fires once). The output
    # file + the single marker line are the authoritative witnesses that the
    # edge actually ran (stdout formatting is not asserted — the filesystem
    # effects are the meaningful check).
    discard runRun(reproBin, pathValue, projectRoot, ["app-run"])
    check fileExists(projectRoot / "build" / "app")
    check nonEmptyLines(projectRoot / ".repro" / "n1-runs.log").len == 1

    # Second run: the build step is action-cache warm — the tool must NOT
    # be relaunched, so the marker stays at exactly one line. This proves
    # `repro run` delegated to the same action-cached build path.
    discard runRun(reproBin, pathValue, projectRoot, ["app-run"])
    check nonEmptyLines(projectRoot / ".repro" / "n1-runs.log").len == 1
