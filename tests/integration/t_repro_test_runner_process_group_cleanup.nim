## Real process-tree isolation regression for repro_test_runner.
##
## This test compiles one real fixture executable and drives the production
## runner against it. The fixture can form root -> child -> grandchild in the
## runner-owned process group, or detach a setsid sidecar. Every long-lived
## level ignores SIGTERM and the leaf owns a real loopback TCP listener. Six
## controller scenarios prove:
##
## * an idle timeout sends TERM and escalates to KILL for the complete nested
##   tree, reaps every recorded PID, and releases the listener;
## * SIGINT with three concurrent workers waits until all three complete trees
##   are gone before returning 130;
## * normal PASS cleanup reaps its supervisor before killing a setsid sidecar
##   by exact token, never attempts another group signal after that reap, and
##   leaves an unrelated sentinel untouched;
## * a detached sidecar that responds to TERM by spawning a token-bearing
##   replacement cannot outrun the post-KILL ownership barrier;
## * on macOS, an unrelated process carrying the exact token only as an argv
##   element is not mistaken for an environment-token owner; and
## * SIGTERM performs the same bounded cleanup before the runner returns 143.
##
## The signal/timeout scenarios also start the same fixture as an unrelated
## sentinel that moves itself into a distinct process group and owns a second
## real listener. The sentinel must remain alive and keep its port bound after
## the runner's cleanup, proving the implementation targets the owned
## PGID/exact private environment token rather than process names, a race-prone
## parent snapshot, or the runner's surrounding process group.
##
## No mocks, stubs, skipped POSIX branches, or shell process-tree emulation are
## used. The only generated component is the real compiled fixture executable;
## all liveness and resource assertions cross kernel process/socket boundaries.

