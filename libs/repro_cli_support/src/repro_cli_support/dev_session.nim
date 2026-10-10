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

  DevSessionProducerOpsResolver* =
      proc (artifact: DevEnvArtifact): seq[DevEnvShellOp]
    ## W2 — resolves the cross-repo ``uses:`` producer pins for an artifact
    ## and returns the activation ops that BIND the ones a previous ``repro
    ## build`` materialized, reporting on stderr any it could not put into
    ## effect.
    ##
    ## A callback rather than a precomputed seq for two reasons. The
    ## supervisor re-reads the artifact on every watch cycle, and the binding
    ## is deliberately re-derived per activation rather than cached — a
    ## session that runs for hours must pick up a producer rebuilt underneath
    ## it. And it keeps the layering: the resolver lives in
    ## ``repro_cli_support``, which IMPORTS this module.
    ##
    ## It is a REQUIRED PARAMETER of ``runDevSessionSupervisor`` and
    ## deliberately not a field of ``DevSessionSupervisorConfig``. That
    ## distinction is the whole fix: Nim object construction zero-fills a
    ## field nobody mentioned, so a config-shaped callback is silently ``nil``
    ## for any construction site that forgets it — which is exactly how the
    ## ``--foreground`` arm of ``repro dev`` / ``repro up`` ended up activating
    ## an environment with no producer pins in it while the detached arm bound
    ## them correctly. A parameter with no default cannot be forgotten; it can
    ## only be refused in writing, at a call site the audit
    ## (``t_w2_activation_surfaces_declare_producer_ops.nim``) reads.

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

  DevSessionReadyBudget* = object
    ## How long ``repro up`` / ``repro dev`` will wait for the session it
    ## detached to report ``session.up``, and WHERE that number came from.
    ## The provenance travels with the number because the diagnostic has to
    ## name it: a wait the user asked for and a wait the tool derived are
    ## different failures with different remedies.
    timeoutMs*: int
    explicit*: bool       ## true when ``--ready-timeout`` set ``timeoutMs``.
    derivedMs*: int       ## what the declared services derive, always.

  DevSessionStillStartingError* = object of CatchableError
    ## The wait expired while the session was still coming up. Distinct from
    ## ``IOError`` ON PURPOSE: the session is alive and may well be up by the
    ## time anyone reads the message, so the caller maps this to its own exit
    ## code rather than to the one it uses for a session that cannot start.
    ## See the exit-code comment in ``runUpOrDevCommand``.

  SessionState = object
    schemaId: string
    sessionId: string
    failure: string
      ## Set when the session could not bring its services up, and published
      ## in ``session.json`` so the PARENT can read a terminal failure
      ## instead of inferring one from the clock. Empty on every healthy
      ## session.
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
    producerOpsFor: DevSessionProducerOpsResolver
      ## W2 — the resolver ``runDevSessionSupervisor`` was handed. It lives on
      ## the private session state rather than on the public config precisely
      ## so that no external construction can leave it unset; see
      ## ``DevSessionProducerOpsResolver``.

