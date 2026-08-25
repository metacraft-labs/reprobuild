## Named-Runnable-Edges N1 verification — diagnostics + exit parity:
##   * `repro run doesnotexist` exits 2 with an `unknown_target`-style
##     diagnostic (matching `repro build`'s shared renderer).
##   * `repro run <plain-artifact-edge>` (a build target that is NOT a
##     run-edge) fails with a diagnostic pointing at `repro build` — the
##     conservative N1 default (spec §3.1 / §7): `repro run` does not guess
##     which output of a non-runnable artifact edge to execute.
##
## Spec cite: Named-Runnable-Edges.md §3.1 / §7; the N1 milestone
## Verification `t_e2e_repro_run_unknown_and_nonrunnable`.

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
  let socketPath = runquotaSocketEndpoint(
    "repro-n1-unknown-rq-" & $getCurrentProcessId())
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
  writeExecutable(binDir / "n1-tool",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'n1-tool 1.0.0'; exit 0; fi\n" &
    "input= output=\n" &
    "while [ \"$#\" -gt 0 ]; do\n" &
    "  case \"$1\" in\n" &
    "    --input) input=$2; shift 2 ;;\n" &
    "    --output) output=$2; shift 2 ;;\n" &
    "    *) echo \"unknown arg $1\" >&2; exit 64 ;;\n" &
    "  esac\n" &
    "done\n" &
    "mkdir -p \"$(dirname \"$output\")\"\n" &
    "cp \"$input\" \"$output\"\n")

proc writeProject(path: string) =
  ## A single PLAIN artifact edge named ``app`` (a `tekImplicit` build
  ## target — NOT a run-edge). No `run "..."` surface here.
  let projectRoot = path.splitPath.head
  createDir(projectRoot / "reprobuild" / "packages")
  writeFile(projectRoot / "reprobuild" / "packages" / "n1_tool.nim",
    "import repro_project_dsl\n\n" &
    "defineCliInterface n1Tool, \"n1-tool\":\n" &
    "  call:\n" &
    "    flag input is string, alias = \"--input\", role = input, required = true\n" &
    "    flag output is string, alias = \"--output\", role = output, required = true\n" &
    "    outputs output\n")
  writeFile(path,
    "import repro_project_dsl\n\n" &
    "package n1PlainPkg:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"n1-tool >=1.0 <2.0\"\n\n" &
    "  build:\n" &
    "    n1Tool(actionId = \"build-app\",\n" &
    "      input = \"src/main.txt\",\n" &
    "      output = \"build/app\")\n")

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

suite "t_e2e_repro_run_unknown_and_nonrunnable":

  test "t_e2e_repro_run_unknown_and_nonrunnable":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-n1-unknown", "")
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

    # Unknown target — exit 2 with the shared `unknown_target` diagnostic
    # (same renderer `repro build` uses, so exit-code + wording match).
    let unknownRun = runResult(reproBin, pathValue, projectRoot,
      ["run", "doesnotexist"])
    check unknownRun.code == 2
    check unknownRun.output.contains("unknown_target")

    # Plain artifact edge `app` — not a run-edge. `repro run` refuses and
    # points at `repro build` (conservative N1 default).
    let nonRunnable = runResult(reproBin, pathValue, projectRoot,
      ["run", "app"])
    check nonRunnable.code == 2
    check nonRunnable.output.contains("repro build")
