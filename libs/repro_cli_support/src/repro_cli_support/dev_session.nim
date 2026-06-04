import std/[json, net, options, os, osproc, sequtils, strtabs, strutils, times]

import cbor
import repro_core
import repro_dev_env_activation
import repro_dev_env_artifacts
import repro_dev_env_engine
import repro_provider_runtime
import repro_cli_support/watch

type
  DevSessionMode* = enum
    dsmUp
    dsmDev

  DevSessionSupervisorConfig* = object
    mode*: DevSessionMode
    foreground*: bool
    projectRoot*: string
    modulePath*: string
    outDir*: string
    workDir*: string
    publicCliPath*: string
    monitorCliPath*: string
    monitorShimLibPath*: string
    artifactPath*: string
    activity*: string
    lockSliceId*: string
    developOverridesPath*: string
    httpBind*: string
    debounceMs*: int

  DevSessionHttpConfig* = object
    sessionDir*: string
    host*: string
    port*: int

  ServiceSpec = object
    name: string
    command: seq[string]
    cwd: string
    dependsOn: seq[string]
    readinessKind: string
    readinessPath: string
    readinessUrl: string
    readinessTimeoutMs: int
    resources: seq[tuple[kind, path: string]]

  ServiceRuntime = object
    spec: ServiceSpec
    process: Process
    pid: int
    status: string
    ready: bool

  SessionState = object
    schemaId: string
    sessionId: string
    mode: DevSessionMode
    projectRoot: string
    artifactPath: string
    activity: string
    sessionDir: string
    httpBind: string
    status: string
    terminalEvents: bool
    resources: seq[tuple[kind, path, status: string]]
    services: seq[ServiceRuntime]
    startOrder: seq[string]
    stopOrder: seq[string]
    watchCycles: int
    lastWatchPath: string

const
  SessionSchemaId = "reprobuild.dev-session.v1"
  EventSchemaId = "reprobuild.dev-session.event.v1"
  HttpReadyFile = "http-ready.json"
  MetadataFile = "session.json"
  EventLogFile = "events.jsonl"
  StopRequestFile* = "stop.request.json"

proc sessionDir*(outDir: string): string =
  outDir / "session"

proc sessionMetadataPath*(outDir: string): string =
  outDir.sessionDir / MetadataFile

proc q(value: string): string =
  quoteShell(value)

proc shellCommand(args: openArray[string]): string =
  args.mapIt(q(it)).join(" ")

proc writeJsonFile(path: string; node: JsonNode) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), pretty(node) & "\n")

proc readJsonFileResilient*(path: string): JsonNode =
  # `parseFile` lifts the race that exists between a concurrent
  # `writeFile` (open(O_TRUNC) → write → close) on the supervisor side
  # and our `parseFile` on the reader side: the open(O_TRUNC) leaves a
  # zero-byte file visible to us for a few hundred microseconds and
  # parseJson raises `session.json(1, 0) Error: { expected`. The
  # supervisor never leaves session.json empty for more than a single
  # write() — retrying for up to ~250 ms is enough to step past the
  # truncate window on macOS APFS / Linux page cache without papering
  # over a real malformed-file bug (we re-raise after the retry budget
  # is exhausted so corruption still surfaces).
  var lastErr: ref CatchableError = nil
  for attempt in 0 ..< 25:
    try:
      return parseFile(extendedPath(path))
    except JsonParsingError as err:
      lastErr = err
    except IOError as err:
      lastErr = err
    sleep(10)
  raise lastErr

proc readJsonFile(path: string): JsonNode =
  parseFile(extendedPath(path))

proc nowIso(): string =
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")

proc modeName*(mode: DevSessionMode): string =
  case mode
  of dsmUp: "up"
  of dsmDev: "dev"