const
  DefaultServiceReadinessTimeoutMs* = 5000
    ## The readiness timeout a service that declares none is supervised
    ## under. ``serviceSpecFromSummary`` applies it, and
    ## ``declaredReadinessTimeoutMs`` re-reads it, so the parent's derived
    ## wait and the supervisor's own per-service wait cannot drift apart by
    ## disagreeing about the default.

  DevSessionReadyMarginMs* = 10_000
    ## Added ONCE to the sum of the declared service readiness timeouts to
    ## get the parent's wait. It pays for the work the supervisor does that
    ## no service declares: its own process spawn, its re-read of the
    ## artifact, the control-API child's bind + ``http-ready.json`` publish
    ## (which the supervisor itself allows 5000 ms for, in
    ## ``runDevSessionSupervisor``), resource reconciliation, and the
    ## parent's own 50 ms poll granularity.
    ##
    ## 10_000 is twice the only part of that with a declared bound, which is
    ## the honest way to pick it: the margin's job is to absorb the
    ## supervisor's fixed overhead on a loaded host, and the one piece of
    ## that overhead anyone has put a number on is the 5000 ms control-API
    ## wait. It is deliberately NOT proportional to the declared timeouts --
    ## a stack that declares 600 s does not take proportionally longer to
    ## fork a process -- and it is deliberately not smaller: an empty
    ## service set derives exactly this value, which is the ten seconds
    ## ``repro up`` waited before it derived anything at all, so a session
    ## with no services keeps the wait it always had.

  DevSessionControlApiTimeoutMs* = 30_000
    ## A separate, SHORTER bound on the first phase of the parent's wait:
    ## the appearance of ``http-ready.json``. That file is written by the
    ## control-API child within milliseconds of the supervisor starting, so
    ## its absence is evidence the supervisor did not start -- a "cannot
    ## start", not a "still starting". Keeping it out of the derived budget
    ## is what stops a stack that declares 600 s from spending ten minutes
    ## discovering that its supervisor died at once. Capped by the budget,
    ## so an explicit ``--ready-timeout`` smaller than this still wins.

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
    "failure": state.failure,
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
  result.readinessTimeoutMs = DefaultServiceReadinessTimeoutMs
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
    result.readinessTimeoutMs = readiness{"timeoutMs"}.getInt(
      DefaultServiceReadinessTimeoutMs)
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

proc discardStaleControlApiBind*(config: DevSessionSupervisorConfig) =
  ## Delete this session directory's ``http-ready.json`` BEFORE a supervisor
  ## is started in it, so that nothing can read a previous session's bind
  ## address out of it.
  ##
  ## That file is published by the control-API child and was never
  ## invalidated by anything: ``repro down`` leaves it, a killed supervisor
  ## leaves it, and the next ``repro up`` in the same directory therefore
  ## finds a file naming a port that closed when the last session ended.
  ## TWO readers take that bind at face value, which is why this has to
  ## happen before the launch rather than inside either of them:
  ##
  ## * ``runDevSessionSupervisor``'s own ``waitForReadyFile`` checks for the
  ##   file BEFORE sleeping, so a leftover file is returned on the first
  ##   check -- every time, not as a race -- and the supervisor publishes
  ##   that dead address as its own ``httpBind`` in ``session.json``. That
  ##   is the address ``repro up`` prints and the address ``repro down``
  ##   later tries to POST to.
  ## * ``waitForDevSessionReady``'s phase 1 does the same, so the parent
  ##   polls a closed port for its whole budget.
  ##
  ## Removing the file makes both of them wait for the bind THIS session's
  ## control API publishes. Nothing else reads it: ``repro down`` takes its
  ## ``httpBind`` from ``session.json``, so removing this file does not take
  ## a running session's stop path away.
  try:
    removeFile(extendedPath(config.readyPath))
  except OSError, IOError:
    # Best effort, and the failure is not silent in consequence: if the
    # stale file survives, the waiters below read a bind that does not
    # answer and say so rather than returning success.
    discard

proc declaredReadinessTimeoutMs*(service: DevEnvServiceSummary): int =
  ## The readiness timeout THIS service declares, read out of the same
  ## supervisor metadata ``serviceSpecFromSummary`` reads, with the same
  ## default.
  ##
  ## Deliberately LENIENT where that one is strict: metadata this cannot
  ## parse yields the default rather than an exception. Refusing to start a
  ## session because the number used to SIZE A WAIT could not be read would
  ## replace a good diagnostic with a bad one -- the supervisor raises the
  ## real ``ValueError`` for malformed metadata a moment later, and it names
  ## the service.
  result = DefaultServiceReadinessTimeoutMs
  let text = service.metadataText.strip()
  if text.len == 0:
    return
  try:
    let metadata = parseJson(text)
    if metadata.hasKey("readiness") and metadata["readiness"].kind == JObject:
      result = metadata["readiness"]{"timeoutMs"}.getInt(
        DefaultServiceReadinessTimeoutMs)
  except CatchableError:
    discard

