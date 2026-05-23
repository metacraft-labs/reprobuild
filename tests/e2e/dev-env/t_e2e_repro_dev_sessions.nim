import std/[json, os, osproc, sequtils, strtabs, streams, strutils, tempfiles,
    unittest]

proc q(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc shellCommand(args: openArray[string]): string =
  args.mapIt(q(it)).join(" ")

proc requireSuccess(command: string; cwd = getCurrentDir()): string =
  let res = execCmdEx(command, workingDir = cwd)
  if res.exitCode != 0:
    raise newException(OSError,
      "command failed with exit " & $res.exitCode & ": " & command &
        "\n" & res.output)
  res.output

proc compileNim(repoRoot, sourcePath, outputPath, cacheName: string;
                appLib = false) =
  var args = @[
    "nim", "c", "--threads:on", "--verbosity:0", "--hints:off",
    "--nimcache:" & repoRoot / "build" / "nimcache" / cacheName,
    "--out:" & outputPath
  ]
  if appLib:
    args.insert("--app:lib", 2)
  args.add(sourcePath)
  discard requireSuccess(shellCommand(args), repoRoot)

when defined(linux) or defined(macosx):
  proc prepareMonitorTools(repoRoot, tempRoot: string):
      tuple[fsSnoop: string; shim: string] =
    let binDir = tempRoot / "bin"
    let libDir = tempRoot / "lib"
    createDir(binDir)
    createDir(libDir)
    result.fsSnoop = binDir / "repro-fs-snoop"
    result.shim =
      when defined(linux):
        libDir / "librepro_monitor_shim.so"
      else:
        libDir / "librepro_monitor_shim.dylib"
    let shimSource =
      when defined(linux):
        repoRoot / "libs" / "repro_monitor_shim" / "src" /
          "repro_monitor_shim" / "linux_preload.nim"
      else:
        repoRoot / "libs" / "repro_monitor_shim" / "src" /
          "repro_monitor_shim" / "macos_interpose.nim"
    compileNim(repoRoot, shimSource, result.shim, "m8-dev-session-monitor-shim",
      appLib = true)
    compileNim(repoRoot,
      repoRoot / "apps" / "repro-fs-snoop" / "repro_fs_snoop.nim",
      result.fsSnoop, "m8-dev-session-fs-snoop")

proc compileRepro(repoRoot, tempRoot: string): string =
  result = tempRoot / "bin" / addFileExt("repro", ExeExt)
  createDir(parentDir(result))
  compileNim(repoRoot, repoRoot / "apps" / "repro" / "repro.nim",
    result, "m8-dev-session-repro")

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
    fsSnoop: string
    shim: string

proc prepareCase(prefix: string; dev = false): M8Case =
  result.repoRoot = getCurrentDir()
  result.tempRoot = createTempDir(prefix, "")
  result.projectRoot = result.tempRoot / "project"
  if dev:
    writeDevFixture(result.projectRoot)
  else:
    writeUpDownFixture(result.projectRoot)
  result.reproBin = compileRepro(result.repoRoot, result.tempRoot)
  when defined(linux) or defined(macosx):
    let monitor = prepareMonitorTools(result.repoRoot, result.tempRoot)
    result.fsSnoop = monitor.fsSnoop
    result.shim = monitor.shim
  else:
    raise newException(OSError,
      "M8 dev session tests require a filesystem monitor backend")

proc envFor(c: M8Case): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["REPROBUILD_SOURCE_ROOT"] = c.repoRoot
  result["REPRO_MONITOR_SHIM_LIB"] = c.shim
  result["REPRO_FS_SNOOP"] = c.fsSnoop

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
  while waited <= timeoutMs:
    if fileExists(path):
      let node = parseFile(path)
      if node{"status"}.getStr() == status:
        return node
    sleep(50)
    waited.inc(50)
  raise newException(IOError, "timed out waiting for session status " & status)

proc httpRequest(httpBindValue, path: string; httpMethod = "GET"): string =
  let command = "python3 - " & q(httpBindValue) & " " & q(path) & " " &
    q(httpMethod) & " <<'PY'\n" &
    "import http.client, sys, urllib.parse\n" &
    "u=urllib.parse.urlparse(sys.argv[1])\n" &
    "conn=http.client.HTTPConnection(u.hostname, u.port, timeout=5)\n" &
    "conn.request(sys.argv[3], sys.argv[2])\n" &
    "resp=conn.getresponse()\n" &
    "body=resp.read().decode()\n" &
    "print(body, end='')\n" &
    "sys.exit(0 if 200 <= resp.status < 300 else 1)\n" &
    "PY"
  requireSuccess(command)

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
    execCmdEx("kill -0 " & $pid).exitCode == 0

proc requirePidGone(pid: int) =
  for _ in 0 ..< 100:
    if not pidAlive(pid):
      return
    sleep(50)
  raise newException(OSError, "supervised service pid still alive: " & $pid)

suite "e2e_repro_dev_sessions":
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
    let up = waitForStatus(metadataPath, "up")
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
