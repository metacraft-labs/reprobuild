import std/[json, os, osproc, sequtils, strtabs, streams, strutils, tempfiles,
    unittest]

import repro_test_support

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
                 dependsOn: seq[string] = @[]): string =
  var root = %*{
    "schemaId": "reprobuild.dev-session.service.v1",
    "command": command,
    "cwd": ".",
    "readiness": {
      "kind": "fileExists",
      "path": readinessPath,
      "timeoutMs": 5000
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

proc prepareCase(prefix: string; dev = false): M8Case =
  result.repoRoot = getCurrentDir()
  result.tempRoot = createTempDir(prefix, "")
  result.projectRoot = result.tempRoot / "project"
  if dev:
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

      # THE SUPERVISOR'S OUTPUT GOES TO A FILE, NOT A PIPE THIS TEST READS TO
      # EOF. ``repro dev`` spawns ``runquotad`` while it prepares the
      # environment, and a child started by ``osproc.startProcess`` keeps the
      # original pipe descriptor open beside its dup'd stdout. When the test
      # terminated a ``repro dev`` that had not come up, that ``runquotad``
      # was orphaned still holding the write end, so ``readAll`` never saw
      # EOF and the case sat idle until the runner killed it at 1800s. A file
      # is read to its current end and cannot wedge the case.
      let devLog = c.tempRoot / "repro-dev.log"
      let devArgs = @[
        "dev", c.projectRoot, "--foreground", "--http=127.0.0.1:0",
        "--debounce-ms=100"
      ]
      var devProcess =
        when defined(windows):
          startProcess("cmd.exe",
            args = @["/c", quoteShellCommand(@[c.reproBin] & devArgs) &
              " > " & quoteShell(devLog) & " 2>&1"],
            workingDir = c.repoRoot,
            env = c.envFor(),
            options = {poUsePath, poParentStreams})
        else:
          startProcess("/bin/sh",
            args = @["-c", "exec \"$0\" \"$@\" > " & q(devLog) & " 2>&1",
              c.reproBin] & devArgs,
            workingDir = c.repoRoot,
            env = c.envFor(),
            options = {poParentStreams})
      proc devOutput(): string =
        if fileExists(devLog): readFile(devLog) else: ""
      defer:
        try:
          if devProcess.running():
            devProcess.terminate()
            discard devProcess.waitForExit()
        except CatchableError:
          discard
        devProcess.close()

      # Up is reached after a COLD provider compile of the fixture (a fresh
      # temp project every run): measured at 173.7s on a loaded host, past the
      # 120s this wait used to allow, while the supervisor was compiling and
      # making progress. So the wait follows the supervisor: it ends when the
      # session is up, fails at once if the supervisor exits, and keeps a cap
      # only as the backstop for a supervisor that is alive and stuck.
      let metadataPath = sessionMetadataPath(c.projectRoot)
      var up: JsonNode = nil
      var waitedMs = 0
      const UpCapMs = 900_000
      while up.isNil:
        if not devProcess.running():
          checkpoint("dev process exited before the session came up:\n" &
            devOutput())
          raise newException(IOError,
            "repro dev exited before session status up")
        if fileExists(metadataPath):
          try:
            let node = parseJson(readFile(metadataPath))
            if node{"status"}.getStr() == "up":
              up = node
              break
          except CatchableError:
            discard # mid-rewrite; read it again on the next poll
        if waitedMs >= UpCapMs:
          checkpoint("dev process output before session became up:\n" &
            devOutput())
          # The original diagnostics, from one last bounded wait.
          up = waitForStatus(metadataPath, "up", timeoutMs = 100)
        sleep(100)
        waitedMs.inc(100)
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
      let exitCode = devProcess.waitForExit()
      let output = devOutput()
      check exitCode == 0
      check output.contains("watch-task:one")
      check output.contains("watch-task:two")
      let terminalKinds = terminalEventKinds(output)
      for kind in ["service.ready", "watch.filesystem.changed",
          "watch.cycle.started", "watch.task.finished", "watch.cycle.finished"]:
        check kind in terminalKinds
        check kind in sseKinds
        check terminalKinds.kindCount(kind) == sseKinds.kindCount(kind)