proc derivedReadyTimeoutMs*(artifact: DevEnvArtifact): int =
  ## The parent's wait, DERIVED from the session's declared services rather
  ## than fixed: the SUM of their declared readiness timeouts plus
  ## ``DevSessionReadyMarginMs``.
  ##
  ## The sum, not the maximum, and that is the point rather than an
  ## over-estimate. ``runDevSessionSupervisor`` starts services
  ## SEQUENTIALLY -- ``for spec in specs: state.startService(...)``, and
  ## ``startService`` blocks in ``spec.waitForReadiness()`` before the next
  ## one is spawned -- so the supervisor's own worst case before it emits
  ## ``session.up`` is the sum of what it allows each service. Two services
  ## declaring 600_000 are supervised for up to 1_200_000 ms between them;
  ## a parent that waited ``max + margin`` would abandon the second one
  ## while the supervisor was still legitimately waiting for it, which is
  ## the same defect this replaces, one service further along. For a
  ## single-service session, which is every stack named in the issue, sum
  ## and maximum are the same number.
  ##
  ## This is the ceiling the supervisor could reach, not a prediction of
  ## what a session takes: a healthy stack returns as soon as ``/status``
  ## says ``up``, so a generous derivation costs nothing on the happy path
  ## and only ever buys patience on the slow one.
  var declared = 0
  for service in artifact.services:
    declared.inc(service.declaredReadinessTimeoutMs)
  declared + DevSessionReadyMarginMs

proc derivedReadyTimeoutMs*(config: DevSessionSupervisorConfig): int =
  ## The same derivation, from the artifact the caller is about to hand the
  ## supervisor. The declared timeouts ARE available to the parent at this
  ## point in the flow: ``runUpOrDevCommand`` has just computed the dev-env
  ## edge and put its ``artifactPath`` on the config, which is the same file
  ## the supervisor re-reads to build its ``ServiceSpec`` set. No new
  ## plumbing is needed to see them -- only this read.
  ##
  ## An unreadable artifact falls back to the bare margin, which is the ten
  ## seconds this wait used to be. The supervisor reads the same file and
  ## will fail with a message that names it, so the fallback only has to
  ## survive long enough to let that happen.
  try:
    derivedReadyTimeoutMs(readDevEnvArtifact(config.artifactPath))
  except CatchableError:
    DevSessionReadyMarginMs

proc readyBudget*(config: DevSessionSupervisorConfig; explicitMs: int):
    DevSessionReadyBudget =
  ## ``explicitMs`` is ``--ready-timeout`` in milliseconds, or 0 when the
  ## user did not pass it.
  ##
  ## An explicit value WINS, including when it is smaller than a declared
  ## service timeout. That is not an oversight to be corrected by clamping
  ## it up to the declared value: a caller that says "do not block me for
  ## more than two seconds" is asking about ITS OWN patience, not making a
  ## claim about the service, and a CI step that must not hang has no other
  ## way to say so. What the tool owes that caller is not obedience plus
  ## silence but obedience plus attribution -- so ``explicit`` is recorded
  ## here and the diagnostic says the wait was theirs, and names what the
  ## services would have been given, so nobody mistakes a short wait for a
  ## slow stack.
  let derived = config.derivedReadyTimeoutMs()
  if explicitMs > 0:
    DevSessionReadyBudget(timeoutMs: explicitMs, explicit: true,
      derivedMs: derived)
  else:
    DevSessionReadyBudget(timeoutMs: derived, explicit: false,
      derivedMs: derived)