proc parseHttpBind*(value: string): tuple[host: string; port: int] =
  var raw = value
  if raw.len == 0:
    raw = "127.0.0.1:0"
  if raw.startsWith("http://"):
    raw = raw["http://".len .. ^1]
  let colon = raw.rfind(':')
  if colon < 0:
    return (host: raw, port: 0)
  let host = raw[0 ..< colon]
  let portText = raw[colon + 1 .. ^1]
  (host: if host.len > 0: host else: "127.0.0.1",
    port: if portText.len > 0: parseInt(portText) else: 0)

proc httpUrl(host: string; port: int): string =
  "http://" & host & ":" & $port

proc eventLogPath(state: SessionState): string =
  state.sessionDir / EventLogFile

proc stopRequestPath(state: SessionState): string =
  state.sessionDir / StopRequestFile

proc metadataPath(state: SessionState): string =
  state.sessionDir / MetadataFile

proc serviceRuntimeJson(service: ServiceRuntime): JsonNode =
  %*{
    "name": service.spec.name,
    "pid": service.pid,
    "status": service.status,
    "ready": service.ready,
    "dependsOn": service.spec.dependsOn,
    "command": service.spec.command
  }

proc resourcesJson(state: SessionState): JsonNode =
  result = newJArray()
  for resource in state.resources:
    result.add(%*{
      "kind": resource.kind,
      "path": resource.path,
      "status": resource.status
    })

proc servicesJson(state: SessionState): JsonNode =
  result = newJArray()
  for service in state.services:
    result.add(service.serviceRuntimeJson())

proc stateJson(state: SessionState): JsonNode =
  %*{
    "schemaId": state.schemaId,
    "sessionId": state.sessionId,
    "mode": state.mode.modeName,
    "projectRoot": state.projectRoot,
    "artifactPath": state.artifactPath,
    "activity": state.activity,
    "sessionDir": state.sessionDir,
    "metadataPath": state.metadataPath,
    "httpBind": state.httpBind,
    "status": state.status,
    "supervisorPid": getCurrentProcessId(),
    "resources": state.resourcesJson(),
    "services": state.servicesJson(),
    "startOrder": state.startOrder,
    "stopOrder": state.stopOrder,
    "watch": {
      "enabled": state.mode == dsmDev,
      "cycles": state.watchCycles,
      "lastPath": state.lastWatchPath
    }
  }

proc writeState(state: SessionState) =
  writeJsonFile(state.metadataPath, state.stateJson())

proc emitEvent(state: SessionState; kind: string; service = "";
               watchPath = ""; detail = ""; cycle = 0;
               extra: JsonNode = nil) =
  var node = %*{
    "schemaId": EventSchemaId,
    "time": nowIso(),
    "sessionId": state.sessionId,
    "kind": kind,
    "service": service,
    "watchPath": watchPath,
    "detail": detail,
    "cycle": cycle
  }
  if not extra.isNil:
    node["extra"] = extra
  createDir(extendedPath(state.sessionDir))
  let line = $node & "\n"
  let path = state.eventLogPath
  if fileExists(extendedPath(path)):
    writeFile(extendedPath(path), readFile(extendedPath(path)) & line)
  else:
    writeFile(extendedPath(path), line)
  if state.terminalEvents:
    var terminal = "repro dev-session event=" & kind
    if service.len > 0:
      terminal.add(" service=" & service)
    if watchPath.len > 0:
      terminal.add(" path=" & watchPath)
    if cycle > 0:
      terminal.add(" cycle=" & $cycle)
    if detail.len > 0:
      terminal.add(" detail=" & detail)
    stdout.writeLine(terminal)
    flushFile(stdout)

proc metadataText(service: DevEnvServiceSummary): string =
  case service.metadata.kind
  of dvText:
    service.metadata.textValue
  else:
    toJson(service.metadata)

proc stringArray(node: JsonNode): seq[string] =
  if node.isNil:
    return @[]
  case node.kind
  of JString:
    return @[node.getStr()]
  of JArray:
    for item in node:
      result.add(item.getStr())
  else:
    return @[]

