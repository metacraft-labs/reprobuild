import std/[json, os, osproc, streams, strutils, tempfiles, times, unittest]

import repro_test_support

proc pathExists(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc reproBinary(): string =
  ## Test-Fixtures-In-Build-Graph M1: ``repro`` is a build-graph artifact
  ## (``reprobuild.apps.repro`` → ``build/bin/repro``, built by
  ## ``just bootstrap`` / the apps collection before tests run). Assert it
  ## exists and drive it instead of recompiling ``apps/repro/repro.nim`` at
  ## test runtime. The repo root is the test's working directory (the suite
  ## runs from the reprobuild checkout root). The timing-helper binary below
  ## is a per-test fixture, not a graph artifact, so it is still compiled
  ## here.
  requireBinary(getCurrentDir() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc nowMillis(): int64 =
  int64(epochTime() * 1000.0)

proc nimString(value: string): string =
  value.escape()

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc copySelectedCodeTracerFiles(codeTracerRoot, projectRoot: string) =
  createDir(projectRoot / "src" / "frontend" / "tests")
  createDir(projectRoot / "src" / "frontend" / "index")
  createDir(projectRoot / "src" / "frontend" / "lib")
  createDir(projectRoot / "src" / "c")
  copyFile(codeTracerRoot / "src" / "frontend" / "tests" /
    "ipc_registry_test.nim",
    projectRoot / "src" / "frontend" / "tests" / "ipc_registry_test.nim")
  copyFile(codeTracerRoot / "src" / "frontend" / "index" /
    "ipc_registry.nim",
    projectRoot / "src" / "frontend" / "index" / "ipc_registry.nim")
  copyFile(codeTracerRoot / "src" / "frontend" / "lib" / "jslib.nim",
    projectRoot / "src" / "frontend" / "lib" / "jslib.nim")
  copyFile(codeTracerRoot / "test-programs" / "c_sudoku_solver" / "main.c",
    projectRoot / "src" / "c" / "main.c")

proc writeTimingHelper(path: string) =
  writeFile(path,
    "import std/[os, strutils, times]\n\n" &
    "proc nowMillis(): int64 = int64(epochTime() * 1000.0)\n\n" &
    "let args = commandLineParams()\n" &
    "if args.len != 5:\n" &
    "  quit 2\n" &
    "let stamp = args[0]\n" &
    "let gate = args[1]\n" &
    "let label = args[2]\n" &
    "let waitMaxMs = parseInt(args[3])\n" &
    "let sleepMs = parseInt(args[4])\n" &
    "createDir(parentDir(stamp))\n" &
    "let started = nowMillis()\n" &
    "writeFile(stamp & \".start\", $started & \"\\n\")\n" &
    "let deadline = started + int64(waitMaxMs)\n" &
    "while not fileExists(gate) and nowMillis() < deadline:\n" &
    "  sleep(25)\n" &
    "let gateSeen = fileExists(gate)\n" &
    "sleep(sleepMs)\n" &
    "let ended = nowMillis()\n" &
    "writeFile(stamp, \"label=\" & label & \"\\n\" &\n" &
    "  \"start_ms=\" & $started & \"\\n\" &\n" &
    "  \"end_ms=\" & $ended & \"\\n\" &\n" &
    "  \"gate_seen=\" & $gateSeen & \"\\n\")\n" &
    "if not gateSeen:\n" &
    "  quit 42\n")

proc writeProject(path, packageName, actionId, helperPath, stampPath, gatePath,
                  label, outputRel: string; inputs: openArray[string];
                  extraShellChecks = "") =
  createDir(path.splitPath.head)
  let script =
    "set -eu\n" &
    "helper=$1\n" &
    "stamp=$2\n" &
    "gate=$3\n" &
    "label=$4\n" &
    "out=$5\n" &
    "test -x \"$helper\"\n" &
    extraShellChecks &
    # The first arg after the label is ``waitMaxMs`` — how long each helper
    # blocks on the release-gate before giving up and quitting 42
    # (gate_seen=false). It MUST comfortably exceed the worst-case time the
    # test takes to OBSERVE serialization and write the gate. On a heavily-
    # shared runner the second session's cold provider compile can hold the
    # only RunQuota slot for a long time before its public action lease
    # becomes visible, so the observation loop (and therefore the gate
    # write) can be slow. A short 90 s window made gate_seen flake under
    # that contention even though the sessions DID serialize. 600 s leaves
    # generous headroom without ever masking a real failure: if the gate
    # genuinely never gets written (serialization never observed), the
    # observation loop's own ``observedQueue`` check still fails first.
    "\"$helper\" \"$stamp\" \"$gate\" \"$label\" 600000 900\n" &
    "mkdir -p \"$(dirname \"$out\")\"\n" &
    "printf '%s\\n' \"$label\" > \"$out\"\n"

  var inputLiteral = ""
  for index, input in inputs:
    if index > 0:
      inputLiteral.add(", ")
    inputLiteral.add(nimString(input))

  writeFile(path,
    "import repro_project_dsl\n\n" &
    "package " & packageName & ":\n" &
    "  uses:\n" &
    "    \"sh >=1\"\n\n" &
    "  executable shTool:\n" &
    "    name \"sh\"\n" &
    "    cli:\n" &
    "      subcmd \"-c\":\n" &
    "        pos args, seq[string], position = 0\n\n" &
    "    build:\n" &
    "      discard buildAction(" & nimString(actionId) & ",\n" &
    "        " & packageName & ".executable(\"sh\").subcmd_2d_c(\n" &
    "          args = @[" & nimString(script) & ", " & nimString("sh") &
      ", " & nimString(helperPath) & ", " & nimString(stampPath) & ", " &
      nimString(gatePath) & ", " & nimString(label) & ", " &
      nimString(outputRel) & "]),\n" &
    "        inputs = @[" & inputLiteral & "],\n" &
    "        outputs = @[" & nimString(outputRel) & "],\n" &
    "        cacheable = false)\n")

proc ensureRunQuotaDaemon(repoRoot: string): tuple[process: owned(Process);
    socket: string; cli: string] =
  let runquotaRoot = repoRoot.parentDir / "runquota"
  let daemonBin = runquotaRoot / "build" / "bin" / addFileExt("runquotad", ExeExt)
  let cliBin = runquotaRoot / "build" / "bin" / addFileExt("runquota", ExeExt)
  if not fileExists(daemonBin) or not fileExists(cliBin):
    raise newException(OSError,
      "runquotad/runquota binaries missing under " & runquotaRoot &
      "/build/bin; build them via the test harness " &
      "(scripts/run_tests.sh)")
  let socketPath = "/tmp/repro-m22-rq-" & $getCurrentProcessId() & ".sock"
  if pathExists(socketPath):
    removeFile(socketPath)
  let daemon = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--cpu-milli", "1000",
    "--memory-bytes", "17179869184"
  ], options = {poUsePath, poStdErrToStdOut})
  putEnv("RUNQUOTA_SOCKET", socketPath)
  for _ in 0 ..< 200:
    if pathExists(socketPath):
      return (process: daemon, socket: socketPath, cli: cliBin)
    sleep(25)
  daemon.terminate()
  raise newException(OSError, "runquotad socket did not appear")