proc describe*(budget: DevSessionReadyBudget): string =
  ## One clause naming the wait and whose it is, for the announcement the
  ## parent prints BEFORE waiting and for the diagnostic it prints if the
  ## wait expires. Both read from this one proc so they cannot disagree.
  if budget.explicit:
    $budget.timeoutMs & " ms (--ready-timeout; the declared service " &
      "readiness timeouts would derive " & $budget.derivedMs & " ms)"
  else:
    $budget.timeoutMs & " ms (derived: " &
      $(budget.derivedMs - DevSessionReadyMarginMs) &
      " ms of declared service readiness timeouts + " &
      $DevSessionReadyMarginMs & " ms margin; override with " &
      "--ready-timeout=MS)"

proc waitForReadyFile(path: string; timeoutMs = 5000): JsonNode =
  var waited = 0
  while waited <= timeoutMs:
    if fileExists(extendedPath(path)):
      return readJsonFile(path)
    sleep(50)
    waited.inc(50)
  raise newException(IOError,
    "dev session HTTP server did not become ready: " & path)

proc eventLogHint(config: DevSessionSupervisorConfig): string =
  "  per-service state: " & (config.outDir.sessionDir / EventLogFile)

proc controlApiStatus(httpBindValue: string): JsonNode =
  ## The session's published state, read ONLY through the live control API.
  ## ``nil`` when the API does not answer.
  ##
  ## THERE WAS A ``session.json`` FALLBACK HERE AND IT IS DELETED, because
  ## reading ``up`` out of the file turned a loud failure into a silent
  ## success. ``repro up`` in a directory that still carried a previous
  ## session's ``http-ready.json`` polled a closed port, fell through to the
  ## file, found ``"status": "up"`` -- written either by the session that had
  ## already ended or by the one just starting -- and exited 0 while
  ## printing an address nothing was listening on. Exit 0 is reserved for "a
  ## script may now use these services" (see
  ## ``DevSessionStillStartingExitCode``), so a fallback that can satisfy it
  ## from a stale file is worse than no fallback.
  ##
  ## The justification the fallback carried -- "a supervisor that died
  ## without publishing a terminal status leaves the file as the only
  ## witness" -- does not survive contact with the other half of this
  ## module: the control API is a separate child that OUTLIVES the
  ## supervisor (``runDevSessionSupervisor``'s own comment records it
  ## answering ``starting`` forever after the supervisor exited), and it
  ## serves ``/status`` by reading that very ``session.json``. So in the
  ## never-ready case the API serves the ``failed`` status the supervisor
  ## published, and the file reaches the parent anyway -- through a reader
  ## whose answer also proves someone is still there to answer.
  ##
  ## What the file can still witness that the API cannot is a session whose
  ## control API has ALSO died. No case in this suite exercises that, and an
  ## untested branch that can convert a failure into a success does not earn
  ## its place, so it is gone; ``waitForDevSessionReady`` now reports that
  ## situation as what it is -- nothing answered -- instead of guessing from
  ## a file.
  try:
    httpGetJson(httpBindValue, "/status")
  except CatchableError:
    nil