proc serviceSpecFromSummary(projectRoot: string;
                            service: DevEnvServiceSummary): ServiceSpec =
  result.name = service.name
  result.readinessKind = "none"
  result.readinessTimeoutMs = 5000
  let text = service.metadataText.strip()
  if text.len == 0:
    raise newException(ValueError,
      "service " & service.name & " has empty supervisor metadata")
  let metadata = parseJson(text)
  result.command = metadata{"command"}.stringArray()
  if result.command.len == 0:
    raise newException(ValueError,
      "service " & service.name & " metadata must contain command")
  result.cwd = metadata{"cwd"}.getStr(projectRoot)
  if result.cwd.len == 0:
    result.cwd = projectRoot
  elif not result.cwd.isAbsolute:
    result.cwd = projectRoot / result.cwd
  result.dependsOn = metadata{"dependsOn"}.stringArray()
  if metadata.hasKey("readiness") and metadata["readiness"].kind == JObject:
    let readiness = metadata["readiness"]
    result.readinessKind = readiness{"kind"}.getStr("none")
    result.readinessPath = readiness{"path"}.getStr("")
    if result.readinessPath.len > 0 and not result.readinessPath.isAbsolute:
      result.readinessPath = projectRoot / result.readinessPath
    result.readinessUrl = readiness{"url"}.getStr("")
    result.readinessTimeoutMs = readiness{"timeoutMs"}.getInt(5000)
  if metadata.hasKey("resources") and metadata["resources"].kind == JArray:
    for item in metadata["resources"]:
      if item.kind != JObject:
        continue
      var path = item{"path"}.getStr("")
      if path.len > 0 and not path.isAbsolute:
        path = projectRoot / path
      result.resources.add((kind: item{"kind"}.getStr("directory"),
        path: path))

proc serviceIndex(services: openArray[ServiceSpec]; name: string): int =
  for i, service in services:
    if service.name == name:
      return i
  -1

proc visitService(index: int; services: openArray[ServiceSpec];
                  temporary, permanent: var seq[string];
                  order: var seq[ServiceSpec]) =
  let name = services[index].name
  if permanent.find(name) >= 0:
    return
  if temporary.find(name) >= 0:
    raise newException(ValueError,
      "cycle in dev service dependencies at " & name)
  temporary.add(name)
  for dep in services[index].dependsOn:
    let depIndex = services.serviceIndex(dep)
    if depIndex < 0:
      raise newException(ValueError,
        "service " & name & " depends on unknown service " & dep)
    visitService(depIndex, services, temporary, permanent, order)
  discard temporary.pop()
  permanent.add(name)
  order.add(services[index])

proc serviceStartOrder(services: openArray[ServiceSpec]): seq[ServiceSpec] =
  var temporary: seq[string] = @[]
  var permanent: seq[string] = @[]
  for i in 0 ..< services.len:
    visitService(i, services, temporary, permanent, result)

proc serviceSpecsFromArtifact(artifact: DevEnvArtifact): seq[ServiceSpec] =
  var specs: seq[ServiceSpec] = @[]
  for service in artifact.services:
    specs.add(serviceSpecFromSummary(artifact.projectRoot, service))
  serviceStartOrder(specs)

proc reconcileResources(state: var SessionState; specs: openArray[ServiceSpec]) =
  createDir(extendedPath(state.sessionDir))
  state.resources.add((kind: "directory", path: state.sessionDir,
    status: "ready"))
  for spec in specs:
    for resource in spec.resources:
      if resource.kind != "directory":
        raise newException(ValueError,
          "unsupported dev-session resource kind for " & spec.name & ": " &
            resource.kind)
      if resource.path.len == 0:
        raise newException(ValueError,
          "service " & spec.name & " declares a directory resource without path")
      createDir(extendedPath(resource.path))
      state.resources.add((kind: resource.kind, path: resource.path,
        status: "ready"))