proc runQuotaJson(cliPath: string; args: openArray[string]): JsonNode =
  let res = runShell(shellCommand(@[cliPath] & @args))
  if res.code != 0:
    raise newException(OSError, "runquota CLI failed: " & res.output)
  parseJson(res.output)

proc hasQueuedAndRunningBuildLeases(cliPath: string; snapshot: var string): bool =
  let node = runQuotaJson(cliPath, ["leases", "--json"])
  snapshot = $node
  var sawQueued = false
  var sawActive = false
  for lease in node{"leases"}.getElems():
    let state = lease{"state"}.getStr()
    if state == "queued":
      sawQueued = true
    if state in ["granted", "starting", "running"]:
      sawActive = true
  sawQueued and sawActive

proc collect(process: Process): tuple[code: int; output: string] =
  if process.outputStream != nil:
    result.output = process.outputStream.readAll()
  result.code = process.waitForExit()
  process.close()

type
  Interval = object
    label: string
    startMs: int64
    endMs: int64
    gateSeen: bool

proc readInterval(path: string): Interval =
  for line in readFile(path).splitLines:
    let split = line.find('=')
    if split < 0:
      continue
    let key = line[0 ..< split]
    let value = line[split + 1 .. ^1]
    case key
    of "label":
      result.label = value
    of "start_ms":
      result.startMs = parseBiggestInt(value)
    of "end_ms":
      result.endMs = parseBiggestInt(value)
    of "gate_seen":
      result.gateSeen = value == "true"
    else:
      discard