proc waitForDevSessionReady*(config: DevSessionSupervisorConfig;
                             budget: DevSessionReadyBudget): JsonNode =
  ## Wait for the session the caller detached to report ``session.up``, and
  ## report THREE outcomes rather than two.
  ##
  ## ``budget`` has NO DEFAULT, on purpose. The defect this replaces was a
  ## ``timeoutMs = 10000`` default that every call site accepted without
  ## saying so, while each service declared its own readiness timeout --
  ## 600_000 for ``infra``'s ``sso``, 300_000 for
  ## ``isonim-platform``'s ``isonim-local-stack`` -- which the supervisor
  ## honoured and this proc ignored, so a healthy session was reported as an
  ## error. A parameter with no default cannot be accepted silently; it has
  ## to be computed by ``readyBudget`` at a call site, which is where the
  ## declared timeouts are visible.
  ##
  ## The three outcomes:
  ##
  ## * the session reported ``up`` -- returns its published state.
  ## * the session reported a TERMINAL failure (``status == "failed"``, or
  ##   its control API never appeared) -- raises ``IOError``. This is
  ##   "cannot start", and it is raised AS SOON AS the supervisor says so
  ##   rather than when the clock runs out, so a service that declares
  ##   600_000 ms and fails in two seconds fails in two seconds.
  ## * the budget expired with the session still coming up -- raises
  ##   ``DevSessionStillStartingError``. Nothing here stops the supervisor,
  ##   so the session is left as it was, and the message says what this
  ##   proc actually OBSERVED about it -- which is not always "it is
  ##   running": see the three arms where that exception is built.
  let started = epochTime()
  let budgetSeconds = budget.timeoutMs.float / 1000.0
  let deadline = started + budgetSeconds
  let readyFile = config.readyPath

  # Phase 1 -- the control API's ``http-ready.json``. Bounded by
  # ``DevSessionControlApiTimeoutMs`` AND by the budget, whichever is
  # sooner; see that constant for why this phase is not given the whole
  # derived budget.
  let controlDeadline = min(deadline,
    started + DevSessionControlApiTimeoutMs.float / 1000.0)
  while not fileExists(extendedPath(readyFile)):
    let now = epochTime()
    if now >= controlDeadline:
      if now >= deadline:
        raise newException(DevSessionStillStartingError,
          "dev session is still starting: its control API had not published " &
            readyFile & " after the parent waited " &
            $int((now - started) * 1000.0) & " ms\n" &
            "  that wait was " & budget.describe() & "\n" &
            config.eventLogHint() & "\n" &
            "  the session was left running: `repro down` stops it, and a " &
            "second `repro up` would contend with it")
      raise newException(IOError,
        "dev session cannot start: its supervisor did not publish a control " &
          "API within " & $DevSessionControlApiTimeoutMs & " ms (" &
          readyFile & " was never written)\n" &
          "  supervisor output: " &
          (config.outDir.sessionDir / "supervisor.log"))
    sleep(50)
  let httpBindValue = readJsonFileResilient(readyFile){"httpBind"}.getStr()

  # Phase 2 -- the session's own status, read only from the live control
  # API. ``statusReads`` and ``lastStatus`` exist to BOUND WHAT THE
  # DIAGNOSTIC MAY ASSERT: see the end of this proc.
  var statusReads = 0
  var lastStatus = ""
  var sessionId = ""
  while true:
    let status = controlApiStatus(httpBindValue)
    if not status.isNil:
      statusReads.inc
      let reported = status{"status"}.getStr("")
      if reported.len > 0:
        lastStatus = reported
      if status{"sessionId"}.getStr().len > 0:
        sessionId = status{"sessionId"}.getStr()
      if lastStatus == "up":
        return status
      if lastStatus == "failed":
        let failure = status{"failure"}.getStr("a service failed to start")
        # The waited figure is in the message so the BOUND is observable
        # from outside: this arm exists to fail when the supervisor says
        # so rather than when the budget runs out, and a reader (or a
        # test) can only tell those apart if the number is published.
        raise newException(IOError,
          "dev session cannot start: " & failure & "\n" &
            "  the supervisor reported that after the parent waited " &
            $int((epochTime() - started) * 1000.0) & " ms of the " &
            $budget.timeoutMs & " ms allowed\n" &
            config.eventLogHint())
    if epochTime() >= deadline:
      break
    sleep(50)
  let waitedMs = int((epochTime() - started) * 1000.0)

  # WHAT THIS MESSAGE MAY ASSERT IS BOUNDED BY WHAT THE LOOP OBSERVED, and
  # the three arms below are the three things the loop can have seen. The
  # version this replaces had one arm and asserted two facts it had not
  # established: that the session "reported `starting`" -- which was merely
  # the value ``lastStatus`` was INITIALISED to -- and that "its control API
  # is answering at <addr>", on a run where every single poll had failed and
  # nothing was listening at that address at all. Measured on a stale
  # session directory: the port named in the message was closed.
  #
  # This matters more here than in most diagnostics, because the whole
  # reason this wait was rewritten is that the old one misdirected the
  # reader about WHERE TO LOOK. A message that invents a live control API
  # sends them to a port instead of to the supervisor log, which is the same
  # defect in a new place.
  let headline =
    if lastStatus.len > 0:
      "it reported `" & lastStatus & "`, not `session.up`, after the " &
        "parent waited " & $waitedMs & " ms"
    elif statusReads > 0:
      "its control API answered but never published a `status`, after the " &
        "parent waited " & $waitedMs & " ms"
    else:
      "no status was ever read from the control API at " & httpBindValue &
        " -- every poll failed -- after the parent waited " & $waitedMs &
        " ms"
  let evidence =
    if lastStatus.len > 0:
      "  its control API is answering at " & httpBindValue &
        ", so this is a WAIT that expired, not a session that failed"
    elif statusReads > 0:
      "  its control API is answering at " & httpBindValue &
        ", but it has published no `status` for the session, so what the " &
        "session is doing cannot be told from here"
    else:
      "  nothing answered at that address, so this is EITHER a wait that " &
        "expired or a supervisor whose control API published " &
        HttpReadyFile & " and then died; the supervisor log is the place " &
        "to look: " & (config.outDir.sessionDir / "supervisor.log")
  # The closing line differs for the same reason. "Left running" is a claim
  # about the session, and in the arm where nothing ever answered there is
  # no evidence for it. What IS true in every arm is the narrower statement
  # about this process: it stopped nothing.
  let disposition =
    if statusReads > 0:
      "  the session was left running: `repro down` stops it, and a second " &
        "`repro up` would contend with it"
    else:
      "  this command stopped nothing, so a supervisor may still be " &
        "running: `repro down` stops it if it is, and a second `repro up` " &
        "would contend with it if it is"
  raise newException(DevSessionStillStartingError,
    "dev session " & (if sessionId.len > 0: sessionId else: "(unnamed)") &
      " is still starting: " & headline & "\n" &
      "  that wait was " & budget.describe() & "\n" &
      evidence & "\n" &
      config.eventLogHint() & "\n" &
      disposition)

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