proc httpRequest*(httpBindValue, path: string; httpMethod = "GET"):
    tuple[status: int; body: string] =
  var raw = httpBindValue
  if raw.startsWith("http://"):
    raw = raw["http://".len .. ^1]
  let slash = raw.find('/')
  if slash >= 0:
    raw = raw[0 ..< slash]
  let colon = raw.rfind(':')
  if colon < 0:
    raise newException(ValueError, "invalid HTTP bind address: " & httpBindValue)
  let host = raw[0 ..< colon]
  let port = parseInt(raw[colon + 1 .. ^1])
  var socket = newSocket()
  defer: socket.close()
  socket.connect(host, Port(port))
  socket.send(httpMethod & " " & path & " HTTP/1.1\r\n" &
    "Host: " & host & "\r\n" &
    "Connection: close\r\n" &
    "Content-Length: 0\r\n\r\n")
  var response = ""
  while true:
    let chunk = socket.recv(4096)
    if chunk.len == 0:
      break
    response.add(chunk)
  let headEnd = response.find("\r\n\r\n")
  let header =
    if headEnd >= 0: response[0 ..< headEnd] else: response
  let parts = header.splitWhitespace()
  if parts.len >= 2 and parts[0].startsWith("HTTP/"):
    result.status = parseInt(parts[1])
  result.body =
    if headEnd >= 0: response[headEnd + 4 .. ^1] else: ""

proc httpGetJson*(httpBindValue, path: string): JsonNode =
  let response = httpRequest(httpBindValue, path)
  if response.status < 200 or response.status >= 300:
    raise newException(IOError,
      "HTTP GET " & path & " failed with " & $response.status & ": " &
        response.body)
  parseJson(response.body)

proc readyPath(config: DevSessionSupervisorConfig): string =
  config.outDir.sessionDir / HttpReadyFile

proc waitForReadyFile(path: string; timeoutMs = 5000): JsonNode =
  var waited = 0
  while waited <= timeoutMs:
    if fileExists(extendedPath(path)):
      return readJsonFile(path)
    sleep(50)
    waited.inc(50)
  raise newException(IOError,
    "dev session HTTP server did not become ready: " & path)

proc waitForDevSessionReady*(config: DevSessionSupervisorConfig;
                             timeoutMs = 10000): JsonNode =
  let ready = waitForReadyFile(config.readyPath, timeoutMs)
  let httpBindValue = ready["httpBind"].getStr()
  var waited = 0
  while waited <= timeoutMs:
    try:
      let status = httpGetJson(httpBindValue, "/status")
      if status{"status"}.getStr() == "up":
        return status
    except CatchableError:
      discard
    sleep(50)
    waited.inc(50)
  raise newException(IOError,
    "dev session metadata did not become queryable at " & httpBindValue)

proc readinessOk(spec: ServiceSpec): bool =
  case spec.readinessKind.normalize()
  of "", "none":
    true
  of "fileexists", "file", "path":
    spec.readinessPath.len > 0 and fileExists(extendedPath(spec.readinessPath))
  of "httpget":
    if spec.readinessUrl.len == 0:
      false
    else:
      try:
        let response = httpRequest(spec.readinessUrl, "/")
        response.status >= 200 and response.status < 500
      except CatchableError:
        false
  else:
    false

proc waitForReadiness(spec: ServiceSpec) =
  var waited = 0
  while waited <= spec.readinessTimeoutMs:
    if readinessOk(spec):
      return
    sleep(50)
    waited.inc(50)
  raise newException(IOError,
    "service readiness timed out for " & spec.name)

proc startService(state: var SessionState; artifact: DevEnvArtifact;
                  artifactPath: string; spec: ServiceSpec) =
  var runtime = ServiceRuntime(spec: spec, status: "starting")
  state.services.add(runtime)
  state.writeState()
  state.emitEvent("service.starting", service = spec.name)
  let activation = activatedEnvironment(artifact, artifactPath,
    defaultWorkingDirectory = spec.cwd)
  var childArgs: seq[string] = @[]
  for i in 1 ..< spec.command.len:
    childArgs.add(spec.command[i])
  let process = startProcess(spec.command[0],
    args = childArgs,
    env = activation.env,
    workingDir = activation.workingDirectory,
    options = {poUsePath, poParentStreams})
  runtime.process = process
  runtime.pid = process.processID()
  runtime.status = "running"
  state.services[^1] = runtime
  state.startOrder.add(spec.name)
  state.writeState()
  spec.waitForReadiness()
  runtime.ready = true
  runtime.status = "ready"
  state.services[^1] = runtime
  state.writeState()
  state.emitEvent("service.ready", service = spec.name)

