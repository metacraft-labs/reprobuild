## Named-Targets M3 verification: ``repro watch doesnotexist`` exits 2
## and stderr carries the same ``unknown_target`` diagnostic shape as
## ``repro build doesnotexist``. This proves the watch arm consumes the
## SHARED M2 resolver / diagnostic helpers rather than reimplementing
## the discriminator.
##
## The test exercises BOTH direct mode (``--daemon=off``) AND the
## default daemon-hosted mode so the daemon-side typed-exception
## translation in ``installUserDaemonWatchExecutor`` stays covered
## alongside the top-level CLI dispatch arm. Mirrors the M2
## ``t_repro_build_unknown_target_diagnostic`` pattern.

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
  let socketPath = "/tmp/repro-m3-unknown-rq-" & $getCurrentProcessId() & ".sock"
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

proc writeM3Tool(binDir: string) =
  ## Same shape as the M2 fixture tool — copies an input to an output
  ## and stamps a marker. ``--version`` is honoured so the
  ## ``tpmPathOnly`` provisioning probe succeeds.
  writeExecutable(binDir / "m3-tool",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'm3-tool 1.0.0'; exit 0; fi\n" &
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
  ## A project that exports a single named edge ``codetracer`` so the
  ## resolver has a near-match for the typo ``codetraver``. Reuses the
  ## M2 fixture shape so the diagnostic comparison between ``repro
  ## build`` and ``repro watch`` is apples-to-apples.
  let projectRoot = path.splitPath.head
  createDir(projectRoot / "reprobuild" / "packages")
  writeFile(projectRoot / "reprobuild" / "packages" / "m3_tool.nim",
    "import repro_project_dsl\n\n" &
    "defineCliInterface m3Tool, \"m3-tool\":\n" &
    "  call:\n" &
    "    flag input is string, alias = \"--input\", role = input, required = true\n" &
    "    flag output is string, alias = \"--output\", role = output, required = true\n" &
    "    flag marker is string, alias = \"--marker\", required = true\n" &
    "    outputs output\n")
  writeFile(path,
    "import repro_project_dsl\n\n" &
    "package m3UnknownPkg:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"m3-tool >=1.0 <2.0\"\n\n" &
    "  build:\n" &
    "    let marker = \".repro/m3-runs.log\"\n" &
    "    m3Tool(actionId = \"build-codetracer\",\n" &
    "      input = \"src/main.txt\",\n" &
    "      output = \"build/codetracer\",\n" &
    "      marker = marker)\n")

suite "t_repro_watch_unknown_target_diagnostic":

  test "t_repro_watch_unknown_target_diagnostic":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m3-watch-unknown", "")
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
    writeM3Tool(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")

    let projectRoot = tempRoot / "project"
    createDir(projectRoot / "src")
    writeFile(projectRoot / "src" / "main.txt", "main v1\n")
    writeUnknownTargetProject(projectRoot / "reprobuild.nim")

    # Single-edit typo: ``codetraver`` vs ``codetracer``. The shared M2
    # resolver MUST surface ``codetracer`` in the Levenshtein top-3.
    #
    # Direct mode (``--daemon=off``): the typed exception
    # ``BuildTargetUnknownError`` raised inside ``runWatchCommand``
    # propagates up to the top-level CLI ``except`` arm, which renders
    # via ``renderUnknownTargetDiagnostic`` and exits 2. ``--max-cycles``
    # is intentionally NOT set — the resolver fires BEFORE the watch
    # cycle starts, so the test never reaches the filesystem watcher.
    let directRes = runShell(shellCommand([
      reproBin, "watch", "codetraver",
      "--daemon=off",
      "--tool-provisioning=path"
    ], [("PATH", pathValue)]), projectRoot)

    check directRes.code == 2
    check directRes.output.contains("unknown_target")
    check directRes.output.contains("codetracer")

    # Default daemon-hosted mode: the typed exception is caught by
    # ``installUserDaemonWatchExecutor``, which emits a ``bekDiagnostic``
    # event carrying ``"stream":"stderr"`` + the formatter's bytes
    # followed by a terminal ``bekFinished`` with exit code 2. The
    # daemon worker's ``terminalSent`` guard suppresses the generic
    # "daemon-hosted watch failed" status line. Result: byte-identical
    # diagnostic + exit code 2 across both modes.
    #
    # Isolate the daemon endpoint / state-dir via ``REPRO_DAEMON_*`` env
    # overrides so the test never adopts a pre-existing user-daemon
    # whose forwarded env may carry stale PATH entries from an
    # unrelated tmp dir (the same daemon-coupling failure mode that
    # forced ``--daemon=off`` pins in
    # ``t_e2e_local_reprobuild_project_build`` (commit 448b887),
    # ``t_e2e_m51_dsl_stdlib_file_ops`` (091cba4),
    # ``t_e2e_repro_build_named_target`` (30a7ce6) and
    # ``t_e2e_repro_build_multiple_named_targets`` (86be3f1)). Here we
    # cannot use ``--daemon=off`` for THIS invocation -- the whole
    # point is to cover ``installUserDaemonWatchExecutor``'s typed-
    # exception arm. Isolation preserves that coverage without the
    # cross-test coupling.
    let daemonEndpoint = daemonSocketEndpoint(
      "repro-m3-watch-unknown-d-" & $getCurrentProcessId())
    if pathExists(daemonEndpoint):
      removeFile(daemonEndpoint)
    let daemonStateDir = tempRoot / "daemon-state"
    let daemonEnv = @[
      ("PATH", pathValue),
      ("REPRO_DAEMON_ENDPOINT", daemonEndpoint),
      ("REPRO_DAEMON_STATE_DIR", daemonStateDir),
      ("REPRO_DAEMON_RUNTIME_DIR", tempRoot / "daemon-runtime")
    ]
    defer:
      # Best-effort: stop the isolated daemon (if any) so it does not
      # outlive the test. Errors swallowed -- the test process exiting
      # closes the daemon socket regardless.
      discard runShell(shellCommand([
        reproBin, "daemon", "stop"
      ], daemonEnv), projectRoot)
      if pathExists(daemonEndpoint):
        try: removeFile(daemonEndpoint) except OSError: discard

    let daemonRes = runShell(shellCommand([
      reproBin, "watch", "codetraver",
      "--tool-provisioning=path"
    ], daemonEnv), projectRoot)

    check daemonRes.code == 2
    check daemonRes.output.contains("unknown_target")
    check daemonRes.output.contains("codetracer")