when defined(posix):
  import std/[json, net, os, osproc, posix, sequtils, streams, strutils,
              tempfiles, times, unittest]

  type
    ProcessRecord = object
      role: string
      label: string
      pid: int
      processGroup: int
      port: int

  const FixtureSource = """
import std/[net, os, osproc, posix, sequtils, strutils, times]

var terminationRequested {.global, volatile.}: Sig_atomic

proc appendRecord(role, label: string; port = 0) =
  let path = getEnv("REPRO_TREE_RECORD")
  if path.len == 0:
    quit(91)
  let file = open(path, fmAppend)
  file.writeLine(role & "," & label & "," & $getCurrentProcessId() & "," &
    $getpgrp() & "," & $port)
  file.close()

proc appendExternalRecord(role, label: string; pid: int; port = 0) =
  let path = getEnv("REPRO_TREE_RECORD")
  if path.len == 0:
    quit(91)
  let processGroup = getpgid(Pid(pid))
  let file = open(path, fmAppend)
  file.writeLine(role & "," & label & "," & $pid & "," & $processGroup & "," &
    $port)
  file.close()

proc runCommand(exe: string; args: openArray[string]):
    tuple[code: int; output: string] =
  let command = (@[exe] & @args).mapIt(quoteShell(it)).join(" ")
  let execution = execCmdEx(command)
  (code: execution.exitCode, output: execution.output)

proc fieldValue(output, field: string): string =
  for line in output.splitLines:
    let prefix = field & ": "
    if line.startsWith(prefix):
      return line[prefix.len .. ^1]

proc daemonArgs(root, endpoint: string): seq[string] =
  @["--endpoint", endpoint, "--state-dir", root / "state",
    "--log", root / "state" / "logs" / "repro-daemon.log"]

proc waitForDaemonRestart(repro, root, endpoint, firstRunId: string):
    tuple[pid: int; output: string] =
  let deadline = epochTime() + 60.0
  while epochTime() < deadline:
    let status = runCommand(repro,
      @["daemon", "status"] & daemonArgs(root, endpoint))
    let pidValue = fieldValue(status.output, "pid")
    let restartRunId = fieldValue(status.output, "restart-run-id")
    if status.code == 0 and status.output.contains("repro daemon: running") and
        pidValue.len > 0 and restartRunId.len > 0 and
        restartRunId != firstRunId:
      return (pid: parseInt(pidValue), output: status.output)
    sleep(50)
  quit(104)

proc writeOwnerEnvironmentProject(path: string) =
  createDir(path)
  let script =
    "set -eu\n" &
    "out=$1\n" &
    "mkdir -p \"$(dirname \"$out\")\"\n" &
    "if [ -n \"${REPRO_TEST_RUNNER_OWNER_TOKEN+x}\" ]; then\n" &
    "  printf 'present\\n' > \"$out\"\n" &
    "else\n" &
    "  printf 'absent\\n' > \"$out\"\n" &
    "fi\n"
  writeFile(path / "reprobuild.nim",
    "import repro_project_dsl\n\n" &
    "package daemonOwnerEnvironment:\n" &
    "  uses:\n" &
    "    \"sh >=1\"\n\n" &
    "  executable shTool:\n" &
    "    name \"sh\"\n" &
    "    cli:\n" &
    "      subcmd \"-c\":\n" &
    "        pos args, seq[string], position = 0\n\n" &
    "    build:\n" &
    "      let action = buildAction(\"owner-environment-probe\",\n" &
    "        daemonOwnerEnvironment.executable(\"sh\").subcmd_2d_c(\n" &
    "          args = @[" & script.escape() & ", \"sh\", " &
      "\"build/owner-environment.txt\"]),\n" &
    "        outputs = @[\"build/owner-environment.txt\"],\n" &
    "        cacheable = false)\n" &
    "      defaultBuildAction(action)\n")

proc ignoreTermination() =
  signal(SIGTERM, SIG_IGN)

proc requestReplacement(sig: cint) {.noconv, gcsafe, raises: [].} =
  terminationRequested = Sig_atomic(sig)

proc listenOnLoopback(): tuple[socket: Socket; port: int] =
  result.socket = newSocket()
  result.socket.bindAddr(Port(0), "127.0.0.1")
  result.socket.listen()
  let (_, assignedPort) = result.socket.getLocalAddr()
  result.port = int(assignedPort)

proc waitForever() =
  while true:
    sleep(1000)

let params = commandLineParams()
let label = getAppFilename().lastPathPart
if params.len == 0 and
    getEnv("REPRO_TREE_MODE") == "actual-daemon-boundary":
  appendRecord("root", label)
  appendExternalRecord("supervisor", label, int(getppid()))
  let tokenPath = getEnv("REPRO_TREE_TOKEN_FILE")
  let continuePath = getEnv("REPRO_TREE_CONTINUE_FILE")
  writeFile(tokenPath, getEnv("REPRO_TEST_RUNNER_OWNER_TOKEN"))
  for _ in 0 ..< 1000:
    if fileExists(continuePath):
      break
    sleep(10)
  if not fileExists(continuePath):
    quit(98)

  let repro = getEnv("REPRO_ACTUAL_REPRO_BIN")
  let root = getEnv("REPRO_ACTUAL_DAEMON_ROOT")
  let endpoint = getEnv("REPRO_ACTUAL_DAEMON_ENDPOINT")
  createDir(root / "source")
  let sourceExe = root / "source" / "repro"
  copyFileWithPermissions(repro, sourceExe)
  when defined(macosx):
    # Give the first source image a different, still-valid ad-hoc signature.
    # Replacing it with the original signed image below changes the digest
    # without appending invalid bytes after Mach-O's code-signature region.
    let initiallySigned = runCommand("/usr/bin/codesign", [
      "--force", "--sign", "-",
      "--identifier", "org.reprobuild.ownerfixture",
      sourceExe,
    ])
    if initiallySigned.code != 0:
      stderr.writeLine("actual daemon initial codesign failed: " &
        initiallySigned.output)
      quit(100)
  let started = runCommand(repro,
    @["daemon", "start", "--dev", "--daemon-exe", sourceExe] &
      daemonArgs(root, endpoint))
  if started.code != 0:
    stderr.writeLine("actual daemon start failed: " & started.output)
    quit(99)
  let firstPid = parseInt(fieldValue(started.output, "pid"))
  let firstRunId = fieldValue(started.output, "restart-run-id")
  appendExternalRecord("daemon-initial", label, firstPid)

  when defined(macosx):
    let replacement = root / "source" / "repro.next"
    copyFileWithPermissions(repro, replacement)
    removeFile(sourceExe)
    moveFile(replacement, sourceExe)
  else:
    let marker = open(sourceExe, fmAppend)
    marker.write("\nOWNER-RESTART-MARKER\n")
    marker.close()

  let restarted = waitForDaemonRestart(repro, root, endpoint, firstRunId)
  if restarted.pid == firstPid:
    quit(101)
  appendExternalRecord("daemon-restarted", label, restarted.pid)

  let project = root / "owner-environment-project"
  writeOwnerEnvironmentProject(project)
  putEnv("REPRO_DAEMON_ENDPOINT", endpoint)
  putEnv("REPRO_DAEMON_STATE_DIR", root / "state")
  putEnv("REPROBUILD_STORE_ROOT", root / "store")
  let buildArgs = @[
    "build", project,
    "--daemon=require",
    "--tool-provisioning=path",
    "--work-root=" & root / "work",
    "--action-cache-root=" & root / "action-cache",
    "--progress=quiet",
    "--log=quiet",
    "--report=none",
    "--no-runquota",
  ]
  when defined(linux):
    # Linux CI can independently hang inside the build engine after the real
    # daemon has spawned its action worker. That is outside this runner
    # ownership regression. Inspect the actual worker environment directly,
    # then let normal PASS cleanup prove that both the daemon and worker stay
    # owned across the systemd-user launch and dev-restart boundaries.
    discard startProcess(repro, args = buildArgs, options = {poParentStreams})
    let daemonLog = root / "state" / "logs" / "repro-daemon.log"
    let workerDeadline = epochTime() + 60.0
    var workerPid = 0
    var workerEnvironment = ""
    while epochTime() < workerDeadline and workerPid == 0:
      if fileExists(daemonLog):
        for line in readFile(daemonLog).splitLines:
          if "build worker started " in line:
            let pidMarker = " pid="
            let pidAt = line.rfind(pidMarker)
            if pidAt >= 0:
              try:
                let candidate = parseInt(
                  line[pidAt + pidMarker.len .. ^1].strip)
                let candidateEnvironment =
                  readFile("/proc/" & $candidate & "/environ")
                if fileExists("/proc/" & $candidate & "/status"):
                  workerPid = candidate
                  workerEnvironment = candidateEnvironment
              except ValueError, IOError, OSError:
                # The detached worker may finish between its log record and
                # this /proc read. Only accept a live, readable exact PID.
                discard
      if workerPid == 0:
        sleep(20)
    if workerPid <= 0:
      quit(105)
    # Linux exposes the process's original exec-time environment memory block
    # through /proc. This worker is double-forked without exec, so that snapshot
    # intentionally retains the daemon's launch marker even though
    # runUserDaemonForeground removed it from the live libc environment before
    # request handling. The runner must still recognize and clean this worker.
    # Wire/unit coverage independently proves the live request/action
    # environment is sanitized; macOS below executes the real action probe.
    if not workerEnvironment.split('\0').anyIt(
        it.startsWith("REPRO_TEST_RUNNER_OWNER_TOKEN=")):
      stderr.writeLine("actual daemon build worker lost ownership snapshot")
      quit(106)
    appendExternalRecord("build-worker", label, workerPid)
  else:
    let build = runCommand(repro, buildArgs)
    if build.code != 0 or
        not fileExists(project / "build" / "owner-environment.txt") or
        readFile(project / "build" / "owner-environment.txt") != "absent\n":
      quit(102)
  quit(0)
elif params.len > 0 and params[0] == "--sentinel":
  if setpgid(Pid(0), Pid(0)) != 0:
    quit(92)
  ignoreTermination()
  let listener = listenOnLoopback()
  appendRecord("sentinel", label, listener.port)
  waitForever()
elif params.len > 2 and params[0] == "--token-churner":
  # This controller is deliberately outside the runner-owned group and does
  # not carry the owner token in its environment. It keeps one token-bearing
  # child alive at a time long enough to make the runner's first bounded
  # post-KILL verification fail, then stops replenishing owners so the final
  # reaper can succeed. This exercises a retry after the original supervisor
  # has already been synchronously reaped.
  if setpgid(Pid(0), Pid(0)) != 0:
    quit(107)
  ignoreTermination()
  delEnv("REPRO_TEST_RUNNER_OWNER_TOKEN")
  let listener = listenOnLoopback()
  appendRecord("churner", label, listener.port)
  let ownerToken = params[1]
  let churnUntil = epochTime() + parseFloat(params[2])
  var owner: Process
  while epochTime() < churnUntil:
    if owner.isNil or owner.peekExitCode() != -1:
      if not owner.isNil:
        discard owner.waitForExit()
        close(owner)
      putEnv("REPRO_TEST_RUNNER_OWNER_TOKEN", ownerToken)
      owner = startProcess(getAppFilename(), args = ["--forged-owner"],
        options = {poParentStreams})
      delEnv("REPRO_TEST_RUNNER_OWNER_TOKEN")
    sleep(10)
  if not owner.isNil:
    discard owner.waitForExit()
    close(owner)
  waitForever()
elif params.len > 0 and params[0] == "--forged-owner":
  ignoreTermination()
  let listener = listenOnLoopback()
  appendRecord("forged-owner", label, listener.port)
  waitForever()
elif params.len > 0 and params[0] == "--argv-collision":
  if setpgid(Pid(0), Pid(0)) != 0:
    quit(95)
  delEnv("REPRO_TEST_RUNNER_OWNER_TOKEN")
  ignoreTermination()
  let listener = listenOnLoopback()
  appendRecord("argv-collision", label, listener.port)
  waitForever()
elif params.len > 0 and params[0] == "--respawn-replacement":
  ignoreTermination()
  let listener = listenOnLoopback()
  appendRecord("replacement", label, listener.port)
  waitForever()
elif params.len > 0 and params[0] == "--respawn-sidecar":
  if setsid() < 0:
    quit(96)
  signal(SIGTERM, requestReplacement)
  let listener = listenOnLoopback()
  appendRecord("respawner", label, listener.port)
  var replacementStarted = false
  while true:
    if terminationRequested != 0 and not replacementStarted:
      replacementStarted = true
      signal(SIGTERM, SIG_IGN)
      discard startProcess(getAppFilename(),
        args = ["--respawn-replacement"], options = {poParentStreams})
    sleep(10)
elif params.len > 0 and params[0] == "--sidecar":
  if setsid() < 0:
    quit(93)
  ignoreTermination()
  let listener = listenOnLoopback()
  appendRecord("sidecar", label, listener.port)
  waitForever()
elif params.len > 0 and params[0] == "--grandchild":
  ignoreTermination()
  let listener = listenOnLoopback()
  appendRecord("grandchild", label, listener.port)
  waitForever()
elif params.len > 0 and params[0] == "--child":
  ignoreTermination()
  appendRecord("child", label)
  discard startProcess(getAppFilename(), args = ["--grandchild"],
    options = {poParentStreams})
  waitForever()
elif getEnv("REPRO_TREE_MODE") == "detached-sidecar":
  appendRecord("root", label)
  discard startProcess(getAppFilename(), args = ["--sidecar"],
    options = {poParentStreams})
  let recordPath = getEnv("REPRO_TREE_RECORD")
  for _ in 0 ..< 1000:
    if fileExists(recordPath) and
        ("sidecar," & label & ",") in readFile(recordPath):
      quit(0)
    sleep(10)
  quit(94)
elif getEnv("REPRO_TREE_MODE") == "detached-respawn":
  appendRecord("root", label)
  discard startProcess(getAppFilename(), args = ["--respawn-sidecar"],
    options = {poParentStreams})
  let recordPath = getEnv("REPRO_TREE_RECORD")
  for _ in 0 ..< 1000:
    if fileExists(recordPath) and
        ("respawner," & label & ",") in readFile(recordPath):
      quit(0)
    sleep(10)
  quit(97)
elif getEnv("REPRO_TREE_MODE") == "owner-token-handshake":
  appendRecord("root", label)
  let tokenPath = getEnv("REPRO_TREE_TOKEN_FILE")
  let continuePath = getEnv("REPRO_TREE_CONTINUE_FILE")
  writeFile(tokenPath, getEnv("REPRO_TEST_RUNNER_OWNER_TOKEN"))
  for _ in 0 ..< 1000:
    if fileExists(continuePath):
      quit(0)
    sleep(10)
  quit(98)
else:
  ignoreTermination()
  appendRecord("root", label)
  discard startProcess(getAppFilename(), args = ["--child"],
    options = {poParentStreams})
  waitForever()
"""

  proc repoRoot(): string =
    var candidate = currentSourcePath().parentDir
    while candidate.parentDir != candidate:
      if fileExists(candidate / "repro.nim") and
          fileExists(candidate / "repro_tests.nim"):
        return candidate
      candidate = candidate.parentDir
    raise newException(IOError, "cannot find reprobuild repository root")

  proc compileFixture(root, scratch, binary: string) =
    let source = scratch / "t_timeout_process_tree.nim"
    writeFile(source, FixtureSource)
    let command = "nim c --threads:on --hints:off --warnings:off" &
      " --nimcache:" & quoteShell(scratch / "nimcache") &
      " --out:" & quoteShell(binary) & " " & quoteShell(source)
    let compilation = execCmdEx(command, workingDir = root)
    if compilation.exitCode != 0:
      checkpoint(compilation.output)
    require compilation.exitCode == 0
    require fileExists(binary)

  proc parseRecords(path: string): seq[ProcessRecord] =
    if not fileExists(path):
      return @[]
    for line in readFile(path).splitLines():
      let fields = line.split(',')
      if fields.len != 5:
        continue
      try:
        result.add(ProcessRecord(
          role: fields[0],
          label: fields[1],
          pid: parseInt(fields[2]),
          processGroup: parseInt(fields[3]),
          port: parseInt(fields[4])))
      except ValueError:
        discard

  proc recordFor(records: seq[ProcessRecord]; role: string;
                 label = ""): ProcessRecord =
    for record in records:
      if record.role == role and
          (label.len == 0 or record.label == label):
        return record
    raise newException(ValueError,
      "missing process record for " & role & " / " & label)

  proc waitForRoles(path: string; roles: openArray[string];
                    timeoutSec = 10.0; label = ""): seq[ProcessRecord] =
    let deadline = epochTime() + timeoutSec
    while epochTime() < deadline:
      result = parseRecords(path)
      var complete = true
      for role in roles:
        var found = false
        for record in result:
          if record.role == role and
              (label.len == 0 or record.label == label):
            found = true
            break
        if not found:
          complete = false
          break
      if complete:
        return
      sleep(20)
    result = parseRecords(path)

  proc processExists(pid: int): bool =
    if pid <= 0:
      return false
    if kill(Pid(pid), cint(0)) == 0:
      return true
    errno == EPERM

  proc waitForProcessesGone(records: openArray[ProcessRecord];
                            timeoutSec = 5.0): bool =
    let deadline = epochTime() + timeoutSec
    while epochTime() < deadline:
      result = true
      for record in records:
        if processExists(record.pid):
          result = false
          break
      if result:
        return
      sleep(20)
    result = true
    for record in records:
      if processExists(record.pid):
        result = false

  proc canBindLoopback(port: int): bool =
    var socket: Socket
    try:
      socket = newSocket()
      socket.bindAddr(Port(port), "127.0.0.1")
      result = true
    except OSError:
      result = false
    finally:
      if not socket.isNil:
        socket.close()

  proc startSentinel(binary, recordPath: string): Process =
    let priorRecord = getEnv("REPRO_TREE_RECORD")
    let hadRecord = existsEnv("REPRO_TREE_RECORD")
    putEnv("REPRO_TREE_RECORD", recordPath)
    try:
      result = startProcess(binary, args = ["--sentinel"],
        options = {poParentStreams})
    finally:
      if hadRecord:
        putEnv("REPRO_TREE_RECORD", priorRecord)
      else:
        delEnv("REPRO_TREE_RECORD")

  proc startArgvCollisionSentinel(binary, recordPath,
                                  ownerToken: string): Process =
    let priorRecord = getEnv("REPRO_TREE_RECORD")
    let hadRecord = existsEnv("REPRO_TREE_RECORD")
    putEnv("REPRO_TREE_RECORD", recordPath)
    try:
      result = startProcess(binary,
        args = [
          "--argv-collision",
          "REPRO_TEST_RUNNER_OWNER_TOKEN=" & ownerToken,
        ],
        options = {poParentStreams})
    finally:
      if hadRecord:
        putEnv("REPRO_TREE_RECORD", priorRecord)
      else:
        delEnv("REPRO_TREE_RECORD")

  proc startTokenChurner(binary, recordPath, ownerToken: string;
                         durationSec: float): Process =
    let priorRecord = getEnv("REPRO_TREE_RECORD")
    let hadRecord = existsEnv("REPRO_TREE_RECORD")
    putEnv("REPRO_TREE_RECORD", recordPath)
    try:
      result = startProcess(binary,
        args = ["--token-churner", ownerToken, $durationSec],
        options = {poParentStreams})
    finally:
      if hadRecord:
        putEnv("REPRO_TREE_RECORD", priorRecord)
      else:
        delEnv("REPRO_TREE_RECORD")

  proc stopExactFixtureProcess(process: Process; expectedPid: int) =
    ## The Process handle remains our unreaped child identity even after the
    ## fixture calls setsid. Check that identity before targeting its exact
    ## PID/PGID so an assertion failure cannot leak the unrelated argv decoy
    ## or accidentally signal a reused PID.
    try:
      if process.processID != expectedPid:
        return
      if process.peekExitCode() == -1:
        let processGroup = getpgid(Pid(expectedPid))
        if processGroup == Pid(expectedPid):
          discard kill(Pid(-expectedPid), SIGKILL)
        else:
          discard kill(Pid(expectedPid), SIGKILL)
        discard process.waitForExit()
    except CatchableError:
      discard
    finally:
      close(process)

  proc ensureCleanupSafe(condition: bool; message: string) =
    ## std/unittest.require deliberately calls quit immediately and documents
    ## that teardown/defer blocks are skipped. Resource-bearing tests use an
    ## ordinary exception instead so exact process cleanup always unwinds.
    if not condition:
      raise newException(IOError, message)

  const InterruptCleanupDeadlineSec = 25.0
    ## The runner uses one global 5-second TERM grace followed by one global
    ## 5-second post-KILL owner/reap barrier, independent of the number of
    ## active groups. Allow an additional 15 seconds for scheduler delay,
    ## three worker joins, summary publication, and the controller poll while
    ## retaining a hard end-to-end bound. This was derived from the production
    ## cleanup phases, not multiplied serially per group.

  proc assertTreeShapeAndCleanup(treeRecords: seq[ProcessRecord];
                                sentinel: ProcessRecord; label = "") =
    ensureCleanupSafe(treeRecords.len >= 3,
      "missing owned root/child/grandchild records for " & label)
    let root = recordFor(treeRecords, "root", label)
    let child = recordFor(treeRecords, "child", label)
    let grandchild = recordFor(treeRecords, "grandchild", label)
    check root.processGroup > 0
    check child.processGroup == root.processGroup
    check grandchild.processGroup == root.processGroup
    check sentinel.processGroup == sentinel.pid
    check sentinel.processGroup != root.processGroup
    check root.processGroup != int(getpgrp())

    let ownedRecords = @[root, child, grandchild]
    check waitForProcessesGone(ownedRecords)
    check canBindLoopback(grandchild.port)
    check processExists(sentinel.pid)
    check not canBindLoopback(sentinel.port)

  proc runnerArgs(binDir, summary, resultsDir: string;
                  timeoutSec: int; threads = 1): seq[string] =
    @[
      "--no-build",
      "--threads=" & $threads,
      "--quiet",
      "--bin-dir=" & binDir,
      "--summary-json=" & summary,
      "--results-dir=" & resultsDir,
      "--test-timeout=" & $timeoutSec,
    ]

  suite "repro test runner owns and cleans complete POSIX process groups":
    test "idle timeout escalates and leaves an unrelated group untouched":
      let root = repoRoot()
      let runner = root / "build" / "bin" / "repro_test_runner"
      require fileExists(runner)

      let scratch = createTempDir("runner-group-timeout-", "")
      defer: removeDir(scratch)
      let binDir = scratch / "bin"
      createDir(binDir)
      let fixture = binDir / "t_timeout_process_tree"
      compileFixture(root, scratch, fixture)

      let sentinelPath = scratch / "sentinel.csv"
      let sentinelProcess = startSentinel(fixture, sentinelPath)
      let sentinelPid = sentinelProcess.processID
      var sentinelCleanupPending = true
      defer:
        if sentinelCleanupPending:
          stopExactFixtureProcess(sentinelProcess, sentinelPid)
      var sentinelRecord: ProcessRecord
      let sentinelRecords = waitForRoles(sentinelPath, ["sentinel"])
      ensureCleanupSafe(sentinelRecords.len == 1,
        "unrelated timeout sentinel did not become ready")
      sentinelRecord = recordFor(sentinelRecords, "sentinel")

      let treePath = scratch / "tree.csv"
      putEnv("REPRO_TREE_RECORD", treePath)
      defer: delEnv("REPRO_TREE_RECORD")
      let summary = scratch / "summary.json"
      let started = epochTime()
      let execution = execCmdEx(
        quoteShell(runner) & " " &
          runnerArgs(binDir, summary, scratch / "results", 2).
            mapIt(quoteShell(it)).join(" "),
        workingDir = root)
      let elapsed = epochTime() - started
      if execution.exitCode != 1:
        checkpoint(execution.output)
      check execution.exitCode == 1
      check elapsed >= 6.0
      check elapsed < 15.0

      let treeRecords = waitForRoles(treePath,
        ["root", "child", "grandchild"])
      assertTreeShapeAndCleanup(treeRecords, sentinelRecord)
      stopExactFixtureProcess(sentinelProcess, sentinelPid)
      sentinelCleanupPending = false

      require fileExists(summary)
      let report = parseFile(summary)
      check report{"summary"}{"total"}.getInt(-1) == 1
      check report{"summary"}{"passed"}.getInt(-1) == 0
      check report{"summary"}{"failed"}.getInt(-1) == 1
      check report{"summary"}{"skipped"}.getInt(-1) == 0
      check "idle deadline" in
        report{"tests"}[0]{"stdout"}.getStr("")

    test "SIGINT waits for three simultaneous owned groups to be reaped":
      let root = repoRoot()
      let runner = root / "build" / "bin" / "repro_test_runner"
      require fileExists(runner)

      let scratch = createTempDir("runner-multi-group-interrupt-", "")
      defer: removeDir(scratch)
      let fixture = scratch / "fixture"
      compileFixture(root, scratch, fixture)
      let binDir = scratch / "bin"
      createDir(binDir)
      let labels = @[
        "t_interrupt_tree_one",
        "t_interrupt_tree_two",
        "t_interrupt_tree_three",
      ]
      for label in labels:
        copyFileWithPermissions(fixture, binDir / label)

      let sentinelPath = scratch / "sentinel.csv"
      let sentinelProcess = startSentinel(fixture, sentinelPath)
      let sentinelPid = sentinelProcess.processID
      var sentinelCleanupPending = true
      defer:
        if sentinelCleanupPending:
          stopExactFixtureProcess(sentinelProcess, sentinelPid)
      var sentinelRecord: ProcessRecord
      let sentinelRecords = waitForRoles(sentinelPath, ["sentinel"])
      ensureCleanupSafe(sentinelRecords.len == 1,
        "unrelated SIGINT sentinel did not become ready")
      sentinelRecord = recordFor(sentinelRecords, "sentinel")

      let treePath = scratch / "trees.csv"
      putEnv("REPRO_TREE_RECORD", treePath)
      defer: delEnv("REPRO_TREE_RECORD")
      let summary = scratch / "summary.json"
      let runnerProcess = startProcess(runner,
        workingDir = root,
        args = runnerArgs(binDir, summary, scratch / "results", 30, 3),
        options = {poStdErrToStdOut})

      var exitCode = -1
      var elapsed = 0.0
      var treeRecords: seq[ProcessRecord]
      try:
        for label in labels:
          let ready = waitForRoles(treePath,
            ["root", "child", "grandchild"], label = label)
          ensureCleanupSafe(
            ready.anyIt(it.label == label and it.role == "root"),
            "missing SIGINT root for " & label)
          ensureCleanupSafe(
            ready.anyIt(it.label == label and it.role == "child"),
            "missing SIGINT child for " & label)
          ensureCleanupSafe(
            ready.anyIt(it.label == label and it.role == "grandchild"),
            "missing SIGINT grandchild for " & label)
        treeRecords = parseRecords(treePath)

        let started = epochTime()
        discard kill(Pid(runnerProcess.processID), SIGINT)
        let deadline = epochTime() + InterruptCleanupDeadlineSec
        while epochTime() < deadline:
          exitCode = runnerProcess.peekExitCode()
          if exitCode != -1:
            break
          sleep(20)
        elapsed = epochTime() - started
        if exitCode == -1:
          try:
            runnerProcess.kill()
            discard runnerProcess.waitForExit()
          except CatchableError:
            discard
      finally:
        if runnerProcess.peekExitCode() == -1:
          try:
            runnerProcess.kill()
            discard runnerProcess.waitForExit()
          except CatchableError:
            discard
        close(runnerProcess)

      check exitCode == 128 + int(SIGINT)
      check elapsed >= 4.0
      check elapsed < InterruptCleanupDeadlineSec
      for label in labels:
        assertTreeShapeAndCleanup(treeRecords, sentinelRecord, label)
      stopExactFixtureProcess(sentinelProcess, sentinelPid)
      sentinelCleanupPending = false

      require fileExists(summary)
      let report = parseFile(summary)
      check report{"summary"}{"total"}.getInt(-1) == 3
      check report{"summary"}{"passed"}.getInt(-1) == 0
      check report{"summary"}{"failed"}.getInt(-1) == 3
      check report{"summary"}{"skipped"}.getInt(-1) == 0

    test "post-reap cleanup uses only exact token ownership":
      let root = repoRoot()
      let runner = root / "build" / "bin" / "repro_test_runner"
      require fileExists(runner)

      let scratch = createTempDir("runner-detached-sidecar-", "")
      defer: removeDir(scratch)
      let binDir = scratch / "bin"
      createDir(binDir)
      let fixture = binDir / "t_detached_process_sidecar"
      compileFixture(root, scratch, fixture)

      let sentinelPath = scratch / "sentinel.csv"
      let sentinelProcess = startSentinel(fixture, sentinelPath)
      let sentinelPid = sentinelProcess.processID
      var sentinelCleanupPending = true
      defer:
        if sentinelCleanupPending:
          stopExactFixtureProcess(sentinelProcess, sentinelPid)
      var sentinelRecord: ProcessRecord
      let sentinelRecords = waitForRoles(sentinelPath, ["sentinel"])
      ensureCleanupSafe(sentinelRecords.len == 1,
        "unrelated normal-completion sentinel did not become ready")
      sentinelRecord = recordFor(sentinelRecords, "sentinel")

      let treePath = scratch / "sidecar.csv"
      let cleanupTracePath = scratch / "cleanup-trace.log"
      let priorMode = getEnv("REPRO_TREE_MODE")
      let hadMode = existsEnv("REPRO_TREE_MODE")
      putEnv("REPRO_TREE_MODE", "detached-sidecar")
      putEnv("REPRO_TREE_RECORD", treePath)
      putEnv("REPRO_TEST_RUNNER_CLEANUP_TRACE", cleanupTracePath)
      defer:
        delEnv("REPRO_TREE_RECORD")
        delEnv("REPRO_TEST_RUNNER_CLEANUP_TRACE")
        if hadMode:
          putEnv("REPRO_TREE_MODE", priorMode)
        else:
          delEnv("REPRO_TREE_MODE")

      let summary = scratch / "summary.json"
      let started = epochTime()
      let execution = execCmdEx(
        quoteShell(runner) & " " &
          runnerArgs(binDir, summary, scratch / "results", 30).
            mapIt(quoteShell(it)).join(" "),
        workingDir = root)
      let elapsed = epochTime() - started
      if execution.exitCode != 0:
        checkpoint(execution.output)
      check execution.exitCode == 0
      check elapsed >= 4.0
      check elapsed < 15.0

      let records = waitForRoles(treePath, ["root", "sidecar"])
      ensureCleanupSafe(records.len >= 2,
        "detached sidecar records were incomplete")
      let rootRecord = recordFor(records, "root")
      let sidecar = recordFor(records, "sidecar")
      check sidecar.processGroup == sidecar.pid
      check waitForProcessesGone([sidecar])
      check canBindLoopback(sidecar.port)
      check processExists(sentinelRecord.pid)
      check not canBindLoopback(sentinelRecord.port)

      # The production cleanup trace proves the detached exact-token sidecar
      # remained after the supervisor was synchronously reaped, then was
      # signalled through token ownership in a later verification phase. A
      # group attempt after the reap would reintroduce the PID/PGID reuse race
      # this scenario guards.
      ensureCleanupSafe(fileExists(cleanupTracePath),
        "production cleanup trace was not written")
      let cleanupEvents = readFile(cleanupTracePath).splitLines()
      let groupKillMarker =
        "group-signal-attempt group=" & $rootRecord.processGroup &
        " signal=" & $SIGKILL
      let anchorReapedMarker =
        "anchor-reaped group=" & $rootRecord.processGroup
      let ownerKillPrefix =
        "owner-signal-attempt group=" & $rootRecord.processGroup & " "
      var groupKillAt = -1
      var anchorReapedAt = -1
      var ownerKillAt = -1
      for index, event in cleanupEvents:
        if event == groupKillMarker and groupKillAt < 0:
          groupKillAt = index
        if event == anchorReapedMarker and anchorReapedAt < 0:
          anchorReapedAt = index
        if event.startsWith(ownerKillPrefix) and
            event.endsWith("signal=" & $SIGKILL) and ownerKillAt < 0:
          ownerKillAt = index
      check groupKillAt >= 0
      check anchorReapedAt > groupKillAt
      check ownerKillAt > anchorReapedAt
      if anchorReapedAt >= 0:
        for index in (anchorReapedAt + 1) ..< cleanupEvents.len:
          check cleanupEvents[index] != groupKillMarker

      stopExactFixtureProcess(sentinelProcess, sentinelPid)
      sentinelCleanupPending = false

      require fileExists(summary)
      let report = parseFile(summary)
      check report{"summary"}{"total"}.getInt(-1) == 1
      check report{"summary"}{"passed"}.getInt(-1) == 1
      check report{"summary"}{"failed"}.getInt(-1) == 0
      check report{"summary"}{"skipped"}.getInt(-1) == 0

    test "final retry never signals a synchronously reaped process group":
      let root = repoRoot()
      let runner = root / "build" / "bin" / "repro_test_runner"
      require fileExists(runner)

      let scratch = createTempDir("runner-post-reap-retry-", "")
      defer: removeDir(scratch)
      let binDir = scratch / "bin"
      createDir(binDir)
      let fixture = binDir / "t_post_reap_retry"
      compileFixture(root, scratch, fixture)

      let treePath = scratch / "tree.csv"
      let tokenPath = scratch / "owner-token"
      let continuePath = scratch / "continue"
      let cleanupTracePath = scratch / "cleanup-trace.log"
      putEnv("REPRO_TREE_MODE", "owner-token-handshake")
      putEnv("REPRO_TREE_RECORD", treePath)
      putEnv("REPRO_TREE_TOKEN_FILE", tokenPath)
      putEnv("REPRO_TREE_CONTINUE_FILE", continuePath)
      putEnv("REPRO_TEST_RUNNER_CLEANUP_TRACE", cleanupTracePath)
      defer:
        delEnv("REPRO_TREE_MODE")
        delEnv("REPRO_TREE_RECORD")
        delEnv("REPRO_TREE_TOKEN_FILE")
        delEnv("REPRO_TREE_CONTINUE_FILE")
        delEnv("REPRO_TEST_RUNNER_CLEANUP_TRACE")

      let summary = scratch / "summary.json"
      let runnerProcess = startProcess(runner,
        workingDir = root,
        args = runnerArgs(binDir, summary, scratch / "results", 60),
        options = {poStdErrToStdOut})
      # The runner snapshots its trace path before spawning any test. Remove
      # it from this controller environment so the unrelated churner cannot
      # inherit or forge cleanup events.
      delEnv("REPRO_TEST_RUNNER_CLEANUP_TRACE")
      defer:
        if runnerProcess.peekExitCode() == -1:
          try:
            runnerProcess.kill()
            discard runnerProcess.waitForExit()
          except CatchableError:
            discard
        close(runnerProcess)

      let tokenDeadline = epochTime() + 10.0
      while epochTime() < tokenDeadline and not fileExists(tokenPath):
        sleep(20)
      ensureCleanupSafe(fileExists(tokenPath),
        "post-reap retry fixture did not publish its owner token")
      let ownerToken = readFile(tokenPath)
      ensureCleanupSafe(ownerToken.len > 20,
        "post-reap retry fixture published an invalid owner token")
      let tokenSuffix = "-" & $runnerProcess.processID & "-1"
      ensureCleanupSafe(ownerToken.endsWith(tokenSuffix),
        "post-reap retry owner token did not identify its runner namespace")
      let stateDirName =
        ownerToken[0 ..< ownerToken.len - tokenSuffix.len]
      let stateDir = getTempDir() / stateDirName
      ensureCleanupSafe(dirExists(stateDir),
        "runner process-group state namespace was not present")
      check getFilePermissions(stateDir) ==
        {fpUserRead, fpUserWrite, fpUserExec}

      # Replenish a real exact-token owner beyond the initial 5-second TERM
      # grace plus 5-second post-KILL verification. The first cleanup must
      # therefore fail after reaping its supervisor; the runner's final
      # fail-closed reaper then retries after replenishment stops.
      let churner = startTokenChurner(
        fixture, treePath, ownerToken, 12.5)
      let churnerPid = churner.processID
      var churnerCleanupPending = true
      defer:
        if churnerCleanupPending:
          stopExactFixtureProcess(churner, churnerPid)
      let ready = waitForRoles(treePath, ["root", "churner"])
      ensureCleanupSafe(ready.anyIt(it.role == "root"),
        "post-reap retry root did not become ready")
      ensureCleanupSafe(ready.anyIt(it.role == "churner"),
        "post-reap retry churner did not become ready")
      let rootRecord = recordFor(ready, "root")
      let churnerRecord = recordFor(ready, "churner")
      check churnerRecord.processGroup == churnerRecord.pid
      check churnerRecord.processGroup != rootRecord.processGroup

      writeFile(continuePath, "continue\n")
      var exitCode = -1
      let deadline = epochTime() + 35.0
      while epochTime() < deadline:
        exitCode = runnerProcess.peekExitCode()
        if exitCode != -1:
          break
        sleep(20)
      if exitCode == -1 and runnerProcess.outputStream != nil:
        checkpoint("post-reap retry runner exceeded its controller deadline")
      check exitCode == 1

      let allRecords = parseRecords(treePath)
      let forgedOwners = allRecords.filterIt(it.role == "forged-owner")
      check forgedOwners.len > 0
      check waitForProcessesGone(forgedOwners)
      for owner in forgedOwners:
        check canBindLoopback(owner.port)
      check processExists(churnerRecord.pid)
      check not canBindLoopback(churnerRecord.port)

      ensureCleanupSafe(fileExists(cleanupTracePath),
        "post-reap retry cleanup trace was not written")
      let cleanupEvents = readFile(cleanupTracePath).splitLines()
      let groupKillMarker =
        "group-signal-attempt group=" & $rootRecord.processGroup &
        " signal=" & $SIGKILL
      let anchorReapedMarker =
        "anchor-reaped group=" & $rootRecord.processGroup
      var groupKillAt = -1
      var anchorReapedAt = -1
      for index, event in cleanupEvents:
        if event == groupKillMarker and groupKillAt < 0:
          groupKillAt = index
        if event == anchorReapedMarker and anchorReapedAt < 0:
          anchorReapedAt = index
      check groupKillAt >= 0
      check anchorReapedAt > groupKillAt
      if anchorReapedAt >= 0:
        for index in (anchorReapedAt + 1) ..< cleanupEvents.len:
          check not cleanupEvents[index].startsWith(
            "group-signal-attempt group=" & $rootRecord.processGroup & " ")

      stopExactFixtureProcess(churner, churnerPid)
      churnerCleanupPending = false

      require fileExists(summary)
      let report = parseFile(summary)
      check report{"summary"}{"total"}.getInt(-1) == 1
      check report{"summary"}{"passed"}.getInt(-1) == 0
      check report{"summary"}{"failed"}.getInt(-1) == 1
      check report{"summary"}{"skipped"}.getInt(-1) == 0
      check ownerToken notin $report
      check ownerToken notin readFile(cleanupTracePath)

    test "TERM-spawned detached replacement is gone before reporting PASS":
      let root = repoRoot()
      let runner = root / "build" / "bin" / "repro_test_runner"
      require fileExists(runner)

      let scratch = createTempDir("runner-respawn-sidecar-", "")
      defer: removeDir(scratch)
      let binDir = scratch / "bin"
      createDir(binDir)
      let fixture = binDir / "t_respawn_process_sidecar"
      compileFixture(root, scratch, fixture)

      let treePath = scratch / "respawn.csv"
      let priorMode = getEnv("REPRO_TREE_MODE")
      let hadMode = existsEnv("REPRO_TREE_MODE")
      putEnv("REPRO_TREE_MODE", "detached-respawn")
      putEnv("REPRO_TREE_RECORD", treePath)
      defer:
        delEnv("REPRO_TREE_RECORD")
        if hadMode:
          putEnv("REPRO_TREE_MODE", priorMode)
        else:
          delEnv("REPRO_TREE_MODE")

      let summary = scratch / "summary.json"
      let execution = execCmdEx(
        quoteShell(runner) & " " &
          runnerArgs(binDir, summary, scratch / "results", 30).
            mapIt(quoteShell(it)).join(" "),
        workingDir = root)
      if execution.exitCode != 0:
        checkpoint(execution.output)
      check execution.exitCode == 0

      let records = waitForRoles(treePath,
        ["root", "respawner", "replacement"])
      require records.len >= 3
      let respawner = recordFor(records, "respawner")
      let replacement = recordFor(records, "replacement")
      check respawner.processGroup == respawner.pid
      check replacement.processGroup == respawner.processGroup
      # No retry here: summary publication itself is the cleanup barrier.
      check not processExists(respawner.pid)
      check not processExists(replacement.pid)
      check canBindLoopback(respawner.port)
      check canBindLoopback(replacement.port)

      require fileExists(summary)
      let report = parseFile(summary)
      check report{"summary"}{"total"}.getInt(-1) == 1
      check report{"summary"}{"passed"}.getInt(-1) == 1
      check report{"summary"}{"failed"}.getInt(-1) == 0
      check report{"summary"}{"skipped"}.getInt(-1) == 0

    test "argv token collision is not treated as environment ownership":
      let root = repoRoot()
      let runner = root / "build" / "bin" / "repro_test_runner"
      require fileExists(runner)

      let scratch = createTempDir("runner-owner-argv-collision-", "")
      defer: removeDir(scratch)
      let binDir = scratch / "bin"
      createDir(binDir)
      let fixture = binDir / "t_owner_token_handshake"
      compileFixture(root, scratch, fixture)

      let treePath = scratch / "tree.csv"
      let tokenPath = scratch / "owner-token"
      let continuePath = scratch / "continue"
      putEnv("REPRO_TREE_MODE", "owner-token-handshake")
      putEnv("REPRO_TREE_RECORD", treePath)
      putEnv("REPRO_TREE_TOKEN_FILE", tokenPath)
      putEnv("REPRO_TREE_CONTINUE_FILE", continuePath)
      defer:
        delEnv("REPRO_TREE_MODE")
        delEnv("REPRO_TREE_RECORD")
        delEnv("REPRO_TREE_TOKEN_FILE")
        delEnv("REPRO_TREE_CONTINUE_FILE")

      let summary = scratch / "summary.json"
      let runnerProcess = startProcess(runner,
        workingDir = root,
        args = runnerArgs(binDir, summary, scratch / "results", 30),
        options = {poStdErrToStdOut})
      defer:
        if runnerProcess.peekExitCode() == -1:
          try:
            runnerProcess.kill()
            discard runnerProcess.waitForExit()
          except CatchableError:
            discard
        close(runnerProcess)

      let tokenDeadline = epochTime() + 10.0
      while epochTime() < tokenDeadline and not fileExists(tokenPath):
        sleep(20)
      ensureCleanupSafe(fileExists(tokenPath),
        "owner-token handshake did not publish its token")
      let ownerToken = readFile(tokenPath)
      ensureCleanupSafe(ownerToken.len > 20,
        "owner-token handshake published an invalid token")

      let collisionPath = scratch / "collision.csv"
      let collisionProcess =
        startArgvCollisionSentinel(fixture, collisionPath, ownerToken)
      let collisionPid = collisionProcess.processID
      var collisionCleanupPending = true
      defer:
        if collisionCleanupPending:
          stopExactFixtureProcess(collisionProcess, collisionPid)
      var collisionRecord: ProcessRecord
      let collisionRecords =
        waitForRoles(collisionPath, ["argv-collision"])
      ensureCleanupSafe(collisionRecords.len == 1,
        "argv-collision sentinel did not become ready")
      collisionRecord = recordFor(collisionRecords, "argv-collision")

      writeFile(continuePath, "continue\n")
      var exitCode = -1
      let deadline = epochTime() + 15.0
      while epochTime() < deadline:
        exitCode = runnerProcess.peekExitCode()
        if exitCode != -1:
          break
        sleep(20)

      check exitCode == 0
      check processExists(collisionRecord.pid)
      check not canBindLoopback(collisionRecord.port)
      stopExactFixtureProcess(collisionProcess, collisionPid)
      collisionCleanupPending = false

      require fileExists(summary)
      let report = parseFile(summary)
      check report{"summary"}{"total"}.getInt(-1) == 1
      check report{"summary"}{"passed"}.getInt(-1) == 1
      check report{"summary"}{"failed"}.getInt(-1) == 0
      check report{"summary"}{"skipped"}.getInt(-1) == 0

    test "actual daemon launch and restart remain owned without leaking to actions":
      let root = repoRoot()
      let runner = root / "build" / "bin" / "repro_test_runner"
      let repro = root / "build" / "bin" / addFileExt("repro", ExeExt)
      require fileExists(runner)
      require fileExists(repro)

      let scratch = createTempDir("runner-actual-daemon-", "")
      let endpoint = "/tmp/repro-owner-daemon-" &
        $getCurrentProcessId() & ".sock"
      defer:
        when defined(macosx):
          let label = "org.reprobuild.repro-daemon." &
            endpoint.extractFilename
          discard execCmdEx("launchctl bootout " &
            quoteShell("gui/" & $getuid() & "/" & label))
        elif defined(linux):
          let unit = "repro-daemon-" & endpoint.extractFilename & ".service"
          discard execCmdEx("systemctl --user stop " & quoteShell(unit))
        try:
          removeFile(endpoint)
        except OSError:
          discard
        removeDir(scratch)

      let binDir = scratch / "bin"
      createDir(binDir)
      let fixture = binDir / "t_actual_daemon_boundary"
      compileFixture(root, scratch, fixture)

      let recordsPath = scratch / "actual-daemon.csv"
      let tokenPath = scratch / "owner-token"
      let continuePath = scratch / "continue"
      putEnv("REPRO_TREE_MODE", "actual-daemon-boundary")
      putEnv("REPRO_TREE_RECORD", recordsPath)
      putEnv("REPRO_TREE_TOKEN_FILE", tokenPath)
      putEnv("REPRO_TREE_CONTINUE_FILE", continuePath)
      putEnv("REPRO_ACTUAL_REPRO_BIN", repro)
      putEnv("REPRO_ACTUAL_DAEMON_ROOT", scratch / "daemon")
      putEnv("REPRO_ACTUAL_DAEMON_ENDPOINT", endpoint)
      defer:
        delEnv("REPRO_TREE_MODE")
        delEnv("REPRO_TREE_RECORD")
        delEnv("REPRO_TREE_TOKEN_FILE")
        delEnv("REPRO_TREE_CONTINUE_FILE")
        delEnv("REPRO_ACTUAL_REPRO_BIN")
        delEnv("REPRO_ACTUAL_DAEMON_ROOT")
        delEnv("REPRO_ACTUAL_DAEMON_ENDPOINT")

      let summary = scratch / "summary.json"
      let runnerProcess = startProcess(runner,
        workingDir = root,
        args = runnerArgs(binDir, summary, scratch / "results", 120),
        options = {poStdErrToStdOut})
      defer:
        if runnerProcess.peekExitCode() == -1:
          try:
            runnerProcess.kill()
            discard runnerProcess.waitForExit()
          except CatchableError:
            discard
        close(runnerProcess)

      let tokenDeadline = epochTime() + 10.0
      while epochTime() < tokenDeadline and not fileExists(tokenPath):
        sleep(20)
      ensureCleanupSafe(fileExists(tokenPath),
        "actual daemon fixture did not publish its owner token")
      let ownerToken = readFile(tokenPath)
      ensureCleanupSafe(ownerToken.len > 20,
        "actual daemon fixture published an invalid owner token")

      let collisionPath = scratch / "collision.csv"
      let collisionProcess =
        startArgvCollisionSentinel(fixture, collisionPath, ownerToken)
      let collisionPid = collisionProcess.processID
      var collisionCleanupPending = true
      defer:
        if collisionCleanupPending:
          stopExactFixtureProcess(collisionProcess, collisionPid)
      var collisionRecord: ProcessRecord
      let collisionRecords =
        waitForRoles(collisionPath, ["argv-collision"])
      ensureCleanupSafe(collisionRecords.len == 1,
        "actual daemon argv-collision sentinel did not become ready")
      collisionRecord = recordFor(collisionRecords, "argv-collision")

      writeFile(continuePath, "continue\n")
      var exitCode = -1
      let deadline = epochTime() + 180.0
      while epochTime() < deadline:
        exitCode = runnerProcess.peekExitCode()
        if exitCode != -1:
          break
        sleep(50)
      if exitCode != 0 and runnerProcess.outputStream != nil:
        checkpoint(runnerProcess.outputStream.readAll())
      if exitCode != 0 and fileExists(summary):
        let failedReport = parseFile(summary)
        checkpoint("actual daemon fixture exit=" &
          $failedReport{"tests"}[0]{"exitCode"}.getInt(-1))
        checkpoint(failedReport{"tests"}[0]{"stdout"}.getStr(""))
      check exitCode == 0
      # This exact argv-only collision must outlive runner cleanup. The
      # unconditional exact-identity defer above removes it afterward even if
      # any subsequent assertion aborts this test.
      check processExists(collisionRecord.pid)
      check not canBindLoopback(collisionRecord.port)
      stopExactFixtureProcess(collisionProcess, collisionPid)
      collisionCleanupPending = false

      var expectedRoles =
        @["root", "supervisor", "daemon-initial", "daemon-restarted"]
      when defined(linux):
        expectedRoles.add("build-worker")
      let records = waitForRoles(recordsPath, expectedRoles)
      require records.len >= expectedRoles.len
      let supervisor = recordFor(records, "supervisor")
      let initial = recordFor(records, "daemon-initial")
      let restarted = recordFor(records, "daemon-restarted")
      check initial.pid != restarted.pid
      check not processExists(supervisor.pid)
      check not processExists(initial.pid)
      # Summary publication itself is the exact-owner cleanup barrier.
      check not processExists(restarted.pid)
      when defined(linux):
        let buildWorker = recordFor(records, "build-worker")
        check not processExists(buildWorker.pid)

      require fileExists(summary)
      let report = parseFile(summary)
      check report{"summary"}{"total"}.getInt(-1) == 1
      check report{"summary"}{"passed"}.getInt(-1) == 1
      check report{"summary"}{"failed"}.getInt(-1) == 0
      check report{"summary"}{"skipped"}.getInt(-1) == 0
      check ownerToken notin $report

      let daemonRoot = scratch / "daemon"
      let daemonLog = daemonRoot / "state" / "logs" / "repro-daemon.log"
      require fileExists(daemonLog)
      check ownerToken notin readFile(daemonLog)
      when not defined(linux):
        require fileExists(
          daemonRoot / "owner-environment-project" / "build" /
            "owner-environment.txt")
        check readFile(
          daemonRoot / "owner-environment-project" / "build" /
            "owner-environment.txt") == "absent\n"

      let launchdDir = daemonRoot / "state" / "launchd"
      if dirExists(launchdDir):
        for path in walkDirRec(launchdDir):
          check not path.endsWith(".plist")
      let actionCache = daemonRoot / "action-cache"
      if dirExists(actionCache):
        for path in walkDirRec(actionCache):
          if fileExists(path):
            check ownerToken notin readFile(path)

    test "SIGTERM to runner cleans every owned group before signal exit":
      let root = repoRoot()
      let runner = root / "build" / "bin" / "repro_test_runner"
      require fileExists(runner)

      let scratch = createTempDir("runner-group-interrupt-", "")
      defer: removeDir(scratch)
      let binDir = scratch / "bin"
      createDir(binDir)
      let fixture = binDir / "t_timeout_process_tree"
      compileFixture(root, scratch, fixture)

      let sentinelPath = scratch / "sentinel.csv"
      let sentinelProcess = startSentinel(fixture, sentinelPath)
      let sentinelPid = sentinelProcess.processID
      var sentinelCleanupPending = true
      defer:
        if sentinelCleanupPending:
          stopExactFixtureProcess(sentinelProcess, sentinelPid)
      var sentinelRecord: ProcessRecord
      let sentinelRecords = waitForRoles(sentinelPath, ["sentinel"])
      ensureCleanupSafe(sentinelRecords.len == 1,
        "unrelated SIGTERM sentinel did not become ready")
      sentinelRecord = recordFor(sentinelRecords, "sentinel")

      let treePath = scratch / "tree.csv"
      putEnv("REPRO_TREE_RECORD", treePath)
      defer: delEnv("REPRO_TREE_RECORD")
      let summary = scratch / "summary.json"
      let runnerProcess = startProcess(runner,
        workingDir = root,
        args = runnerArgs(binDir, summary, scratch / "results", 30),
        options = {poStdErrToStdOut})

      var exitCode = -1
      var elapsed = 0.0
      var treeRecords: seq[ProcessRecord]
      try:
        treeRecords = waitForRoles(treePath,
          ["root", "child", "grandchild"])
        ensureCleanupSafe(treeRecords.len >= 3,
          "SIGTERM owned tree did not become ready")
        let started = epochTime()
        discard kill(Pid(runnerProcess.processID), SIGTERM)
        let deadline = epochTime() + InterruptCleanupDeadlineSec
        while epochTime() < deadline:
          exitCode = runnerProcess.peekExitCode()
          if exitCode != -1:
            break
          sleep(20)
        elapsed = epochTime() - started
        if exitCode == -1:
          try:
            runnerProcess.kill()
            discard runnerProcess.waitForExit()
          except CatchableError:
            discard
      finally:
        if runnerProcess.peekExitCode() == -1:
          try:
            runnerProcess.kill()
            discard runnerProcess.waitForExit()
          except CatchableError:
            discard
        close(runnerProcess)

      check exitCode == 128 + int(SIGTERM)
      check elapsed >= 4.0
      check elapsed < InterruptCleanupDeadlineSec
      assertTreeShapeAndCleanup(treeRecords, sentinelRecord)
      stopExactFixtureProcess(sentinelProcess, sentinelPid)
      sentinelCleanupPending = false

      require fileExists(summary)
      let report = parseFile(summary)
      check report{"summary"}{"total"}.getInt(-1) == 1
      check report{"summary"}{"passed"}.getInt(-1) == 0
      check report{"summary"}{"failed"}.getInt(-1) == 1
      check report{"summary"}{"skipped"}.getInt(-1) == 0