proc stopService(state: var SessionState; index: int) =
  if index < 0 or index >= state.services.len:
    return
  var runtime = state.services[index]
  if runtime.process.isNil:
    return
  state.emitEvent("service.stopping", service = runtime.spec.name)
  runtime.status = "stopping"
  state.services[index] = runtime
  state.writeState()
  try:
    if runtime.process.running():
      runtime.process.terminate()
      var waited = 0
      while waited < 3000 and runtime.process.running():
        sleep(50)
        waited.inc(50)
      if runtime.process.running():
        runtime.process.kill()
  except CatchableError:
    discard
  let exitCode =
    try:
      runtime.process.waitForExit()
    except CatchableError:
      -1
  runtime.process.close()
  runtime.status = "stopped"
  runtime.ready = false
  state.stopOrder.add(runtime.spec.name)
  state.services[index] = runtime
  state.writeState()
  state.emitEvent("service.stopped", service = runtime.spec.name,
    detail = "exitCode=" & $exitCode)

proc stopServices(state: var SessionState) =
  for i in countdown(state.services.len - 1, 0):
    state.stopService(i)

proc eventInputPaths(artifact: DevEnvArtifact; state: SessionState): seq[string] =
  result.add(state.stopRequestPath)
  for input in artifact.evaluationInputs:
    if input.kind == gevFileRead and input.identity.len > 0 and
        fileExists(extendedPath(input.identity)):
      result.add(input.identity)
  var seen: seq[string] = @[]
  for path in result:
    let normalized = os.normalizedPath(path)
    if seen.find(normalized) < 0:
      seen.add(normalized)
  result = seen

proc runTaskCommand(state: var SessionState; artifact: DevEnvArtifact;
                    artifactPath: string; task: DevEnvTaskSummary;
                    cycle: int) =
  if task.command.len == 0:
    return
  state.emitEvent("watch.task.started", detail = task.name, cycle = cycle)
  let activation = activatedEnvironment(artifact, artifactPath,
    defaultWorkingDirectory = artifact.projectRoot)
  let command =
    when defined(windows):
      @["cmd", "/c", task.command]
    else:
      @["sh", "-c", task.command]
  let process = startProcess(command[0],
    args = command[1 .. ^1],
    env = activation.env,
    workingDir = activation.workingDirectory,
    options = {poUsePath, poParentStreams})
  let exitCode = process.waitForExit()
  process.close()
  state.emitEvent("watch.task.finished", detail = task.name & ":" & $exitCode,
    cycle = cycle)
  if exitCode != 0:
    raise newException(OSError,
      "watch task " & task.name & " failed with exit " & $exitCode)

proc computeFreshArtifact(config: DevSessionSupervisorConfig): DevEnvEdgeResult =
  computeDevEnvEdge(DevEnvEdgeConfig(
    modulePath: config.modulePath,
    projectRoot: config.projectRoot,
    outDir: config.outDir,
    workDir: config.workDir,
    publicCliPath: config.publicCliPath,
    monitorCliPath: config.monitorCliPath,
    monitorShimLibPath: config.monitorShimLibPath,
    activity: config.activity,
    lockSliceId: config.lockSliceId,
    developOverridesPath: config.developOverridesPath,
    renderShell: false,
    statsEnabled: false))

proc runWatchCycle(state: var SessionState; config: DevSessionSupervisorConfig;
                   artifact: var DevEnvArtifact; artifactPath: var string) =
  state.watchCycles.inc
  let cycle = state.watchCycles
  state.emitEvent("watch.cycle.started", cycle = cycle)
  let edge = computeFreshArtifact(config)
  artifactPath = edge.artifactPath
  artifact = readDevEnvArtifact(artifactPath)
  for task in artifact.tasks:
    state.runTaskCommand(artifact, artifactPath, task, cycle)
  state.writeState()
  state.emitEvent("watch.cycle.finished", cycle = cycle)