proc overlaps(a, b: Interval): bool =
  a.startMs < b.endMs and b.startMs < a.endMs

proc reportAction(reportPath, actionId: string): JsonNode =
  for action in parseFile(reportPath){"actions"}.getElems():
    if action{"id"}.getStr() == actionId:
      return action
  raise newException(ValueError, "missing action in report: " & actionId)

proc checkRunQuotaReportDiagnostics(action: JsonNode; socket: string) =
  check action{"runQuotaBackend"}.getStr() == "posix-fork-exec-poll"
  check action{"runQuotaSocket"}.getStr() == socket
  check action{"leaseId"}.getBiggestInt() > 0

suite "integration_reprobuild_sessions_share_runquota":
  when isNixSupported:
    test "two repro build sessions serialize default 1000 milliCPU actions through one daemon":
      let repoRoot = getCurrentDir()
      let codeTracerRoot = absolutePath(repoRoot / ".." / "codetracer")
      check fileExists(codeTracerRoot / "src" / "frontend" / "tests" /
        "ipc_registry_test.nim")
      check fileExists(codeTracerRoot / "test-programs" / "c_sudoku_solver" /
        "main.c")

      let tempRoot = createTempDir("repro-m22-shared-runquota", "")
      let previousSocket = getEnv("RUNQUOTA_SOCKET", "")
      defer:
        putEnv("RUNQUOTA_SOCKET", previousSocket)
        removeDir(tempRoot)

      let reproBin = reproBinary()

      let helperSource = tempRoot / "timing_helper.nim"
      let helperBin = tempRoot / "timing-helper"
      writeTimingHelper(helperSource)
      discard requireSuccess(shellCommand([
        "nim", "c", "--verbosity:0", "--hints:off",
        "--nimcache:" & (tempRoot / "nimcache-helper"),
        "--out:" & helperBin,
        helperSource
      ]), repoRoot)

      let stampsDir = tempRoot / "stamps"
      let gatePath = tempRoot / "release-gate"
      let codeProject = tempRoot / "codetracer-project"
      let fixtureProject = tempRoot / "fixture-project"
      createDir(codeProject)
      createDir(fixtureProject)
      copySelectedCodeTracerFiles(codeTracerRoot, codeProject)
      writeFile(fixtureProject / "input.txt", "fixture\n")

      const CodeAction = "m22-codetracer-sleep"
      const FixtureAction = "m22-fixture-sleep"
      writeProject(codeProject / "reprobuild.nim", "codeTracerM22", CodeAction,
        helperBin, stampsDir / "codetracer.stamp", gatePath, "codetracer",
        "build/codetracer.done",
        ["src/frontend/tests/ipc_registry_test.nim", "src/c/main.c"],
        "test -f src/frontend/tests/ipc_registry_test.nim\n" &
          "test -f src/c/main.c\n")
      writeProject(fixtureProject / "reprobuild.nim", "fixtureM22", FixtureAction,
        helperBin, stampsDir / "fixture.stamp", gatePath, "fixture",
        "build/fixture.done",
        ["input.txt"])

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      let launchStart = nowMillis()
      # Pin ``--daemon=off`` so this RunQuota-sharing test exercises the
      # direct-mode build engine without coupling to whichever host
      # ``repro-daemon`` is already running. The default ``--daemon=auto``
      # would reuse a pre-existing user daemon -- whose forwarded env
      # carries stale PATH entries from an unrelated test -- producing
      # hangs / spurious cache misses unrelated to the RunQuota-session
      # sharing this test guards. Mirrors the pins applied in
      # ``t_e2e_m51_dsl_stdlib_file_ops`` (091cba4),
      # ``t_e2e_local_reprobuild_project_build`` (448b887),
      # ``t_e2e_repro_build_named_target`` (30a7ce6) and
      # ``t_e2e_repro_build_multiple_named_targets`` (86be3f1).
      let codeBuild = startProcess(reproBin, workingDir = repoRoot,
        args = ["build", codeProject, "--daemon=off",
          "--tool-provisioning=path", "--log=actions", "--report=full"],
        options = {poUsePath, poStdErrToStdOut})
      let codeStartStamp = stampsDir / "codetracer.stamp.start"
      # Wait for the first session's action to actually start (its helper
      # writes the .start stamp). On a shared runner the cold provider
      # compile that precedes the action can be slow, so poll against a
      # generous deadline rather than a fixed iteration count. If the action
      # never starts, ``check pathExists`` below still fails.
      let startStampDeadline = nowMillis() + 300000
      while nowMillis() < startStampDeadline:
        if pathExists(codeStartStamp) or codeBuild.peekExitCode() != -1:
          break
        sleep(25)
      check pathExists(codeStartStamp)

      let fixtureBuild = startProcess(reproBin, workingDir = repoRoot,
        args = ["build", fixtureProject, "--daemon=off",
          "--tool-provisioning=path", "--log=actions", "--report=full"],
        options = {poUsePath, poStdErrToStdOut})
      let launchEnd = nowMillis()
      check launchEnd - launchStart < 150000

      var lastLeases = ""
      var observedQueue = false
      # Cold provider compilation can hold the only RunQuota slot before these
      # public action leases become visible during a full-suite run. Under
      # heavy contention on a shared runner that delay can be substantial, so
      # poll against a generous wall-clock deadline (must stay well within the
      # helper's 600 s gate-wait window above) rather than a fixed iteration
      # count. This only changes HOW LONG we are willing to wait to OBSERVE
      # serialization; the serialization proof itself (the non-overlap check
      # on the two stamp intervals below) is unchanged. If the queued+running
      # condition never materialises, ``observedQueue`` stays false and the
      # ``check observedQueue`` below still fails — the wait is not masking it.
      let observeDeadline = nowMillis() + 300000
      while nowMillis() < observeDeadline:
        if hasQueuedAndRunningBuildLeases(daemon.cli, lastLeases):
          observedQueue = true
          break
        if codeBuild.peekExitCode() != -1 and fixtureBuild.peekExitCode() != -1:
          break
        sleep(25)
      writeFile(gatePath, "release\n")
      if not observedQueue:
        checkpoint(lastLeases)
      check observedQueue

      let codeResult = collect(codeBuild)
      let fixtureResult = collect(fixtureBuild)
      if codeResult.code != 0:
        checkpoint(codeResult.output)
      if fixtureResult.code != 0:
        checkpoint(fixtureResult.output)
      check codeResult.code == 0
      check fixtureResult.code == 0

      for output in [codeResult.output, fixtureResult.output]:
        check output.contains("runQuotaSocket: " & daemon.socket)
        check output.contains("socket=" & daemon.socket)
        check output.contains("runquota=posix-fork-exec-poll")
        check output.contains("lease=")

      let codeInterval = readInterval(stampsDir / "codetracer.stamp")
      let fixtureInterval = readInterval(stampsDir / "fixture.stamp")
      check codeInterval.label == "codetracer"
      check fixtureInterval.label == "fixture"
      check codeInterval.gateSeen
      check fixtureInterval.gateSeen
      check codeInterval.startMs < codeInterval.endMs
      check fixtureInterval.startMs < fixtureInterval.endMs
      check not codeInterval.overlaps(fixtureInterval)

      let codeReport = valueAfter(codeResult.output, "buildReport:")
      let fixtureReport = valueAfter(fixtureResult.output, "buildReport:")
      checkRunQuotaReportDiagnostics(reportAction(codeReport, CodeAction),
        daemon.socket)
      checkRunQuotaReportDiagnostics(reportAction(fixtureReport, FixtureAction),
        daemon.socket)

      let status = runQuotaJson(daemon.cli, ["status", "--json"])
      check status{"active_sessions"}.getInt() == 0
      check status{"active_leases"}.getInt() == 0
      check status{"queued_leases"}.getInt() == 0
      # Each build session runs its provider compilation through the build engine
      # before the public test action, so the shared daemon observes two
      # bootstrap leases and two action leases.
      check status{"total_granted"}.getInt() == 4
      check status{"total_finished"}.getInt() == 4