proc producerOps(state: SessionState;
                 artifact: DevEnvArtifact): seq[DevEnvShellOp] =
  ## W2 — see ``DevSessionProducerOpsResolver``. Every activation the
  ## supervisor performs goes through here, so there is ONE place the session's
  ## producer binding is derived and no per-activation site that could differ.
  ##
  ## ``nil`` can only arrive here from a caller that wrote ``nil`` at the
  ## ``runDevSessionSupervisor`` call site — which the W2 activation-surface
  ## audit rejects. It is tolerated rather than asserted because a supervisor
  ## that aborts a developer's session over a missing binding would be a worse
  ## failure than the one it is guarding.
  if state.producerOpsFor == nil:
    return @[]
  state.producerOpsFor(artifact)

proc startService(state: var SessionState;
                  artifact: DevEnvArtifact;
                  artifactPath: string; spec: ServiceSpec) =
  var runtime = ServiceRuntime(spec: spec, status: "starting")
  state.services.add(runtime)
  state.writeState()
  state.emitEvent("service.starting", service = spec.name)
  let activation = activatedEnvironment(artifact, artifactPath,
    defaultWorkingDirectory = spec.cwd,
    extraOps = state.producerOps(artifact))
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

proc recordStartFailure(state: var SessionState; service, detail: string) =
  ## Publish a terminal start failure: ``status: "failed"`` plus the reason
  ## in ``session.json``, and one event in ``events.jsonl``. Both surfaces,
  ## because the parent polls the first and a human reads the second.
  state.status = "failed"
  state.failure =
    if service.len > 0: "service " & service & ": " & detail
    else: detail
  state.writeState()
  state.emitEvent(
    if service.len > 0: "service.failed" else: "session.failed",
    service = service, detail = detail)

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