proc stopRequested(state: SessionState): bool =
  fileExists(extendedPath(state.stopRequestPath))

proc runWatchLoop(state: var SessionState; config: DevSessionSupervisorConfig;
                  artifact: var DevEnvArtifact; artifactPath: var string) =
  if artifact.tasks.len > 0:
    state.runWatchCycle(config, artifact, artifactPath)
  while not state.stopRequested():
    let paths = eventInputPaths(artifact, state)
    state.emitEvent("watch.idle")
    var watcher = openFilesystemWatcher(paths)
    try:
      let event = watcher.waitForEvent()
      if state.stopRequested():
        break
      if event.path == state.stopRequestPath or
          event.path.startsWith(state.sessionDir):
        continue
      state.lastWatchPath = event.path
      state.emitEvent("watch.filesystem.changed", watchPath = event.path,
        detail = event.detail)
      discard watcher.drainDebouncedEvents(config.debounceMs)
    finally:
      watcher.closeFilesystemWatcher()
    if state.stopRequested():
      break
    state.runWatchCycle(config, artifact, artifactPath)

proc startHttpServer(config: DevSessionSupervisorConfig) =
  let httpBindParts = parseHttpBind(config.httpBind)
  let args = @[
    "__repro-dev-session-http",
    "--session-dir", config.outDir.sessionDir,
    "--host", httpBindParts.host,
    "--port", $httpBindParts.port
  ]
  discard startProcess(config.publicCliPath,
    args = args,
    workingDir = config.projectRoot,
    options = {poUsePath, poParentStreams})

proc runDevSessionSupervisor*(config: DevSessionSupervisorConfig): int =
  var artifactPath = config.artifactPath
  var artifact = readDevEnvArtifact(artifactPath)
  var state = SessionState(
    schemaId: SessionSchemaId,
    sessionId: "dev-session-" & $getCurrentProcessId() & "-" &
      $epochTime().int64,
    mode: config.mode,
    projectRoot: config.projectRoot,
    artifactPath: artifactPath,
    activity: config.activity,
    sessionDir: config.outDir.sessionDir,
    httpBind: "",
    status: "starting",
    terminalEvents: config.foreground)
  createDir(extendedPath(state.sessionDir))
  try:
    removeFile(extendedPath(state.stopRequestPath))
  except OSError:
    discard
  state.writeState()
  config.startHttpServer()
  let ready = waitForReadyFile(config.readyPath, 5000)
  state.httpBind = ready["httpBind"].getStr()
  state.writeState()
  state.emitEvent("session.created")

  let specs = serviceSpecsFromArtifact(artifact)
  state.reconcileResources(specs)
  state.writeState()
  state.emitEvent("resources.reconciled")
  for spec in specs:
    state.startService(artifact, artifactPath, spec)
  state.status = "up"
  state.writeState()
  state.emitEvent("session.up")

  try:
    if config.mode == dsmDev:
      state.runWatchLoop(config, artifact, artifactPath)
    else:
      while not state.stopRequested():
        sleep(100)
  finally:
    state.status = "stopping"
    state.writeState()
    state.emitEvent("session.stopping")
    state.stopServices()
    state.status = "down"
    state.writeState()
    state.emitEvent("session.down")
  0

proc requestPathAndQuery(target: string): tuple[path: string; query: string] =
  let q = target.find('?')
  if q < 0:
    (path: target, query: "")
  else:
    (path: target[0 ..< q], query: target[q + 1 .. ^1])

proc queryValue(query, name, fallback: string): string =
  for part in query.split('&'):
    let eq = part.find('=')
    if eq > 0 and part[0 ..< eq] == name:
      return part[eq + 1 .. ^1]
  fallback

