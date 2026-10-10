## End-to-end gates over `repro up` / `repro dev` / `repro down`.
##
## MOCKS: NONE. Most cases drive the real `build/bin/repro` as a child
## process against a real project directory on the real filesystem, with real
## supervised services (`sh` scripts that really sleep and really touch their
## readiness files) and the real HTTP control API over a real loopback socket.
## The defect these gates were added for -- a parent that abandoned a healthy
## session after a hardcoded ten seconds -- is a disagreement between two
## PROCESSES about a wall-clock duration, so a fake clock or a stubbed
## supervisor would have removed the thing under test. One case therefore
## genuinely spends twelve seconds; see
## `e2e_repro_up_waits_for_a_service_slower_than_ten_seconds`.
##
## FOUR CASES DO NOT SPAWN `repro`, and none substitutes a fake for
## anything:
##
## * `e2e_dev_session_wait_names_a_control_api_that_never_answered` calls
##   `waitForDevSessionReady` in this process against a real session
##   directory holding a real `http-ready.json` that names a real -- and
##   really closed -- loopback port. The condition under test is a control
##   API that publishes its bind and then does not answer, and there is no
##   way to stage it through the CLI without a race: the supervisor removes
##   the stale ready file before its child publishes a fresh one, so the
##   only CLI-level route is to kill the child in the few milliseconds
##   between its publish and the parent's first poll. The proc under test,
##   the directory, the socket and the failure are all real; what is
##   narrowed is the entry point.
## * `e2e_dev_session_wait_reports_a_supervisor_that_published_no_bind`
##   calls `waitForDevSessionReady` in this process against a real session
##   directory in which `http-ready.json` is genuinely absent. The
##   condition is a supervisor that publishes no control-API bind inside
##   the parent's budget, and it cannot be staged through the CLI without
##   racing the control-API child, which binds within milliseconds. The
##   directory, the absent file, the clock and the proc are all real.
## * `e2e_dev_session_wait_reports_a_peer_that_publishes_no_status` stands
##   a REAL loopback HTTP server, in its own process, in front of a real
##   session directory, and calls `waitForDevSessionReady` against it. The
##   arm under test handles a peer that answers 2xx with JSON carrying no
##   `status`, which this module's own `/status` cannot produce (it serves
##   `session.json`, which always carries one, or 404) -- so the peer is
##   the thing being staged, and staging it means running a different
##   server rather than faking anything. See `startStatuslessPeer`.
## * `e2e_reap_session_only_kills_pids_that_name_the_session` exercises this
##   file's own `reapSession` against two real `sh` processes. See its
##   comment.
##
## TWO CASES STAGE A SESSION DIRECTORY BY HAND and then drive the real
## `repro` against it --
## `e2e_repro_up_does_not_report_a_stale_sessions_identity`
## and `e2e_repro_down_diagnostic_says_what_it_observed`. The files they
## write are exactly what a previous session would have left, and the ports
## they name are real loopback ports that are really closed; what is
## replaced is the history, not any part of the code under test.

import std/[json, net, os, osproc, sequtils, strtabs, streams, strutils,
    tempfiles, times, unittest]

import repro_test_support
import repro_cli_support/dev_session

