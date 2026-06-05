## Named-Targets M2 verification: ``repro build doesnotexist`` exits 2
## and stderr carries the ``unknown_target`` diagnostic, including at
## least one Levenshtein candidate when a near-match exists in the
## project's target-export table.

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
  let runquotaRoot = repoRoot.parentDir / "runquota"
  let daemonBin = runquotaRoot / "build" / "bin" / addFileExt("runquotad", ExeExt)
  if not fileExists(daemonBin):
    raise newException(OSError,
      "runquotad binary missing at " & daemonBin)
  let socketPath = "/tmp/repro-m2-unknown-rq-" & $getCurrentProcessId() & ".sock"
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

proc writeExecutable(path, content: string) =
  createDir(path.splitPath.head)
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc writeM2Tool(binDir: string) =
  writeExecutable(binDir / "m2-tool",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'm2-tool 1.0.0'; exit 0; fi\n" &
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

proc writeUnknownTargetProject(path: string) =
  ## A project that exports a target named ``codetracer``. We invoke
  ## ``repro build codetraver`` (a single-edit typo) and expect the
  ## ``unknown_target`` diagnostic to surface ``codetracer`` as a top-3
  ## Levenshtein candidate.
  let projectRoot = path.splitPath.head
  createDir(projectRoot / "reprobuild" / "packages")
  writeFile(projectRoot / "reprobuild" / "packages" / "m2_tool.nim",
    "import repro_project_dsl\n\n" &
    "defineCliInterface m2Tool, \"m2-tool\":\n" &
    "  call:\n" &
    "    flag input is string, alias = \"--input\", role = input, required = true\n" &
    "    flag output is string, alias = \"--output\", role = output, required = true\n" &
    "    flag marker is string, alias = \"--marker\", required = true\n" &
    "    outputs output\n")
  writeFile(path,
    "import repro_project_dsl\n\n" &
    "package m2UnknownPkg:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"m2-tool >=1.0 <2.0\"\n\n" &
    "  build:\n" &
    "    let marker = \".repro/m2-runs.log\"\n" &
    "    m2Tool(actionId = \"build-codetracer\",\n" &
    "      input = \"src/main.txt\",\n" &
    "      output = \"build/codetracer\",\n" &
    "      marker = marker)\n")

suite "t_repro_build_unknown_target_diagnostic":

  test "t_repro_build_unknown_target_diagnostic":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m2-unknown", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    let reproBin = tempRoot / "repro"
    discard requireSuccess(shellCommand([
      "nim", "c", "--verbosity:0", "--hints:off",
      "--nimcache:" & (tempRoot / "nimcache-repro"),
      "--out:" & reproBin,
      repoRoot / "apps" / "repro" / "repro.nim"
    ]), repoRoot)

    let binDir = tempRoot / "bin"
    writeM2Tool(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")

    let projectRoot = tempRoot / "project"
    createDir(projectRoot / "src")
    writeFile(projectRoot / "src" / "main.txt", "main v1\n")
    writeUnknownTargetProject(projectRoot / "reprobuild.nim")

    # Single-edit typo: ``codetraver`` vs ``codetracer``. The resolver
    # MUST surface ``codetracer`` in the Levenshtein top-3.
    #
    # Named-Targets M2 contract: BOTH direct mode (``--daemon=off``)
    # AND the default daemon-hosted mode must surface the diagnostic
    # with the same exit code (2) and the same ``unknown_target``
    # token in stderr. The daemon-side translation lives in
    # ``installUserDaemonBuildExecutor``'s ``except
    # BuildTargetUnknownError`` clause; it shares the
    # ``renderUnknownTargetDiagnostic`` helper with the top-level CLI
    # dispatch arm so the two emission paths cannot drift.
    let directRes = runShell(shellCommand([
      reproBin, "build", "codetraver",
      "--daemon=off",
      "--tool-provisioning=path", "--log=actions"
    ], [("PATH", pathValue)]), projectRoot)

    check directRes.code == 2
    check directRes.output.contains("unknown_target")
    check directRes.output.contains("codetracer")

    let daemonRes = runShell(shellCommand([
      reproBin, "build", "codetraver",
      "--tool-provisioning=path", "--log=actions"
    ], [("PATH", pathValue)]), projectRoot)

    check daemonRes.code == 2
    check daemonRes.output.contains("unknown_target")
    check daemonRes.output.contains("codetracer")