proc runTaskCommand(state: var SessionState;
                    artifact: DevEnvArtifact;
                    artifactPath: string; task: DevEnvTaskSummary;
                    cycle: int) =
  if task.command.len == 0:
    return
  state.emitEvent("watch.task.started", detail = task.name, cycle = cycle)
  let activation = activatedEnvironment(artifact, artifactPath,
    defaultWorkingDirectory = artifact.projectRoot,
    extraOps = state.producerOps(artifact))
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
    # Executable-Consolidation M1: when ``monitorCliPath`` is the ``repro``
    # image (self-spawn), prepend the ``internal io monitor`` selector. The
    # literal mirrors ``internalIoMonitorArgs`` in ``repro_cli_support.nim``.
    monitorCliArgs: @["internal", "io", "monitor"],
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

proc runDevSessionSupervisor*(config: DevSessionSupervisorConfig;
                              producerOpsFor: DevSessionProducerOpsResolver):
    int =
  ## W2 — ``producerOpsFor`` has no default ON PURPOSE. A dev session starts
  ## services and runs watch-cycle tasks in the activated environment, so it is
  ## an activation surface exactly like ``repro exec``; a caller that reaches
  ## this proc has to state, in writing, what it wants done about the
  ## workspace's declared ``uses:`` producer pins. Both call sites are in
  ## ``repro_cli_support`` (the ``--foreground`` arm of ``repro dev`` / ``repro
  ## up``, and the detached supervisor's re-entry helper) and both pass
  ## ``devEnvProducerOpsResolver``; the audit in
  ## ``t_w2_activation_surfaces_declare_producer_ops.nim`` fails if a third one
  ## appears that does not.
  var artifactPath = config.artifactPath
  var artifact = readDevEnvArtifact(artifactPath)
  var state = SessionState(
    schemaId: SessionSchemaId,
    producerOpsFor: producerOpsFor,
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
  # Before the control-API child can publish a bind, the PREVIOUS session's
  # published bind has to go: ``waitForReadyFile`` below checks for the file
  # before it sleeps, so a leftover one is what it returns, and this
  # supervisor would record a closed port as its own ``httpBind``. See
  # ``discardStaleControlApiBind``. The parent does this too, before it
  # launches this process, because it reads the same file.
  config.discardStaleControlApiBind()
  config.startHttpServer()
  let ready = waitForReadyFile(config.readyPath, 5000)
  state.httpBind = ready["httpBind"].getStr()
  state.writeState()
  state.emitEvent("session.created")

  # A session that cannot bring its services up is a TERMINAL condition, and
  # until now it was invisible from outside: the exception escaped here, the
  # supervisor exited, ``session.json`` was left saying ``starting``, and the
  # control-API child kept answering ``starting`` forever. The only evidence
  # reaching the parent was the clock -- which cannot tell a service that
  # will never be ready from one that declared 600_000 ms and means it.
  # Publishing the failure in ``session.json`` and in ``events.jsonl`` is
  # what lets ``waitForDevSessionReady`` fail at the moment the supervisor
  # knows, instead of at the end of its budget.
  #
  # The exception is RE-RAISED unchanged: this arm adds a report, it does
  # not change what a failed start does. In particular it does NOT stop the
  # services that did start -- that pre-existing leak is untouched here.
  var specs: seq[ServiceSpec]
  try:
    specs = serviceSpecsFromArtifact(artifact)
    state.reconcileResources(specs)
  except CatchableError as err:
    state.recordStartFailure("", err.msg)
    raise
  state.writeState()
  state.emitEvent("resources.reconciled")
  for spec in specs:
    try:
      state.startService(artifact, artifactPath, spec)
    except CatchableError as err:
      state.recordStartFailure(spec.name, err.msg)
      raise
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