proc q(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

# prepareMonitorTools is exported from libs/repro_test_support.

# Test-Fixtures-In-Build-Graph M1: ``repro`` is a build-graph artifact
# (``reprobuild.apps.repro`` → ``build/bin/repro``, built by ``just bootstrap``
# / the apps collection before tests run). Assert it exists and use it instead
# of recompiling ``apps/repro/repro.nim`` at test runtime.
proc reproBinary(): string =
  requireBinary(getCurrentDir() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc writeExecutable(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc serviceJson(command: seq[string]; readinessPath: string;
                 dependsOn: seq[string] = @[];
                 readinessTimeoutMs = 5000): string =
  var root = %*{
    "schemaId": "reprobuild.dev-session.service.v1",
    "command": command,
    "cwd": ".",
    "readiness": {
      "kind": "fileExists",
      "path": readinessPath,
      "timeoutMs": readinessTimeoutMs
    },
    "resources": [
      {"kind": "directory", "path": "state"}
    ]
  }
  if dependsOn.len > 0:
    root["dependsOn"] = %dependsOn
  $root

proc providerText(services: openArray[tuple[name, metadata: string]];
                  taskCommand = ""; readSource = false): string =
  result = "import std/strutils\n" &
    "import repro_project_dsl\n\n" &
    "package fixture:\n" &
    "  devEnv:\n" &
    "    activity \"default\"\n" &
    "    setEnv \"M8_STATE_DIR\", \"state\"\n"
  if readSource:
    result.add("    setEnv \"M8_SOURCE\", readDevEnvFile(\"watch-source.txt\").strip()\n")
  if taskCommand.len > 0:
    result.add("    task \"watch-task\", command = \"" &
      taskCommand.replace("\\", "\\\\").replace("\"", "\\\"") & "\"\n")
  for service in services:
    result.add("    servicePlaceholder \"" & service.name &
      "\", metadata = \"\"\"" & service.metadata & "\"\"\"\n")

proc writeUpDownFixture(dir: string) =
  createDir(dir)
  createDir(dir / "scripts")
  writeExecutable(dir / "scripts" / "db.sh",
    "#!/bin/sh\n" &
      "mkdir -p state\n" &
      "printf 'db-start\\n' >> state/order.log\n" &
      "touch state/db.ready\n" &
      "trap 'printf \"db-stop\\n\" >> state/order.log; exit 0' TERM INT\n" &
      "while :; do sleep 1; done\n")
  writeExecutable(dir / "scripts" / "api.sh",
    "#!/bin/sh\n" &
      "mkdir -p state\n" &
      "test -f state/db.ready || exit 12\n" &
      "printf 'api-start\\n' >> state/order.log\n" &
      "touch state/api.ready\n" &
      "trap 'printf \"api-stop\\n\" >> state/order.log; exit 0' TERM INT\n" &
      "while :; do sleep 1; done\n")
  writeFile(dir / "reprobuild.nim", providerText([
    (name: "db", metadata: serviceJson(@["sh", "scripts/db.sh"],
      "state/db.ready")),
    (name: "api", metadata: serviceJson(@["sh", "scripts/api.sh"],
      "state/api.ready", dependsOn = @["db"]))
  ]))

proc writeReadinessFixture(dir: string; sleepSeconds: int;
                           readinessTimeoutMs: int;
                           everReady = true) =
  ## One service that becomes ready ``sleepSeconds`` after it starts (or
  ## never, when ``everReady`` is false) and DECLARES
  ## ``readinessTimeoutMs``. The two numbers are independent on purpose:
  ## they are exactly the pair the defect confused -- what the service says
  ## it needs, and what it actually takes.
  createDir(dir)
  createDir(dir / "scripts")
  writeExecutable(dir / "scripts" / "slow.sh",
    "#!/bin/sh\n" &
      "mkdir -p state\n" &
      "printf 'slow-start\\n' >> state/order.log\n" &
      "sleep " & $sleepSeconds & "\n" &
      (if everReady: "touch state/slow.ready\n" else: "") &
      "trap 'printf \"slow-stop\\n\" >> state/order.log; exit 0' TERM INT\n" &
      "while :; do sleep 1; done\n")
  writeFile(dir / "reprobuild.nim", providerText([
    (name: "slow", metadata: serviceJson(@["sh", "scripts/slow.sh"],
      "state/slow.ready", readinessTimeoutMs = readinessTimeoutMs))
  ]))

proc writeStubbornStopFixture(dir: string; services: int) =
  ## ``services`` services that each IGNORE SIGTERM and therefore burn the
  ## supervisor's whole per-service stop grace before it reaches ``kill()``.
  ##
  ## Nothing here is a stub: these are real `sh` processes with a real
  ## `trap "" TERM`, which is a thing a real service does (a wrapper that
  ## forwards signals to a child it is still draining, a process in an
  ## uninterruptible write). The point is to make the supervisor's stop cost
  ## what ``stopServices`` ALLOWS it to cost, so a waiter's budget is
  ## observable from the outside: with the grace at 3000 ms, four services
  ## put the supervisor's own stop past the ten seconds ``repro down`` used
  ## to allow.
  createDir(dir)
  createDir(dir / "scripts")
  var specs: seq[tuple[name, metadata: string]] = @[]
  for i in 0 ..< services:
    let name = "svc" & $i
    writeExecutable(dir / "scripts" / (name & ".sh"),
      "#!/bin/sh\n" &
        "mkdir -p state\n" &
        "trap '' TERM INT\n" &
        "touch state/" & name & ".ready\n" &
        "while :; do sleep 1; done\n")
    specs.add((name: name, metadata: serviceJson(
      @["sh", "scripts/" & name & ".sh"], "state/" & name & ".ready")))
  writeFile(dir / "reprobuild.nim", providerText(specs))

proc writeDevFixture(dir: string) =
  createDir(dir)
  createDir(dir / "scripts")
  writeFile(dir / "watch-source.txt", "one\n")
  writeExecutable(dir / "scripts" / "worker.sh",
    "#!/bin/sh\n" &
      "mkdir -p state\n" &
      "printf 'worker-start\\n' >> state/dev.log\n" &
      "touch state/worker.ready\n" &
      "trap 'printf \"worker-stop\\n\" >> state/dev.log; exit 0' TERM INT\n" &
      "while :; do sleep 1; done\n")
  writeExecutable(dir / "scripts" / "watch-task.sh",
    "#!/bin/sh\n" &
      "mkdir -p state\n" &
      "printf 'task:%s\\n' \"$M8_SOURCE\" >> state/watch.log\n" &
      "printf 'watch-task:%s\\n' \"$M8_SOURCE\"\n")
  writeFile(dir / "reprobuild.nim", providerText([
    (name: "worker", metadata: serviceJson(@["sh", "scripts/worker.sh"],
      "state/worker.ready"))
  ], taskCommand = "sh scripts/watch-task.sh", readSource = true))

type
  M8Case = object
    tempRoot: string
    projectRoot: string
    repoRoot: string
    reproBin: string
    monitorCliPath: string
    shim: string

proc prepareCase(prefix: string; dev = false;
                 writeFixture: proc (dir: string) = nil): M8Case =
  result.repoRoot = getCurrentDir()
  result.tempRoot = createTempDir(prefix, "")
  result.projectRoot = result.tempRoot / "project"
  if writeFixture != nil:
    writeFixture(result.projectRoot)
  elif dev:
    writeDevFixture(result.projectRoot)
  else:
    writeUpDownFixture(result.projectRoot)
  result.reproBin = reproBinary()
  when isIoMonitorSupported:
    let monitor = prepareMonitorTools(result.repoRoot, result.tempRoot, "m8-dev-sessions")
    result.monitorCliPath = monitor.monitorCliPath
    result.shim = monitor.shim

proc envFor(c: M8Case): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["REPROBUILD_SOURCE_ROOT"] = c.repoRoot
  result["REPRO_MONITOR_SHIM_LIB"] = c.shim

proc runProgram(program: string; args: openArray[string]; cwd: string;
                env: StringTableRef = nil): tuple[exitCode: int; output: string] =
  var process = startProcess(program,
    args = @args,
    workingDir = cwd,
    env = env,
    options = {poUsePath, poStdErrToStdOut})
  let output =
    if process.outputStream != nil: process.outputStream.readAll()
    else: ""
  let exitCode = process.waitForExit()
  process.close()
  (exitCode: exitCode, output: output)

proc runRepro(c: M8Case; args: openArray[string]):
    tuple[exitCode: int; output: string] =
  runProgram(c.reproBin, args, c.repoRoot, c.envFor())

proc requireRepro(c: M8Case; args: openArray[string]): string =
  let res = runRepro(c, args)
  if res.exitCode != 0:
    raise newException(OSError,
      "repro command failed with exit " & $res.exitCode & ": " &
        args.join(" ") & "\n" & res.output)
  res.output

proc sessionMetadataPath(projectRoot: string): string =
  projectRoot / ".repro" / "dev-env" / "default" / "session" / "session.json"

proc waitForStatus(path, status: string; timeoutMs = 10000): JsonNode =
  var waited = 0
  var lastBody = ""
  var lastStatus = ""
  var lastError = ""
  while waited <= timeoutMs:
    if fileExists(path):
      try:
        lastBody = readFile(path)
        let node = parseJson(lastBody)
        lastStatus = node{"status"}.getStr()
        if lastStatus == status:
          return node
      except CatchableError as err:
        lastError = err.msg
    sleep(50)
    waited.inc(50)
  checkpoint("session metadata path: " & path)
  if lastStatus.len > 0:
    checkpoint("last session status: " & lastStatus)
  if lastError.len > 0:
    checkpoint("last session metadata parse error: " & lastError)
  if lastBody.len > 0:
    checkpoint("last session metadata body:\n" & lastBody)
  else:
    checkpoint("session metadata file was not present")
  raise newException(IOError, "timed out waiting for session status " & status)

proc httpRequest(httpBindValue, path: string; httpMethod = "GET"): string =
  let script =
    "import http.client, sys, urllib.parse\n" &
    "u=urllib.parse.urlparse(sys.argv[1])\n" &
    "conn=http.client.HTTPConnection(u.hostname, u.port, timeout=5)\n" &
    "conn.request(sys.argv[3], sys.argv[2])\n" &
    "resp=conn.getresponse()\n" &
    "body=resp.read().decode()\n" &
    "print(body, end='')\n" &
    "sys.exit(0 if 200 <= resp.status < 300 else 1)\n"
  requireSuccess(shellCommand(@["python3", "-c", script,
    httpBindValue, path, httpMethod]))

proc statusJson(httpBindValue: string): JsonNode =
  parseJson(httpRequest(httpBindValue, "/status"))

proc sseEvents(httpBindValue: string; waitMs = 500): seq[JsonNode] =
  let text = httpRequest(httpBindValue, "/events?wait-ms=" & $waitMs)
  for line in text.splitLines:
    if line.startsWith("data: "):
      result.add(parseJson(line["data: ".len .. ^1]))

proc eventKinds(events: openArray[JsonNode]): seq[string] =
  events.mapIt(it{"kind"}.getStr())

proc kindCount(kinds: openArray[string]; kind: string): int =
  for item in kinds:
    if item == kind:
      inc result

proc kindIndex(kinds: openArray[string]; kind: string): int =
  for i, item in kinds:
    if item == kind:
      return i
  -1

proc terminalEventKinds(text: string): seq[string] =
  for line in text.splitLines:
    let marker = "repro dev-session event="
    let pos = line.find(marker)
    if pos >= 0:
      var rest = line[pos + marker.len .. ^1]
      let space = rest.find(' ')
      if space >= 0:
        rest = rest[0 ..< space]
      result.add(rest)

proc pidAlive(pid: int): bool =
  when defined(windows):
    false
  else:
    runShell(shellCommand(@["kill", "-0", $pid])).code == 0

proc reportedWaitMs(output: string): int =
  ## The wait the parent PUBLISHED in its diagnostic, in ms.
  ##
  ## Asserted on instead of the wall clock around `repro up`, because that
  ## clock includes the dev-env edge computation -- tens of seconds on a
  ## loaded host -- and the readiness wait is the only part of it these
  ## gates are about. The number is the parent's own measurement of its own
  ## wait, which is exactly the quantity under test.
  result = -1
  const marker = "the parent waited "
  let pos = output.find(marker)
  if pos < 0:
    return
  let rest = output[pos + marker.len .. ^1]
  let stop = rest.find(" ms")
  if stop > 0:
    result = parseInt(rest[0 ..< stop])

proc eventTimes(projectRoot, kind: string): seq[DateTime] =
  ## Every `events.jsonl` timestamp for one event kind, parsed.
  let path = projectRoot / ".repro" / "dev-env" / "default" / "session" /
    "events.jsonl"
  for line in readFile(path).splitLines():
    if line.len == 0:
      continue
    let node = parseJson(line)
    if node{"kind"}.getStr() == kind:
      result.add(parse(node{"time"}.getStr(),
        "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'", utc()))

proc belongsToSession(pid: int; projectRoot: string): bool =
  ## Does this pid still look like something THIS session started?
  ##
  ## Asked before every signal, because a pid read out of `session.json` is
  ## a HISTORICAL RECORD, not a handle. Between the supervisor writing it
  ## and this file reading it the process may have exited and the number
  ## been reissued -- to a nim compiler, to a parallel test's fixture, to a
  ## login shell. Killing by number alone turns a reap of a dead session
  ## into an attack on a live stranger, and SIGKILL gives the stranger no
  ## say.
  ##
  ## TWO WITNESSES, because the session's processes do not all name the
  ## session the same way. The supervisor and the control-API child carry
  ## the session's own directories in their argv (`--project-root`,
  ## `--out-dir`, `--session-dir`); a supervised service is whatever the
  ## fixture declared (`sh scripts/slow.sh`) and names nothing at all -- its
  ## only link to the session is its WORKING DIRECTORY, which the supervisor
  ## sets to the project root. Requiring argv alone would leave every
  ## service process behind, which is the leak `reapSession` exists to
  ## close; requiring cwd alone would miss a supervisor whose cwd moved.
  ##
  ## `projectRoot` is this case's own `createTempDir` path, so either
  ## witness is a strong one here.
  ##
  ## LINUX ONLY, and the `else` branch is a decision rather than a gap. Both
  ## witnesses come from `/proc`, which no other platform has. On a platform
  ## without it, argv alone would place the supervisor and the control-API
  ## child and NOTHING ELSE -- a supervised service's argv is the fixture's
  ## own command -- so a guard built on argv alone would stop reaping every
  ## service and leak them instead. That trades a recycled-pid risk for a
  ## certain leak, on a platform this change cannot measure. So the answer
  ## there stays what it was before this guard existed, and the case that
  ## proves the guard is Linux-only too, deliberately and visibly.
  when defined(windows):
    false
  elif defined(linux):
    let cmdline =
      try:
        readFile("/proc/" & $pid & "/cmdline")
      except CatchableError:
        ""
    if cmdline.len > 0 and cmdline.contains(projectRoot):
      return true
    try:
      let cwd = expandSymlink("/proc/" & $pid & "/cwd")
      cwd == projectRoot or cwd.startsWith(projectRoot & "/")
    except CatchableError:
      false
  else:
    true

proc reapSession(projectRoot: string) =
  ## BEST-EFFORT reap of whatever the session left behind, by pid, after
  ## confirming each pid still belongs to this session.
  ##
  ## Needed because a supervisor that gives up on a service exits WITHOUT
  ## stopping the control-API child or the services it had already started
  ## -- a pre-existing leak that `recordStartFailure` reports but does not
  ## repair. A test that drives a failing start therefore has to reap, or it
  ## leaves processes behind for every later case to trip over.
  ##
  ## WHAT THIS IS NOT: a guarantee that nothing leaks. It kills the pids the
  ## session PUBLISHED, so a process the session started but never recorded
  ## -- a grandchild a service forked, a service whose pid was not written
  ## before the supervisor died -- survives it. The structural fix belongs
  ## in the supervisor (stop what you started, on the way out), not here,
  ## and until that exists a case that relies on this for cleanliness should
  ## say so rather than assume it.
  when not defined(windows):
    let sessionDir = projectRoot / ".repro" / "dev-env" / "default" / "session"
    var pids: seq[int] = @[]
    for file in ["session.json", "http-ready.json"]:
      let path = sessionDir / file
      if not fileExists(path):
        continue
      try:
        let node = parseJson(readFile(path))
        if node.hasKey("pid"):
          pids.add(node["pid"].getInt())
        if node.hasKey("supervisorPid"):
          pids.add(node["supervisorPid"].getInt())
        if node.hasKey("services"):
          for service in node["services"]:
            pids.add(service{"pid"}.getInt())
      except CatchableError:
        discard
    for pid in pids:
      if pid > 0 and belongsToSession(pid, projectRoot):
        discard runShell(shellCommand(@["kill", "-TERM", $pid]))
    sleep(300)
    # Re-checked rather than reused: a pid that exited under the SIGTERM
    # above needs no SIGKILL, and if its number has already been reissued
    # the second signal is exactly the one that must not be sent.
    for pid in pids:
      if pid > 0 and belongsToSession(pid, projectRoot):
        discard runShell(shellCommand(@["kill", "-KILL", $pid]))

proc stopAndReap(projectRoot: string) =
  ## Teardown for a case that may leave a live supervisor behind in EITHER
  ## direction of the fix under test. Writing the stop-request file is what
  ## the supervisor polls, so it shuts down services it did start; the reap
  ## then covers a supervisor that never got that far.
  when not defined(windows):
    let sessionDir = projectRoot / ".repro" / "dev-env" / "default" / "session"
    if dirExists(sessionDir):
      try:
        writeFile(sessionDir / "stop-request.json",
          "{\"source\":\"test-teardown\"}\n")
      except CatchableError:
        discard
      sleep(500)
    reapSession(projectRoot)

proc closedLoopbackPort(): int =
  ## A loopback port that is NOT listening: bound to learn its number, then
  ## closed. A real port, really closed -- so the "nothing answered there"
  ## cases below exercise a real connect failure rather than a stub.
  var probe = newSocket()
  probe.setSockOpt(OptReuseAddr, true)
  probe.bindAddr(Port(0), "127.0.0.1")
  result = int(probe.getLocalAddr()[1])
  probe.close()

type
  UpAnnouncement = object
    sessionId: string
    status: string
    httpBind: string

proc upAnnouncement(output: string): UpAnnouncement =
  ## The `repro up: session <id> <status> <bind>` line, parsed.
  const marker = "repro up: session "
  for line in output.splitLines():
    let pos = line.find(marker)
    if pos < 0:
      continue
    let fields = line[pos + marker.len .. ^1].strip().splitWhitespace()
    if fields.len >= 3:
      return UpAnnouncement(sessionId: fields[0], status: fields[1],
        httpBind: fields[2])
  UpAnnouncement()

proc liveStatusAt(httpBindValue: string): JsonNode =
  ## `/status` from whatever is listening at `httpBindValue`, or nil when
  ## NOTHING is. The point of the connect is that a string comparison
  ## between the printed address and the recorded one cannot tell a live
  ## bind from a closed one -- both are the same text.
  try:
    parseJson(httpRequest(httpBindValue, "/status"))
  except CatchableError:
    nil

type
  StatuslessPeer = object
    ## A real loopback HTTP server, in its own process, that answers every
    ## request with one fixed 200 + JSON body.
    process: Process
    httpBind: string

proc startStatuslessPeer(body: string): StatuslessPeer =
  ## Stand a real server on a real loopback port that answers 200 with
  ## ``body``.
  ##
  ## WHY A SEPARATE PROCESS AND NOT A FAKE: the thing under test is
  ## `waitForDevSessionReady`'s middle expiry arm, which is reached only
  ## when a *peer* at the published bind answers 2xx with JSON carrying no
  ## usable `status`. This module's own control API cannot produce that
  ## answer -- `/status` serves `session.json`, which `stateJson` always
  ## stamps a non-empty `status` into, or 404 -- so the arm is a guard
  ## against a peer that is NOT this control API: a port reused by
  ## something else, or a second implementation of `/status`. Staging that
  ## peer means standing up a different server; there is no version of this
  ## case that drives it through `repro up`. Everything else stays real --
  ## real socket, real connect, real HTTP, real `waitForDevSessionReady`,
  ## real session directory -- and nothing the production code does is
  ## replaced.
  let script =
    "import json, socket, sys\n" &
    "body = sys.argv[1].encode()\n" &
    "srv = socket.socket()\n" &
    "srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n" &
    "srv.bind(('127.0.0.1', 0))\n" &
    "srv.listen(8)\n" &
    "print(srv.getsockname()[1], flush=True)\n" &
    "while True:\n" &
    "    conn, _ = srv.accept()\n" &
    "    try:\n" &
    "        conn.recv(65536)\n" &
    "        conn.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Type: " &
      "application/json\\r\\nContent-Length: ' +\n" &
    "            str(len(body)).encode() + b'\\r\\nConnection: close" &
      "\\r\\n\\r\\n' + body)\n" &
    "    finally:\n" &
    "        conn.close()\n"
  result.process = startProcess("python3",
    args = @["-c", script, body],
    options = {poUsePath})
  let portLine = result.process.outputStream.readLine()
  result.httpBind = "http://127.0.0.1:" & portLine.strip()

proc stop(peer: StatuslessPeer) =
  try:
    if peer.process.running():
      peer.process.kill()
    discard peer.process.waitForExit()
  except CatchableError:
    discard
  peer.process.close()

proc requirePidGone(pid: int) =
  for _ in 0 ..< 100:
    if not pidAlive(pid):
      return
    sleep(50)
  raise newException(OSError, "supervised service pid still alive: " & $pid)

suite "e2e_repro_dev_sessions":
  when isIoMonitorSupported:
    test "e2e_repro_up_down_supervises_real_services":
      let c = prepareCase("repro-m8-up-down")
      defer: removeDir(c.tempRoot)

      let upOutput = requireRepro(c, @["up", c.projectRoot, "--http=127.0.0.1:0"])
      check upOutput.contains("repro up: session")
      # The derived wait is the SUM of the declared service readiness
      # timeouts plus the margin, not their maximum: this fixture declares
      # 5000 ms for `db` and 5000 ms for `api`, which the supervisor waits
      # for one after the other. 15000 here would mean `max`, 20000 means
      # `sum`, and 10000 would mean the hardcoded constant came back.
      check upOutput.contains("waiting up to 20000 ms (derived: 10000 ms of " &
        "declared service readiness timeouts + 10000 ms margin")
      let metadata = waitForStatus(sessionMetadataPath(c.projectRoot), "up")
      let httpBindValue = metadata["httpBind"].getStr()
      let status = statusJson(httpBindValue)
      check status["status"].getStr() == "up"
      check status["services"].len == 2
      check status["services"][0]["name"].getStr() == "db"
      check status["services"][0]["ready"].getBool()
      check status["services"][1]["name"].getStr() == "api"
      check status["services"][1]["ready"].getBool()
      check status["resources"].anyIt(it["path"].getStr().endsWith("state") and
        it["status"].getStr() == "ready")
      let pids = status["services"].mapIt(it["pid"].getInt())
      check pids.allIt(it > 0)
      check pids.allIt(pidAlive(it))

      let upEvents = sseEvents(httpBindValue, waitMs = 250)
      let upKinds = eventKinds(upEvents)
      check upKinds.kindIndex("resources.reconciled") >= 0
      check upKinds.kindIndex("session.up") >= 0
      check upKinds.kindIndex("resources.reconciled") <
        upKinds.kindIndex("session.up")

      let downOutput = requireRepro(c, @["down", c.projectRoot])
      check downOutput.contains("repro down: session")
      let down = waitForStatus(sessionMetadataPath(c.projectRoot), "down")
      check down["stopOrder"].mapIt(it.getStr()) == @["api", "db"]
      check down["services"].mapIt(it["pid"].getInt()) == pids
      check down["services"].allIt(it["status"].getStr() == "stopped")
      for pid in pids:
        requirePidGone(pid)
      let order = readFile(c.projectRoot / "state" / "order.log")
      check order.find("db-start") < order.find("api-start")
      check order.find("api-stop") < order.find("db-stop")

    test "e2e_repro_dev_watch_and_service_events":
      let c = prepareCase("repro-m8-dev-watch", dev = true)
      defer: removeDir(c.tempRoot)

      var devProcess = startProcess(c.reproBin,
        args = @[
          "dev", c.projectRoot, "--foreground", "--http=127.0.0.1:0",
          "--debounce-ms=100"
        ],
        workingDir = c.repoRoot,
        env = c.envFor(),
        options = {poUsePath, poStdErrToStdOut})
      defer:
        try:
          if devProcess.running():
            devProcess.terminate()
        except CatchableError:
          discard
        devProcess.close()

      let metadataPath = sessionMetadataPath(c.projectRoot)
      let up =
        try:
          waitForStatus(metadataPath, "up", timeoutMs = 120000)
        except CatchableError:
          try:
            if devProcess.running():
              devProcess.terminate()
              discard devProcess.waitForExit()
          except CatchableError:
            discard
          let output =
            if devProcess.outputStream != nil: devProcess.outputStream.readAll()
            else: ""
          checkpoint("dev process output before session became up:\n" & output)
          raise
      let httpBindValue = up["httpBind"].getStr()
      check statusJson(httpBindValue)["services"][0]["ready"].getBool()

      while not fileExists(c.projectRoot / "state" / "watch.log"):
        sleep(50)
      check readFile(c.projectRoot / "state" / "watch.log").contains("task:one")

      writeFile(c.projectRoot / "watch-source.txt", "two\n")
      var sawTwo = false
      for _ in 0 ..< 100:
        if fileExists(c.projectRoot / "state" / "watch.log") and
            readFile(c.projectRoot / "state" / "watch.log").contains("task:two"):
          sawTwo = true
          break
        sleep(50)
      check sawTwo

      let events = sseEvents(httpBindValue, waitMs = 750)
      let sseKinds = eventKinds(events)
      check "service.ready" in sseKinds
      check "watch.filesystem.changed" in sseKinds
      check "watch.cycle.started" in sseKinds
      check "watch.task.finished" in sseKinds
      check "watch.cycle.finished" in sseKinds
      check sseKinds.kindCount("watch.cycle.started") >= 2
      check sseKinds.kindCount("watch.task.finished") >= 2
      check statusJson(httpBindValue)["watch"]["cycles"].getInt() >= 2

      discard requireRepro(c, @["down", c.projectRoot])
      let output =
        if devProcess.outputStream != nil: devProcess.outputStream.readAll()
        else: ""
      let exitCode = devProcess.waitForExit()
      check exitCode == 0
      check output.contains("watch-task:one")
      check output.contains("watch-task:two")
      let terminalKinds = terminalEventKinds(output)
      for kind in ["service.ready", "watch.filesystem.changed",
          "watch.cycle.started", "watch.task.finished", "watch.cycle.finished"]:
        check kind in terminalKinds
        check kind in sseKinds
        check terminalKinds.kindCount(kind) == sseKinds.kindCount(kind)

    test "e2e_repro_up_waits_for_a_service_slower_than_ten_seconds":
      # THE HEADLINE GATE for
      # reprobuild-specs/issues/2026-10-04-repro-up-abandons-any-service-slower-than-ten-seconds.md.
      #
      # A service that declares 60000 ms and takes twelve seconds is a
      # healthy service by its own declaration, and the supervisor honours
      # that declaration. The parent used to wait a hardcoded 10000 ms and
      # then report `dev session metadata did not become queryable at
      # <port>` -- about a control API that was answering on that very
      # port -- with a non-zero exit, for a session that came up correctly.
      #
      # This is the ONE case here that spends real wall clock crossing the
      # old boundary, and it has to: the boundary was a wall-clock constant.
      let c = prepareCase("repro-m8-slow-ready", writeFixture =
        proc (dir: string) = writeReadinessFixture(dir, sleepSeconds = 12,
          readinessTimeoutMs = 60000))
      defer:
        reapSession(c.projectRoot)
        removeDir(c.tempRoot)

      let res = runRepro(c, @["up", c.projectRoot, "--http=127.0.0.1:0"])
      checkpoint("repro up output:\n" & res.output)
      check res.exitCode == 0
      check res.output.contains("repro up: session")
      check res.output.contains(" up http://")
      # The service really did take longer than the old ten-second
      # ceiling -- measured from the session's own event log, not from the
      # test's clock -- and `repro up` returned 0 anyway.
      let starting = eventTimes(c.projectRoot, "service.starting")
      let ready = eventTimes(c.projectRoot, "service.ready")
      check starting.len == 1
      check ready.len == 1
      let readinessMs = (ready[0] - starting[0]).inMilliseconds.int
      checkpoint("service took " & $readinessMs & " ms to become ready")
      check readinessMs > 11_000
      # ...and the budget it held itself to was derived from what the
      # service declared: 60000 ms declared + 10000 ms margin.
      check res.output.contains("waiting up to 70000 ms (derived: 60000 ms " &
        "of declared service readiness timeouts + 10000 ms margin")
      check not res.output.contains("did not become queryable")

      let metadata = waitForStatus(sessionMetadataPath(c.projectRoot), "up")
      check metadata["services"][0]["ready"].getBool()
      check metadata{"failure"}.getStr() == ""
      # Teardown, deliberately NOT asserted: `repro down` has its own
      # hardcoded ten-second wait -- the same defect class, out of this
      # change's scope -- and these cases are about `up`. The
      # `reapSession` in the defer is what guarantees no leak.
      discard runRepro(c, @["down", c.projectRoot])

    test "e2e_repro_up_ready_timeout_overrides_the_derived_wait":
      # `--ready-timeout` LARGER than the derived value. The flag has to
      # reach `waitForDevSessionReady` and replace the budget, not merely
      # parse: the announcement names the number the parent is holding
      # itself to and where it came from, so a flag that parsed and was
      # dropped would still print the derived 12000 ms here.
      let c = prepareCase("repro-m8-ready-timeout-high", writeFixture =
        proc (dir: string) = writeReadinessFixture(dir, sleepSeconds = 0,
          readinessTimeoutMs = 2000))
      defer:
        reapSession(c.projectRoot)
        removeDir(c.tempRoot)

      let res = runRepro(c, @["up", c.projectRoot, "--http=127.0.0.1:0",
        "--ready-timeout=90000"])
      checkpoint("repro up output:\n" & res.output)
      check res.exitCode == 0
      check res.output.contains("waiting up to 90000 ms (--ready-timeout; " &
        "the declared service readiness timeouts would derive 12000 ms)")
      check res.output.contains("repro up: session")
      # Teardown, deliberately NOT asserted: `repro down` has its own
      # hardcoded ten-second wait -- the same defect class, out of this
      # change's scope -- and these cases are about `up`. The
      # `reapSession` in the defer is what guarantees no leak.
      discard runRepro(c, @["down", c.projectRoot])

    test "e2e_repro_up_ready_timeout_below_the_declared_wait_is_the_users":
      # `--ready-timeout` SMALLER than what the service declares. It is
      # honoured -- the caller is describing their own patience, not making
      # a claim about the service -- and the diagnostic says so: the wait
      # that expired was theirs, and the declared timeouts would have
      # allowed 70000 ms. The exit code is the "still starting" code, not
      # the failure code, because the session is alive and comes up a
      # moment later -- which `repro down` then proves by stopping it.
      let c = prepareCase("repro-m8-ready-timeout-low", writeFixture =
        proc (dir: string) = writeReadinessFixture(dir, sleepSeconds = 3,
          readinessTimeoutMs = 60000))
      defer:
        reapSession(c.projectRoot)
        removeDir(c.tempRoot)

      let res = runRepro(c, @["up", c.projectRoot, "--http=127.0.0.1:0",
        "--ready-timeout=800"])
      checkpoint("repro up output:\n" & res.output)
      check res.exitCode == 75
      check res.output.contains("is still starting")
      check res.output.contains("that wait was 800 ms (--ready-timeout; " &
        "the declared service readiness timeouts would derive 70000 ms)")
      check res.output.contains("events.jsonl")
      check res.output.contains("the session was left running")
      check not res.output.contains("did not become queryable")
      # It gave up when the USER said, not when the service said: the
      # wait it reports is the 800 ms it was given, not the 70000 ms the
      # service's declaration would have allowed.
      checkpoint("reported wait: " & $reportedWaitMs(res.output) & " ms")
      check reportedWaitMs(res.output) >= 800
      check reportedWaitMs(res.output) < 5_000

      # The session was left running, as the message claims, and comes up
      # on its own.
      let metadata = waitForStatus(sessionMetadataPath(c.projectRoot), "up",
        timeoutMs = 120000)
      check metadata["services"][0]["ready"].getBool()
      # Teardown, deliberately NOT asserted: `repro down` has its own
      # hardcoded ten-second wait -- the same defect class, out of this
      # change's scope -- and these cases are about `up`. The
      # `reapSession` in the defer is what guarantees no leak.
      discard runRepro(c, @["down", c.projectRoot])

    test "e2e_repro_up_fails_fast_when_a_service_cannot_become_ready":
      # The opposite direction, and the regression this fix must not cause:
      # a service that genuinely never becomes ready still FAILS, still
      # exits non-zero, and fails on the supervisor's terminal event rather
      # than on the parent's clock -- so the bound is the service's own
      # declared 2000 ms, not the 12000 ms the parent was willing to wait.
      let c = prepareCase("repro-m8-never-ready", writeFixture =
        proc (dir: string) = writeReadinessFixture(dir, sleepSeconds = 0,
          readinessTimeoutMs = 2000, everReady = false))
      defer:
        reapSession(c.projectRoot)
        removeDir(c.tempRoot)

      let res = runRepro(c, @["up", c.projectRoot, "--http=127.0.0.1:0"])
      checkpoint("repro up output:\n" & res.output)
      check res.exitCode == 1
      check res.output.contains("dev session cannot start")
      check res.output.contains("service slow")
      check res.output.contains("events.jsonl")
      check not res.output.contains("did not become queryable")
      check not res.output.contains("is still starting")
      # Bounded by the DECLARED timeout plus startup overhead, and well
      # inside the 12000 ms budget the parent was willing to wait: the
      # failure arrived on the supervisor's terminal event, not on the
      # clock.
      check res.output.contains("of the 12000 ms allowed")
      checkpoint("reported wait: " & $reportedWaitMs(res.output) & " ms")
      check reportedWaitMs(res.output) >= 0
      check reportedWaitMs(res.output) < 11_000

      let failed = waitForStatus(sessionMetadataPath(c.projectRoot), "failed")
      check failed{"failure"}.getStr().contains("service slow")
      let kinds = readFile(sessionMetadataPath(c.projectRoot).parentDir /
        "events.jsonl").splitLines().filterIt(it.len > 0).mapIt(
        parseJson(it){"kind"}.getStr())
      check "service.failed" in kinds
      check "session.up" notin kinds

    test "e2e_repro_dev_session_flags_are_refused_when_they_cannot_act":
      # The unknown-flag refusal is not weakened by the new flag, and the
      # new flag is refused everywhere it could not take effect. Each of
      # these parses argv and raises before any dev-env work, so the case
      # costs nothing beyond process starts.
      let c = prepareCase("repro-m8-flag-refusals")
      defer: removeDir(c.tempRoot)

      let unknown = runRepro(c, @["up", c.projectRoot, "--nope"])
      check unknown.exitCode == 1
      check unknown.output.contains("unsupported up flag: --nope")

      let unknownDev = runRepro(c, @["dev", c.projectRoot, "--nope=1"])
      check unknownDev.exitCode == 1
      check unknownDev.output.contains("unsupported dev flag: --nope=1")

      # `down` does not wait for readiness, so accepting `--ready-timeout`
      # there would be a flag that parses and does nothing.
      let onDown = runRepro(c, @["down", c.projectRoot,
        "--ready-timeout=5000"])
      check onDown.exitCode == 1
      check onDown.output.contains(
        "unsupported down flag: --ready-timeout=5000")

      # Same rule for `--foreground`: a foreground session IS the
      # supervisor, so there is no parent wait to bound.
      let withForeground = runRepro(c, @["up", c.projectRoot, "--foreground",
        "--ready-timeout=5000"])
      check withForeground.exitCode == 1
      check withForeground.output.contains(
        "--ready-timeout has no effect with --foreground")

      let nonPositive = runRepro(c, @["up", c.projectRoot,
        "--ready-timeout=0"])
      check nonPositive.exitCode == 1
      check nonPositive.output.contains(
        "--ready-timeout must be a positive number of milliseconds")

    test "e2e_repro_up_after_down_reports_the_live_control_api":
      # B1. `up`, `down`, `up` in ONE directory. The second `up` used to
      # exit 0 while printing the FIRST session's control-API address, which
      # had closed when that session stopped: `http-ready.json` is never
      # invalidated, so the parent's phase-1 read and the new supervisor's
      # own `waitForReadyFile` both took the dead bind on their first check,
      # and the `session.json` fallback then supplied an `up` status to go
      # with it. Exit 0 is the contract's "a script may now use these
      # services" (`DevSessionStillStartingExitCode`), so this was the
      # loudest possible failure reported as the quietest success.
      #
      # The assertion that matters is the CONNECT. Comparing the printed
      # address against the recorded one cannot fail here -- they are the
      # same string, both wrong -- so this case opens a socket to the
      # address `repro up` printed and asks the thing that answers which
      # session it is serving.
      let c = prepareCase("repro-m8-up-down-up", writeFixture =
        proc (dir: string) = writeReadinessFixture(dir, sleepSeconds = 0,
          readinessTimeoutMs = 5000))
      defer:
        stopAndReap(c.projectRoot)
        removeDir(c.tempRoot)

      let first = runRepro(c, @["up", c.projectRoot, "--http=127.0.0.1:0"])
      checkpoint("first up:\n" & first.output)
      check first.exitCode == 0
      let firstUp = upAnnouncement(first.output)
      check firstUp.sessionId.len > 0
      let firstDown = runRepro(c, @["down", c.projectRoot])
      checkpoint("down:\n" & firstDown.output)
      check firstDown.exitCode == 0

      let second = runRepro(c, @["up", c.projectRoot, "--http=127.0.0.1:0"])
      checkpoint("second up:\n" & second.output)
      check second.exitCode == 0
      let secondUp = upAnnouncement(second.output)
      check secondUp.sessionId.len > 0
      check secondUp.status == "up"
      check secondUp.sessionId != firstUp.sessionId
      # The address printed beside `up` has to be the session's own live
      # control API.
      let live = liveStatusAt(secondUp.httpBind)
      checkpoint("printed bind: " & secondUp.httpBind)
      check not live.isNil
      if not live.isNil:
        check live{"status"}.getStr() == "up"
        check live{"sessionId"}.getStr() == secondUp.sessionId
      discard runRepro(c, @["down", c.projectRoot])

    test "e2e_repro_up_does_not_report_a_stale_sessions_identity":
      # B1, second scenario: a session directory left claiming `up` by a
      # session that is gone -- a supervisor killed, a host rebooted, a
      # `repro down` that never completed. `repro up` used to read that file
      # through its fallback, find `"status": "up"`, and exit 0 announcing
      # the DEAD session's id and port while the session it had actually
      # just launched came up elsewhere under a different id. The caller
      # then had a success, an id and an address, and all three described
      # something that no longer existed.
      #
      # Staged by writing the two leftover files by hand, which is what
      # makes this deterministic rather than a kill-at-the-right-moment
      # race: both files are exactly what the previous session would have
      # left, and the port named in them is a real loopback port that is
      # really closed.
      let c = prepareCase("repro-m8-stale-session-dir", writeFixture =
        proc (dir: string) = writeReadinessFixture(dir, sleepSeconds = 0,
          readinessTimeoutMs = 5000))
      defer:
        stopAndReap(c.projectRoot)
        removeDir(c.tempRoot)

      let sessionDir = c.projectRoot / ".repro" / "dev-env" / "default" /
        "session"
      createDir(sessionDir)
      const staleId = "dev-session-stale-000000-0"
      let staleBind = "http://127.0.0.1:" & $closedLoopbackPort()
      writeFile(sessionDir / "http-ready.json", $(%*{
        "schemaId": "reprobuild.dev-session.http.v1",
        "httpBind": staleBind,
        "pid": 0
      }))
      writeFile(sessionDir / "session.json", $(%*{
        "schemaId": "reprobuild.dev-session.v1",
        "sessionId": staleId,
        "failure": "",
        "mode": "up",
        "projectRoot": c.projectRoot,
        "httpBind": staleBind,
        "status": "up",
        "services": [],
        "resources": [],
        "startOrder": []
      }))

      let res = runRepro(c, @["up", c.projectRoot, "--http=127.0.0.1:0"])
      checkpoint("repro up output:\n" & res.output)
      check res.exitCode == 0
      let announced = upAnnouncement(res.output)
      checkpoint("announced: " & announced.sessionId & " at " &
        announced.httpBind)
      check announced.sessionId.len > 0
      check announced.sessionId != staleId
      check announced.httpBind != staleBind
      let live = liveStatusAt(announced.httpBind)
      check not live.isNil
      if not live.isNil:
        check live{"sessionId"}.getStr() == announced.sessionId
        check live{"sessionId"}.getStr() != staleId
      discard runRepro(c, @["down", c.projectRoot])

    test "e2e_dev_session_wait_names_a_control_api_that_never_answered":
      # B2. When the wait expires having never read a status, the
      # diagnostic must say THAT, and must not assert the two things the
      # shipped message asserted without checking: that the session
      # "reported `starting`" -- which was only the value the variable was
      # initialised to -- and that "its control API is answering at <addr>",
      # printed on a run where every poll to that address failed and nothing
      # was listening on it. Both clauses sent the reader to a port instead
      # of to the supervisor log, which is the same misdirection this whole
      # change exists to remove.
      #
      # Entry point narrowed, nothing faked: see the header note.
      let tempRoot = createTempDir("repro-m8-no-status", "")
      defer: removeDir(tempRoot)
      let outDir = tempRoot / ".repro" / "dev-env" / "default"
      let sessionDir = outDir / "session"
      createDir(sessionDir)
      let deadBind = "http://127.0.0.1:" & $closedLoopbackPort()
      writeFile(sessionDir / "http-ready.json", $(%*{
        "schemaId": "reprobuild.dev-session.http.v1",
        "httpBind": deadBind,
        "pid": 0
      }))
      let config = DevSessionSupervisorConfig(
        mode: dsmUp,
        projectRoot: tempRoot,
        outDir: outDir,
        artifactPath: tempRoot / "no-such-dev-env-artifact.json",
        httpBind: "127.0.0.1:0")
      let budget = DevSessionReadyBudget(timeoutMs: 600, explicit: true,
        derivedMs: 12000)

      var message = ""
      var raised = false
      try:
        discard waitForDevSessionReady(config, budget)
      except DevSessionStillStartingError as err:
        raised = true
        message = err.msg
      checkpoint("diagnostic:\n" & message)
      check raised
      check message.contains("is still starting")
      check message.contains("no status was ever read from the control API " &
        "at " & deadBind)
      check message.contains("every poll failed")
      # The two false clauses, in both their forms.
      check not message.contains("is answering at")
      check not message.contains("it reported `")
      # And it points at the one artifact that can say what happened.
      check message.contains("supervisor.log")

    test "e2e_dev_session_wait_reports_a_supervisor_that_published_no_bind":
      # B2, PHASE ONE -- the arm the readiness work added a new instance of
      # the same defect to. When the parent's budget expires with
      # `http-ready.json` still absent, the only thing observed is that
      # absence: no bind has been published, so no status has been read and
      # none could be. The message the readiness work shipped nevertheless
      # closed with "the session was left running", which is a claim about
      # a process nothing in that arm has a witness for, and it pointed at
      # `events.jsonl` -- a file the supervisor writes once it is
      # running -- instead of at `supervisor.log`, the one artifact that
      # can say why it is not.
      #
      # `startBackgroundSupervisor` does not make the claim safe either: on
      # POSIX it checks `execShellCmd` on a command whose last token is
      # `&`, so a shell that backgrounds a non-existent binary still exits
      # 0. The check proves a launch was attempted, not that anything is
      # alive.
      #
      # Entry point narrowed exactly as in the case below it, and for the
      # same reason: a supervisor that never publishes a bind inside a
      # bounded budget cannot be staged through the CLI without racing the
      # control-API child, which binds in milliseconds. The directory, the
      # absent file, the clock and the proc are all real.
      let tempRoot = createTempDir("repro-m8-no-bind", "")
      defer: removeDir(tempRoot)
      let outDir = tempRoot / ".repro" / "dev-env" / "default"
      let sessionDir = outDir / "session"
      createDir(sessionDir)
      # Deliberately NOT written: `http-ready.json`. That is the whole
      # staging.
      check not fileExists(sessionDir / "http-ready.json")
      let config = DevSessionSupervisorConfig(
        mode: dsmUp,
        projectRoot: tempRoot,
        outDir: outDir,
        artifactPath: tempRoot / "no-such-dev-env-artifact.json",
        httpBind: "127.0.0.1:0")
      # Explicit and well under `DevSessionControlApiTimeoutMs`, so the
      # budget is what expires: a budget longer than that constant would
      # raise the "cannot start" IOError from the other side of this `if`
      # instead, which is a different outcome with a different exit code.
      let budget = DevSessionReadyBudget(timeoutMs: 600, explicit: true,
        derivedMs: 12000)

      var message = ""
      var raised = false
      try:
        discard waitForDevSessionReady(config, budget)
      except DevSessionStillStartingError as err:
        raised = true
        message = err.msg
      checkpoint("diagnostic:\n" & message)
      check raised
      check message.contains("is still starting")
      # What it DID observe, said as an observation.
      check message.contains("its control API had not published")
      check message.contains("http-ready.json")
      check message.contains("no session status")
      check message.contains("there was no address to read one from")
      # The claim it must NOT make: that something is running.
      check not message.contains("the session was left running")
      check message.contains("this command stopped nothing")
      # And the artifact it must point at, for a supervisor that has not
      # reached the point of writing an event log.
      check message.contains("supervisor.log")
      # The budget's provenance still travels with it.
      check message.contains("that wait was 600 ms (--ready-timeout")

    test "e2e_dev_session_wait_reports_a_peer_that_publishes_no_status":
      # COVERAGE for the middle expiry arm, which this change did not alter
      # and which no case reached before. It is kept as a DEFENSIVE GUARD
      # rather than made reachable through the CLI, because this module's
      # `/status` cannot produce the answer it handles: the handler serves
      # `session.json` verbatim or 404, and every `session.json` comes from
      # `stateJson`, which stamps a non-empty `status` unconditionally.
      #
      # So this case does not change colour across the change -- it passes
      # in both directions, and that is stated rather than hidden. What it
      # buys is that the guard stops being indistinguishable from dead
      # code: delete the arm and this reddens, because the third arm's text
      # ("every poll failed") is false on a run where a poll succeeded.
      let tempRoot = createTempDir("repro-m8-no-status-key", "")
      defer: removeDir(tempRoot)
      let peer = startStatuslessPeer(
        "{\"sessionId\":\"dev-session-peer-000\",\"note\":\"no status key\"}")
      defer: peer.stop()
      let outDir = tempRoot / ".repro" / "dev-env" / "default"
      let sessionDir = outDir / "session"
      createDir(sessionDir)
      writeFile(sessionDir / "http-ready.json", $(%*{
        "schemaId": "reprobuild.dev-session.http.v1",
        "httpBind": peer.httpBind,
        "pid": 0
      }))
      # The peer really answers, and really answers without a `status`:
      # asserted here as the POSITIVE CONTROL, so a case that reached the
      # third arm because the server was dead could not pass by accident.
      let probe = statusJson(peer.httpBind)
      check probe{"sessionId"}.getStr() == "dev-session-peer-000"
      check probe{"status"}.getStr() == ""

      let config = DevSessionSupervisorConfig(
        mode: dsmUp,
        projectRoot: tempRoot,
        outDir: outDir,
        artifactPath: tempRoot / "no-such-dev-env-artifact.json",
        httpBind: "127.0.0.1:0")
      let budget = DevSessionReadyBudget(timeoutMs: 600, explicit: true,
        derivedMs: 12000)

      var message = ""
      var raised = false
      try:
        discard waitForDevSessionReady(config, budget)
      except DevSessionStillStartingError as err:
        raised = true
        message = err.msg
      checkpoint("diagnostic:\n" & message)
      check raised
      check message.contains("is still starting")
      check message.contains(
        "its control API answered but never published a `status`")
      check message.contains("it has published no `status` for the session")
      check message.contains(peer.httpBind)
      # The two statements that would be FALSE here, which is what makes
      # this arm's existence load-bearing rather than decorative.
      check not message.contains("every poll failed")
      check not message.contains("it reported `")

    test "e2e_repro_down_waits_for_the_stop_grace_its_services_imply":
      # THE HEADLINE GATE for `runDownCommand`'s own hardcoded ten seconds --
      # the start side's defect, one command over. `stopServices` stops
      # services ONE AT A TIME, in reverse, and allows each one
      # `DevSessionServiceStopGraceMs` (3000) between `terminate()` and
      # `kill()`. Four services that ignore SIGTERM therefore cost the
      # supervisor about twelve seconds of work it is entitled to, and
      # `repro down` used to abandon that at 10000 ms and report a timeout
      # for a session that stops correctly.
      #
      # Four, not two, because the number has to cross the old boundary:
      # the boundary was a wall-clock constant, so this case spends real
      # wall clock crossing it, exactly as
      # `e2e_repro_up_waits_for_a_service_slower_than_ten_seconds` does on
      # the start side.
      let c = prepareCase("repro-m8-stubborn-stop", writeFixture =
        proc (dir: string) = writeStubbornStopFixture(dir, services = 4))
      defer:
        reapSession(c.projectRoot)
        removeDir(c.tempRoot)

      let up = runRepro(c, @["up", c.projectRoot, "--http=127.0.0.1:0"])
      checkpoint("repro up output:\n" & up.output)
      check up.exitCode == 0
      let metadata = waitForStatus(sessionMetadataPath(c.projectRoot), "up")
      check metadata["services"].len == 4
      let pids = metadata["services"].mapIt(it["pid"].getInt())
      check pids.allIt(it > 0)

      let down = runRepro(c, @["down", c.projectRoot])
      checkpoint("repro down output:\n" & down.output)
      check down.exitCode == 0
      check down.output.contains("repro down: session")
      # The wait it held itself to is DERIVED from the services the session
      # says it is running, and the announcement names the derivation. 13000
      # here would mean one service; 10000 would mean the hardcoded constant
      # came back.
      check down.output.contains("waiting up to 22000 ms (derived: 4 live " &
        "service(s) x 3000 ms stop grace + 10000 ms margin")
      check not down.output.contains("did not stop")

      let stopped = waitForStatus(sessionMetadataPath(c.projectRoot), "down")
      check stopped["stopOrder"].mapIt(it.getStr()) ==
        @["svc3", "svc2", "svc1", "svc0"]
      check stopped["services"].allIt(it["status"].getStr() == "stopped")
      for pid in pids:
        requirePidGone(pid)
      # The supervisor really did spend longer than the old ten-second
      # ceiling stopping -- measured from the session's own event log, not
      # from this test's clock -- and `repro down` returned 0 anyway.
      let stopping = eventTimes(c.projectRoot, "session.stopping")
      let downEvents = eventTimes(c.projectRoot, "session.down")
      check stopping.len == 1
      check downEvents.len == 1
      let stopMs = (downEvents[0] - stopping[0]).inMilliseconds.int
      checkpoint("supervisor spent " & $stopMs & " ms stopping")
      check stopMs > 11_000

    test "e2e_repro_down_diagnostic_says_what_it_observed":
      # The other half of the same defect: when the wait DOES expire, the
      # message has to say what was observed. The text this replaces was
      # "timed out waiting for dev session to stop: <path>" -- it named the
      # file and nothing else, so a reader could not tell a session still
      # working through its services from one that never heard the stop
      # request, could not see how long the wait had been, where that
      # length came from, or which artifact to open.
      #
      # Staged by hand, which is what makes it deterministic rather than a
      # kill-at-the-right-moment race: a session directory left claiming
      # `up` with a bind on a real, really closed loopback port. `--force`
      # is the documented path for a control API that does not answer, so
      # the stop request goes to the file, and no supervisor exists to act
      # on it -- which is precisely a stop that is never completed.
      let c = prepareCase("repro-m8-down-expired", writeFixture =
        proc (dir: string) = writeReadinessFixture(dir, sleepSeconds = 0,
          readinessTimeoutMs = 5000))
      defer: removeDir(c.tempRoot)

      let sessionDir = c.projectRoot / ".repro" / "dev-env" / "default" /
        "session"
      createDir(sessionDir)
      let deadBind = "http://127.0.0.1:" & $closedLoopbackPort()
      writeFile(sessionDir / "session.json", $(%*{
        "schemaId": "reprobuild.dev-session.v1",
        "sessionId": "dev-session-never-stops-0",
        "failure": "",
        "mode": "up",
        "projectRoot": c.projectRoot,
        "httpBind": deadBind,
        "status": "up",
        "services": [
          {"name": "a", "pid": 0, "status": "ready"},
          {"name": "b", "pid": 0, "status": "ready"}
        ],
        "resources": [],
        "startOrder": ["a", "b"]
      }))

      let res = runRepro(c, @["down", c.projectRoot, "--force",
        "--stop-timeout=700"])
      checkpoint("repro down output:\n" & res.output)
      check res.exitCode == 1
      # Named, and named as a session that did not stop rather than as a
      # bare timeout against a path.
      check res.output.contains("dev session dev-session-never-stops-0 " &
        "did not stop")
      # What it OBSERVED: the status the file was actually reporting.
      check res.output.contains("it still reports `up`, not `down`")
      # How long, and whose wait it was -- the explicit flag is attributed,
      # and what the services would have derived is named beside it so a
      # short wait is not mistaken for a slow stack.
      check res.output.contains("that wait was 700 ms (--stop-timeout; the " &
        "session's live services would derive 16000 ms)")
      # The distinction the old message could not draw.
      check res.output.contains("the supervisor had not begun stopping")
      check res.output.contains("never published `stopping`")
      # And both artifacts, by path.
      check res.output.contains("events.jsonl")
      check res.output.contains("supervisor.log")
      # The text this replaces, asserted ABSENT separately. The assertions
      # above all mention `--stop-timeout`, so on a tree without the flag
      # they redden because the flag is refused rather than because the
      # message is wrong; this one reddens on the message alone, which is
      # what makes "restore the old text" a mutation this case catches.
      check not res.output.contains(
        "timed out waiting for dev session to stop")
      # The stop request really was written -- the `--force` arm is the one
      # under test here, so a run where nothing was requested would be
      # testing nothing.
      check fileExists(sessionDir / "stop.request.json")

      # SECOND SCENARIO, same surface: metadata with NO `services` key at
      # all. It is in this case rather than its own because it asserts the
      # same diagnostic; what it adds is the nil path through the
      # derivation. `{}` hands back a nil `JsonNode` for a missing key and
      # `kind` is a plain field on a ref, so the obvious spelling of that
      # derivation SEGVs here -- which is a crash, not a diagnostic, and
      # `repro down` would have no way to report anything at all. The
      # assertion that matters is therefore the EXIT CODE: 1, the refusal,
      # not 139.
      removeFile(sessionDir / "stop.request.json")
      writeFile(sessionDir / "session.json", $(%*{
        "schemaId": "reprobuild.dev-session.v1",
        "sessionId": "dev-session-no-services-0",
        "mode": "up",
        "projectRoot": c.projectRoot,
        "httpBind": deadBind,
        "status": "up"
      }))
      let bare = runRepro(c, @["down", c.projectRoot, "--force"])
      checkpoint("repro down (no services key) output:\n" & bare.output)
      check bare.exitCode == 1
      check bare.output.contains("dev session dev-session-no-services-0 " &
        "did not stop")
      # With no services to stop, the derivation is the bare margin -- the
      # ten seconds this wait had before it derived anything.
      check bare.output.contains("waiting up to 10000 ms (derived: 0 live " &
        "service(s) x 3000 ms stop grace + 10000 ms margin")
      check not bare.output.contains(
        "timed out waiting for dev session to stop")

    test "e2e_repro_down_refuses_a_stop_timeout_it_cannot_honour":
      # `--stop-timeout` is accepted exactly where there is a stop to
      # bound, and refused everywhere else, which is the rule
      # `--ready-timeout` already follows in the other direction. A flag
      # that parses and does nothing is the failure mode this campaign
      # keeps finding.
      let c = prepareCase("repro-m8-stop-timeout-refusals")
      defer: removeDir(c.tempRoot)

      let onUp = runRepro(c, @["up", c.projectRoot, "--stop-timeout=5000"])
      check onUp.exitCode == 1
      check onUp.output.contains("unsupported up flag: --stop-timeout=5000")

      let onDev = runRepro(c, @["dev", c.projectRoot, "--stop-timeout=5000"])
      check onDev.exitCode == 1
      check onDev.output.contains("unsupported dev flag: --stop-timeout=5000")

      let nonPositive = runRepro(c, @["down", c.projectRoot,
        "--stop-timeout=0"])
      check nonPositive.exitCode == 1
      check nonPositive.output.contains(
        "--stop-timeout must be a positive number of milliseconds")

    test "e2e_reap_session_only_kills_pids_that_name_the_session":
      # The third item: `reapSession` SIGKILLs pids read out of
      # `session.json`, and a pid in a file is a historical record, not a
      # handle -- the process may have exited and the number been reissued
      # to something else on this host. Two REAL `sh` processes stand in for
      # the two cases, one started inside the session's project root and one
      # outside it; nothing here is a fake, including the kill.
      #
      # The insider is the POSITIVE CONTROL: without it, a `reapSession`
      # that killed nothing at all would pass this case, and the guard would
      # be indistinguishable from a reap that does not work.
      when not defined(windows):
        let tempRoot = createTempDir("repro-m8-reap-identity", "")
        let projectRoot = tempRoot / "project"
        createDir(projectRoot)
        let sessionDir = projectRoot / ".repro" / "dev-env" / "default" /
          "session"
        createDir(sessionDir)

        const spin = "while :; do sleep 1; done"
        let outsider = startProcess("sh", args = @["-c", spin],
          workingDir = tempRoot, options = {poUsePath})
        let insider = startProcess("sh", args = @["-c", spin],
          workingDir = projectRoot, options = {poUsePath})
        defer:
          for process in [outsider, insider]:
            try:
              if process.running():
                process.kill()
              discard process.waitForExit()
            except CatchableError:
              discard
            process.close()
          removeDir(tempRoot)

        writeFile(sessionDir / "session.json", $(%*{
          "schemaId": "reprobuild.dev-session.v1",
          "sessionId": "dev-session-reap-identity",
          "status": "up",
          "supervisorPid": outsider.processID,
          "services": [{"name": "spin", "pid": insider.processID}]
        }))
        check outsider.running()
        check insider.running()

        reapSession(projectRoot)

        proc waitGone(process: Process): bool =
          for _ in 0 ..< 100:
            if not process.running():
              return true
            sleep(50)
          false

        # The positive control runs on EVERY platform: a `reapSession` that
        # killed nothing at all would satisfy the negative control below
        # for entirely the wrong reason.
        check waitGone(insider)
        when defined(linux):
          # The guard itself. `belongsToSession` can only read argv and cwd
          # where /proc is, so this is the platform where the guard exists
          # and the only one where its effect can be asserted; see that
          # proc for why the others keep the unguarded reap.
          check outsider.running()
