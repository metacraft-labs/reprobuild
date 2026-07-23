## Named-Runnable-Edges N1 verification — a dev-env task and a named
## run-edge that SHARE a bare name (`deploy`):
##   * `repro run task:deploy`   → resolves + runs the dev-env task.
##   * `repro run <pkg>:deploy`  → resolves + runs the run-edge.
##   * `repro run deploy` (bare) → prefers the task AND warns, naming the
##     qualifier to disambiguate (spec §7).
##
## Spec cite: Named-Runnable-Edges.md §5 / §7; the N1 milestone
## Verification `t_e2e_repro_run_qualified_and_ambiguous`.
##
## The task and the run-edge write DISTINCT marker files, so the marker
## present after each invocation is an authoritative witness of which
## resolution tier actually executed.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support

const PkgName = "n1AmbigPkg"

proc pathExists(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc ensureRunQuotaDaemon(repoRoot: string): tuple[process: owned(Process);
    socket: string] =
  let daemonBin = requireRunQuotaDaemonBin(repoRoot)
  let socketPath = "/tmp/repro-n1-ambig-rq-" & $getCurrentProcessId() & ".sock"
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

proc writeTool(binDir: string) =
  ## Stamps a distinct build-marker each time it fires (the run-edge side).
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
    "printf 'ran\\n' >> \"$marker\"\n")

proc writeProject(path: string) =
  ## A ``deploy`` dev-env task (touches ``.repro/task-ran``) and a
  ## ``deploy`` run-edge (its ``build-deploy`` tool appends to
  ## ``.repro/build-ran``) share the bare name.
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
    "package " & PkgName & ":\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"n1-tool >=1.0 <2.0\"\n\n" &
    "  devEnv:\n" &
    "    task \"deploy\", command = \"touch .repro/task-ran\"\n\n" &
    "  build:\n" &
    "    n1Tool(actionId = \"build-deploy\",\n" &
    "      input = \"src/main.txt\",\n" &
    "      output = \"build/app\",\n" &
    "      marker = \".repro/build-ran\")\n" &
    "    run(\"deploy\", build = \"build-deploy\")\n")

proc runResult(reproBin, pathValue: string; cwd: string;
               subArgs: openArray[string]): CmdResult =
  var args = @[reproBin]
  for a in subArgs:
    args.add(a)
  let entries = @[
    ("PATH", pathValue),
    ("REPRO_TOOL_PROVISIONING", "path")
  ]
  runShell(shellCommand(args, entries), cwd)

suite "t_e2e_repro_run_qualified_and_ambiguous":

  test "t_e2e_repro_run_qualified_and_ambiguous":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-n1-ambig", "")
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
    writeTool(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")

    let projectRoot = tempRoot / "project"
    createDir(projectRoot / "src")
    writeFile(projectRoot / "src" / "main.txt", "main v1\n")
    writeProject(projectRoot / "reprobuild.nim")

    let taskMarker = projectRoot / ".repro" / "task-ran"
    let buildMarker = projectRoot / ".repro" / "build-ran"

    proc clearMarkers() =
      if fileExists(taskMarker): removeFile(taskMarker)
      if fileExists(buildMarker): removeFile(buildMarker)

    # `task:deploy` — the task tier runs; only the task marker appears.
    clearMarkers()
    let taskRun = runResult(reproBin, pathValue, projectRoot,
      ["run", "task:deploy"])
    check taskRun.code == 0
    check fileExists(taskMarker)
    check not fileExists(buildMarker)

    # `<pkg>:deploy` — the run-edge tier runs; only the build marker appears.
    clearMarkers()
    let edgeRun = runResult(reproBin, pathValue, projectRoot,
      ["run", PkgName & ":deploy"])
    check edgeRun.code == 0
    check fileExists(buildMarker)
    check not fileExists(taskMarker)

    # Bare `deploy` — prefers the task (task marker present) AND emits a
    # disambiguation warning naming the qualifiers.
    clearMarkers()
    let bareRun = runResult(reproBin, pathValue, projectRoot,
      ["run", "deploy"])
    check bareRun.code == 0
    check fileExists(taskMarker)
    check not fileExists(buildMarker)
    check bareRun.output.contains("warning")
    check bareRun.output.contains("task:deploy")