proc sendResponse(client: Socket; status: int; contentType, body: string) =
  let reason =
    case status
    of 200: "OK"
    of 202: "Accepted"
    of 404: "Not Found"
    else: "Error"
  client.send("HTTP/1.1 " & $status & " " & reason & "\r\n" &
    "Content-Type: " & contentType & "\r\n" &
    "Content-Length: " & $body.len & "\r\n" &
    "Connection: close\r\n\r\n" & body)

proc sendSse(client: Socket; id: int; node: JsonNode) =
  let kind = node{"kind"}.getStr("message")
  client.send("id: " & $id & "\n")
  client.send("event: " & kind & "\n")
  client.send("data: " & $node & "\n\n")

proc serveEvents(client: Socket; sessionDir, query: string) =
  let waitMs = parseInt(queryValue(query, "wait-ms", "250"))
  let since = parseInt(queryValue(query, "since", "0"))
  client.send("HTTP/1.1 200 OK\r\n" &
    "Content-Type: text/event-stream\r\n" &
    "Cache-Control: no-cache\r\n" &
    "Connection: close\r\n\r\n")
  let path = sessionDir / EventLogFile
  var sent = 0
  var waited = 0
  while waited <= waitMs:
    if fileExists(extendedPath(path)):
      let lines = readFile(extendedPath(path)).splitLines()
      for i, line in lines:
        if line.len == 0 or i < since or i < sent:
          continue
        client.sendSse(i, parseJson(line))
        sent = i + 1
    sleep(50)
    waited.inc(50)

proc recvHttpLine(socket: Socket): string =
  while true:
    let chunk = socket.recv(1)
    if chunk.len == 0:
      return
    let ch = chunk[0]
    if ch == '\n':
      if result.len > 0 and result[^1] == '\r':
        result.setLen(result.len - 1)
      return
    result.add(ch)

proc handleHttpClient(client: Socket; sessionDir: string) =
  defer: client.close()
  let request = client.recvHttpLine()
  if request.len == 0:
    return
  while true:
    let line = client.recvHttpLine()
    if line.len == 0:
      break
  let parts = request.splitWhitespace()
  if parts.len < 2:
    client.sendResponse(404, "text/plain", "bad request\n")
    return
  let httpMethod = parts[0]
  let target = parts[1].requestPathAndQuery()
  case target.path
  of "/status", "/session":
    let metadata = sessionDir / MetadataFile
    if fileExists(extendedPath(metadata)):
      client.sendResponse(200, "application/json",
        readFile(extendedPath(metadata)))
    else:
      client.sendResponse(404, "application/json", "{\"error\":\"no session\"}\n")
  of "/events":
    client.serveEvents(sessionDir, target.query)
  of "/session/stop":
    if httpMethod != "POST":
      client.sendResponse(404, "application/json",
        "{\"error\":\"POST required\"}\n")
    else:
      writeJsonFile(sessionDir / StopRequestFile, %*{
        "schemaId": "reprobuild.dev-session.stop-request.v1",
        "source": "http",
        "time": nowIso()
      })
      client.sendResponse(202, "application/json", "{\"stopping\":true}\n")
  of "/health":
    client.sendResponse(200, "text/plain", "ok\n")
  else:
    client.sendResponse(404, "application/json", "{\"error\":\"not found\"}\n")

proc runDevSessionHttpServer*(config: DevSessionHttpConfig): int =
  createDir(extendedPath(config.sessionDir))
  var server = newSocket()
  defer: server.close()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(config.port), config.host)
  server.listen()
  let local = server.getLocalAddr()
  let httpBindValue = httpUrl(
    if config.host.len > 0: config.host else: local[0],
    int(local[1]))
  writeJsonFile(config.sessionDir / HttpReadyFile, %*{
    "schemaId": "reprobuild.dev-session.http.v1",
    "httpBind": httpBindValue,
    "pid": getCurrentProcessId()
  })
  while not fileExists(extendedPath(config.sessionDir / StopRequestFile)):
    var client: owned(Socket)
    server.accept(client)
    if not client.isNil:
      client.handleHttpClient(config.sessionDir)
  0
