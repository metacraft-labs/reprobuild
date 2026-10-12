import std/[algorithm, hashes, json, net, options, os, osproc, sequtils,
            strtabs, strutils, tables, times]

import cbor
import repro_core
import repro_dev_env_activation
import repro_dev_env_artifacts
import repro_dev_env_engine
import repro_provider_runtime
import repro_project_dsl                 # ServiceIdentityDef / ServiceScope
import repro_resources/service_identity  # the (identity, scope, environment) key
import repro_resources/service_registry  # the snapshot codec + lease words
import repro_resources/readiness_edge    # D-SS10 (§7.1): the edge's own names
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

  ServiceSpec* = object
    ## Shared-Development-Services L9 exported this type and its fields.
    ## It is read-only widening — no field changed and no behaviour moved
    ## — and it is earned: the claim L9 has to prove is that the typed
    ## `service` block's supervision facts reach the SPEC the supervisor
    ## starts from, and until now the only way to see any of that from
    ## outside was `sharedServiceInstanceLaunch`, which reports the
    ## command and the working directory and nothing else. Asserting the
    ## readiness probe and the state directories through a running
    ## supervisor instead would have been a test of process timing
    ## rather than of the plumbing under test.
    name*: string
    command*: seq[string]
    cwd*: string
    dependsOn*: seq[string]
    readinessKind*: string
    readinessPath*: string
    readinessUrl*: string
    readinessTimeoutMs*: int
    resources*: seq[tuple[kind, path: string]]

  SharedServiceInstanceDeclaration* = object
    ## Shared-Development-Services L7 (§4.5): the dev-session service
    ## metadata's `instance` block — the declaration that makes a service
    ## a SHARED INSTANCE held in the daemon's registry rather than a
    ## process this session owns.
    ##
    ## WHY IT ARRIVES THROUGH THE SERVICE METADATA AND NOT THROUGH THE
    ## TYPED `service` BLOCK, SAID PLAINLY BECAUSE IT IS A LIMITATION AND
    ## NOT A DESIGN. L1-L6 lowered the typed `service` block's identity
    ## and scope onto `DslServiceDef`, into the `gnkService` graph node
    ## (payload v2) and into the interface lift — but NOTHING routes them
    ## into `DevEnvArtifact.services`, which is the only service channel
    ## the dev-session supervisor reads. Measured at `478abb590` plus
    ## this tree: `registeredServices` has exactly ONE non-test caller,
    ## the graph-fragment emitter
    ## (`repro_project_dsl/runtime_provider.nim:309`); every other
    ## reference is a test or this module's own prose.
    ## `service_identity.nim` does NOT reference it at all — an earlier
    ## draft of this comment said it did, and that was simply wrong.
    ##
    ## The GAP is unchanged by that correction, and it is the gap that
    ## matters: `DevEnvServiceSummary` carries only `name`,
    ## `activityRequirements`, `supervisorPlanRef`,
    ## `hasSupervisorPlanRef` and `metadata`. There is no field an
    ## identity or a scope could travel in, so no amount of routing on
    ## the producing side would deliver them — the typed interface has
    ## to reach the CONSUMING path first. So L7 reads the declaration
    ## from the channel that exists, and the plumbing is handed on; the
    ## milestone drawer names which milestone owns it.
    ##
    ## THE IDENTITY AND THE SCOPE ARE NOT DECLARED HERE. They are
    ## declared on the typed `service` block (`identity stable "<id>"` /
    ## `scope workspace`, which L4 added) and travel through the real
    ## interface lift, so `repro up` reads them from the lifted row. An
    ## earlier draft of this block carried them as JSON keys and was
    ## wrong for a reason worth recording: a recipe would then state its
    ## identity TWICE, the two statements could disagree, and the one
    ## that decided which instance a consumer reached would be the JSON
    ## one — so the `service` block's `identity stable` would become
    ## decoration. `identity` and `scope` are therefore REFUSED BY NAME
    ## here, which is the opposite of ignoring them.
    ##
    ## Every field is parsed by `parseSharedServiceInstance`, which
    ## REFUSES an unrecognised key by name rather than ignoring it.
    declared*: bool
      ## False when the service metadata carried no `instance` block at
      ## all, which is the ordinary session-owned service.
    serviceName*: string
    environment*: string
    leaseTtlSeconds*: int64
      ## The holder's lease policy in the daemon wire encoding (negative
      ## = `keep`, 0 = `immediate`, positive = `delayed(n)`). Defaults to
      ## `keep`; see `SharedServiceInstanceDefaultTtlSeconds`.
      ##
      ## THE INTERFACE SNAPSHOT IS NOT HERE, and that is deliberate. §4.3
      ## decides attach-or-refuse on the service's LIFTED interface
      ## fingerprint, and the honest source of that is the project
      ## interface artifact `repro up` has already produced
      ## (`DevEnvEdgeResult.interfacePath`) -- not this metadata blob. A
      ## snapshot carried here would be a second, author-maintained copy
      ## of a lift output; a snapshot INVENTED from the argv would warn on
      ## an implementation-only change, which §4.3 forbids in the one
      ## control L6's gate names. So `repro up` reads it from the lift by
      ## the service's name, and a service that declares an `instance`
      ## but is not in the lift is a named refusal
      ## (`serviceInterfaceSnapshot` already lists what the lift does
      ## declare).

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

  DevSessionStopBudget* = object
    ## How long ``repro down`` will wait for the session it asked to stop to
    ## report ``down``, and WHERE that number came from. Same shape and same
    ## reason as ``DevSessionReadyBudget``, deliberately not the same type:
    ## the two derivations read different declarations and the two
    ## diagnostics name different flags, so sharing one object would make
    ## ``describe`` lie about one of them.
    timeoutMs*: int
    explicit*: bool       ## true when ``--stop-timeout`` set ``timeoutMs``.
    derivedMs*: int       ## what the session's live services derive, always.

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

  DevSessionServiceStopGraceMs* = 3000
    ## The grace ONE service gets between ``terminate()`` and ``kill()`` in
    ## ``stopService``. It was an unnamed ``3000`` in that loop; naming it is
    ## what lets ``repro down``'s wait be derived from the number the
    ## supervisor actually honours instead of from a second, unrelated
    ## constant that nothing keeps in step with it.
    ##
    ## THIS IS NOT A DECLARED BUDGET, and the difference matters when
    ## reading ``derivedStopTimeoutMs``. On the start side each service
    ## declares its own ``readiness.timeoutMs`` in its supervisor metadata,
    ## so the parent's wait is derived from what the SERVICES say. Nothing
    ## in the service metadata schema says anything about stopping -- there
    ## is no ``shutdown``, no ``stop.timeoutMs``, no per-service grace --
    ## so the only honest source for a stop derivation is the supervisor's
    ## own behaviour, which is this constant.

  DevSessionStopMarginMs* = 10_000
    ## Added ONCE to the per-service stop grace total to get ``repro
    ## down``'s wait. It pays for the work the stop does that no service
    ## accounts for: the control API's write of ``stop.request.json``, the
    ## supervisor noticing it (up to 100 ms of its own poll in ``up`` mode),
    ## the ``waitForExit`` and ``close`` after each ``kill``, the
    ## ``writeState`` + ``emitEvent`` pair per service, and ``repro down``'s
    ## own 100 ms poll granularity.
    ##
    ## 10_000 for the same reason ``DevSessionReadyMarginMs`` is 10_000: a
    ## session with NO services derives exactly the margin, and ten seconds
    ## is the wait ``repro down`` had before it derived anything at all, so
    ## no stack gets a shorter wait than the one it has today.

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

const
  SharedServiceInstanceDefaultTtlSeconds* = SharedServiceInstanceKeepTtlSeconds
    ## D-SS5, DECIDED HERE: a shared development service instance's
    ## holder takes a `keep` lease by default (`-1` is the wire spelling
    ## of `keep`).
    ##
    ## The open decision asked for "reap semantics for a `stable`,
    ## state-owning service" and expected `keep`: "`delayed(ttl)` would
    ## destroy exactly the state `stable` exists to preserve". That is
    ## the choice taken, and the cost is named rather than hidden: a
    ## `keep` holder's consumer id is not written into a lease record
    ## (`mergeHolderDeadlines` drops it), so a daemon restart cannot
    ## enumerate the holders of an instance held only by `keep` holders,
    ## and §4.5 rule 1 then REFUSES `--replace` and refuses to decide a
    ## release. That refusal is the designed behaviour of the default,
    ## not a surprise: the alternative — a dated default — trades a
    ## refusal for a reaped database.
    ##
    ## A recipe that wants the other trade declares `"lease": "delayed",
    ## "ttlSeconds": <n>` and gets a holder the rebuild can name.
    ##
    ## Shared-Development-Services L9: the number itself now lives at
    ## `repro_project_dsl`'s `SharedServiceInstanceKeepTtlSeconds`, so
    ## the typed `instance:` block's `lease keep` and this JSON block's
    ## default are one value rather than two that agree today.

  SharedServiceInstanceKeys = ["environment", "lease", "ttlSeconds"]
    ## The complete set of keys `instance` accepts. Enumerated so an
    ## unrecognised key is a REFUSAL: this campaign's dominant finding is
    ## "constructs that are declared, look wired, and are silently
    ## dropped", and a JSON block read with `node{"x"}` accessors drops
    ## every misspelling in silence. `"schemaid"` / `"Scope"` /
    ## `"enviroment"` all land here.

proc refuseInstanceDeclaration(serviceName, detail: string) {.noreturn.} =
  raise newException(ValueError,
    "service `" & serviceName & "`: the `instance` block of its " &
    "dev-session metadata " & detail)

proc parseSharedServiceInstance*(serviceName, metadataText: string):
    SharedServiceInstanceDeclaration =
  ## Parse the `instance` block out of one service's dev-session
  ## metadata. ONE implementation, exported, because `repro up`, `repro
  ## down` and the supervisor all have to agree about which services are
  ## daemon-owned — three readers of one JSON blob is how they stop
  ## agreeing.
  ##
  ## A service with no `instance` block yields `declared = false` and no
  ## error: that is every service that existed before L7.
  result = SharedServiceInstanceDeclaration(serviceName: serviceName,
    leaseTtlSeconds: SharedServiceInstanceDefaultTtlSeconds)
  let text = metadataText.strip()
  if text.len == 0:
    return
  let metadata =
    try:
      parseJson(text)
    except CatchableError as err:
      refuseInstanceDeclaration(serviceName,
        "could not be read because the metadata is not JSON: " & err.msg)
  if metadata.kind != JObject:
    return
  let node = metadata{"instance"}
  if node.isNil:
    return
  if node.kind != JObject:
    refuseInstanceDeclaration(serviceName,
      "must be a JSON object; it is a " & $node.kind &
      ". A non-object `instance` is refused rather than ignored, " &
      "because ignoring it would leave the service session-owned while " &
      "its author believed it was shared.")
  result.declared = true
  # `identity` and `scope` are refused BEFORE the generic unknown-key
  # sweep below, so the message can say where they belong instead of
  # only that they are not accepted.
  #
  # THE ORDER IS LOAD-BEARING AND WAS MEASURED WRONG FIRST. With these
  # two checks placed after the sweep, the sweep refused them as ordinary
  # unknown keys and the two specific messages were UNREACHABLE -- a
  # construct that was declared, looked wired and did nothing, found by
  # the probe set in
  # `t_l7_shared_instance_declaration_refuses_near_misses.nim` and not by
  # reading the code.
  if node.hasKey("identity"):
    refuseInstanceDeclaration(serviceName,
      "declares `identity`. An instance's identity is declared on the " &
      "typed `service` block -- `identity stable \"<id>\"` " &
      "(Shared-Development-Services.md §4.2) -- and reaches `repro up` " &
      "through the interface lift. Declaring it here too would give one " &
      "service two answers to `are these the same instance?`, and the " &
      "JSON one would win, which would make the `service` block's " &
      "declaration decoration.")
  if node.hasKey("scope"):
    refuseInstanceDeclaration(serviceName,
      "declares `scope`. Like the identity, the scope is declared on " &
      "the typed `service` block (`scope project|workspace|user|" &
      "system`, §4.1) and read from the lift.")
  for key in node.keys:
    if SharedServiceInstanceKeys.find(key) < 0:
      refuseInstanceDeclaration(serviceName,
        "carries the key `" & key & "`, which nothing reads. The keys " &
        "it accepts are " & SharedServiceInstanceKeys.join(", ") &
        ". Refused rather than ignored: a key that parses and does " &
        "nothing is the silent drop this campaign exists to find.")
  let environmentNode = node{"environment"}
  if not environmentNode.isNil:
    if environmentNode.kind != JString:
      refuseInstanceDeclaration(serviceName,
        "declares `environment` as a " & $environmentNode.kind &
        "; it must be a string.")
    result.environment = environmentNode.getStr("").strip()
  let leaseNode = node{"lease"}
  if not leaseNode.isNil:
    if leaseNode.kind != JString:
      refuseInstanceDeclaration(serviceName,
        "declares `lease` as a " & $leaseNode.kind &
        "; it must be one of the words keep, immediate, delayed.")
    case leaseNode.getStr("").strip()
    # The CONSTANT here too: the default at the top of this proc already
    # uses it, so the explicit spelling of the same lease must not reach
    # the number by a different route.
    of "keep": result.leaseTtlSeconds = SharedServiceInstanceKeepTtlSeconds
    of "immediate": result.leaseTtlSeconds = 0'i64
    of "delayed":
      let ttl = node{"ttlSeconds"}
      if ttl.isNil or ttl.kind != JInt or ttl.getBiggestInt(0) <= 0:
        refuseInstanceDeclaration(serviceName,
          "declares `lease: \"delayed\"` without a positive " &
          "`ttlSeconds`. A delayed lease with no ttl is an immediate " &
          "one wearing the wrong name.")
      result.leaseTtlSeconds = int64(ttl.getBiggestInt(0))
    else:
      refuseInstanceDeclaration(serviceName,
        "declares `lease: \"" & leaseNode.getStr("") & "\"`, which is " &
        "not one of keep, immediate, delayed.")
  if node.hasKey("ttlSeconds") and result.leaseTtlSeconds <= 0:
    # `ttlSeconds` is read ONLY by `lease: "delayed"`. Anywhere else it
    # parses, looks effective and is read by nothing -- including beside
    # an explicit `lease: "keep"`, which is the spelling that slipped
    # through the first draft of this guard: it checked only for a
    # MISSING `lease`, so `{"lease":"keep","ttlSeconds":3600}` was
    # accepted and the number silently ignored. Measured by this
    # milestone's own probe set, which is the point of having one.
    refuseInstanceDeclaration(serviceName,
      "declares `ttlSeconds`, which is read only by `lease: " &
      "\"delayed\"`. The lease here is " &
      (if node.hasKey("lease"): "`" & node{"lease"}.getStr("") & "`"
       else: "the default, `keep`") &
      ", which has no deadline, so the ttl would be read by nothing.")

proc sharedServiceInstanceOf*(service: DevEnvServiceSummary):
    SharedServiceInstanceDeclaration =
  ## The declaration of one dev-env service. The single entry point every
  ## caller uses, so `repro up`, `repro down` and the supervisor cannot
  ## read the blob differently.
  ##
  ## Shared-Development-Services L9: it now reads TWO lanes, and the
  ## JSON one is the only one read when the typed block is SILENT --
  ## which is not the same as winning where both speak, because where
  ## both speak this proc REFUSES (see the paragraph below; an earlier
  ## version of this sentence said "wins", which is true of the
  ## `command` and false of `instance`). The typed `instance:` block is
  ## what lets `infra/repro.nim` delete its `servicePlaceholder`; the
  ## JSON block is what every recipe written before L9 has, and
  ## preferring the typed side would change which services the daemon
  ## owns in a recipe nobody edited.
  ##
  ## BOTH DECLARING IT IS A REFUSAL rather than a precedence decision,
  ## for `serviceSpecFromSummary`'s readiness reason: the loser decides
  ## whether a state-owning service is reaped, and "the one the author
  ## wrote in the other file" is not an answer anybody can read off the
  ## recipe.
  result = parseSharedServiceInstance(service.name, service.metadataText)
  if not service.instanceDeclared:
    return
  if result.declared:
    refuseInstanceDeclaration(service.name,
      "is declared TWICE -- once as the `instance` key of the " &
      "`servicePlaceholder`'s metadata and once as the typed `service` " &
      "block's `instance:` block. One service cannot have two leases " &
      "and two environments; whichever lost would be the one deciding " &
      "whether this instance's state is reaped. Delete the " &
      "placeholder's `instance` key -- the typed block is the surface " &
      "that makes a shared service declarable once.")
  result.declared = true
  result.leaseTtlSeconds = service.instanceLeaseTtlSeconds
  # DERIVED at evaluation, carried here. The typed `instance:` block
  # refuses an `environment` setting by name, so this is the only
  # answer, which is the point: §6.4 makes the selection a tracked
  # input and §6.5 makes it part of the instance key, and a recipe that
  # could also write the name would be a second answer able to disagree
  # with the selection under which the artifact was evaluated.
  result.environment = service.instanceEnvironment

proc sharedServiceInstancesOf*(artifact: DevEnvArtifact):
    seq[SharedServiceInstanceDeclaration] =
  ## Every shared-instance declaration in one dev-env artifact, in
  ## declaration order.
  result = @[]
  for service in artifact.services:
    let declaration = sharedServiceInstanceOf(service)
    if declaration.declared:
      result.add(declaration)

proc sharedServiceInstanceKey*(
    declaration: SharedServiceInstanceDeclaration;
    projectRoot: string;
    identity: ServiceIdentityDef;
    scope: ServiceScope): ServiceInstanceKey =
  ## The `(identity, scope, environment)` key, through the REAL
  ## `serviceInstanceKey` over the REAL `discoverServiceScopeContext` —
  ## so the scope resolution, including its two reported degradations, is
  ## L4's and not a second copy.
  ##
  ## `identity` and `scope` come from the LIFTED service row (see the
  ## declaration type's note on why they are not in the JSON), and
  ## `environment` from the declaration. The `DslServiceDef` assembled
  ## here carries only the fields `serviceIdentity` reads for a
  ## `sikStable` service: the package and service names, which appear
  ## only in its refusal message, and the identity itself. That is safe
  ## ONLY because a `derived` identity is refused by the caller --
  ## `derivedServiceIdentity` reads `executable`, `args` and the
  ## rendered outputs, and a dev-session declaration carries none of
  ## them as outputs. A caller that forgot that refusal would get a
  ## digest over an empty definition, which every service would share.
  if identity.kind != sikStable:
    refuseInstanceDeclaration(declaration.serviceName,
      "names a service whose declared identity is `derived`. A DERIVED " &
      "identity is a digest of the service's materialised definition " &
      "(Shared-Development-Services.md §4.2) -- the executable, the " &
      "rendered configuration outputs, the arguments -- and `repro up`'s " &
      "dev-session path has no materialised closure here to digest, so " &
      "resolving one would invent a second, disagreeing answer to " &
      "`what is this service's identity`. Declare `identity stable " &
      "\"<id>\"` on the `service` block, which §4.2 requires of a " &
      "service that owns durable state anyway.")
  serviceInstanceKey(
    DslServiceDef(
      packageName: "dev-session",
      serviceName: declaration.serviceName,
      identity: identity,
      scope: scope),
    discoverServiceScopeContext(projectRoot),
    environment = declaration.environment)

const
  MintedAttributeTokenPrefix* = "@minted:"
  MintedAttributeTokenSuffix* = "@"
    ## Shared-Development-Services L8: the argv token a consuming
    ## service writes for a value the shared instance MINTS.
    ##
    ## §9.3's worked example writes the value as a staged member
    ## expression -- `sso.relyingParty("isonim-site").clientId`. That
    ## spelling needs a typed handle member on the lifted interface,
    ## which does not exist (L3 lifted the service's SIGNATURE, not a
    ## member accessor). So the token is the shape the lane carries
    ## today, and it is a TOKEN rather than an environment variable for
    ## the reason §7 gives: "argv is concretized late, and a resource
    ## attribute computed during reconciliation is available before an
    ## edge that depends on that resource runs" -- which is the whole
    ## argument for deleting a wrapper that sources a file at process
    ## start.
    ##
    ## AN UNRESOLVED TOKEN IS A REFUSAL. Left verbatim it would reach
    ## the service as the literal text `@minted:isonim-site@`; emptied
    ## it would reach it as `""`, which D-SS10 names as "the one answer
    ## that must not be chosen". Both are silent; the refusal is not.
  SharedInstanceMintedFile* = "shared-instance-registrations.json"
  SharedInstanceMintedSchemaId* =
    "reprobuild.dev-session.shared-instance-registrations.v1"

proc sharedInstanceMintedPath*(outDir: string): string =
  ## Where `repro up` records what the instance minted, for the
  ## supervisor child to read.
  ##
  ## A FILE OF ITS OWN rather than two more keys in the shared-instance
  ## LEDGER. The ledger exists so `repro down` can release exactly the
  ## holders this session took, and its schema id is checked on read; a
  ## session that crashed between the two writes must still be
  ## releasable, so the release record does not get a second
  ## responsibility.
  outDir.sessionDir / SharedInstanceMintedFile

proc writeSharedInstanceMinted*(outDir: string;
    entries: openArray[tuple[serviceName, member, mintedId: string]]) =
  createDir(extendedPath(outDir.sessionDir))
  var rows = newJArray()
  for entry in entries:
    rows.add(%*{"serviceName": entry.serviceName, "member": entry.member,
      "mintedId": entry.mintedId})
  let doc = %*{"schemaId": SharedInstanceMintedSchemaId}
  doc["registrations"] = rows
  writeFile(extendedPath(outDir.sharedInstanceMintedPath), $doc & "\n")

proc readSharedInstanceMinted*(outDir: string): Table[string, string] =
  ## The minted table, keyed `<serviceName>:<member>` and also by the
  ## bare `<member>`.
  ##
  ## BOTH KEYS, because a consuming service names the MEMBER it needs
  ## (`@minted:isonim-site@`) and does not generally know which shared
  ## service registered it; the qualified key exists so two shared
  ## services registering a member of the same name can still be
  ## addressed apart. A bare member registered by two services is
  ## recorded under the qualified keys only, so the bare form then
  ## resolves to nothing and the substitution REFUSES rather than
  ## picking one.
  result = initTable[string, string]()
  let path = outDir.sharedInstanceMintedPath
  if not fileExists(extendedPath(path)):
    return
  let doc = parseJson(readFile(extendedPath(path)))
  if doc.kind != JObject:
    raise newException(ValueError,
      "the shared-instance registration record at " & path &
      " is not a JSON object")
  if doc{"schemaId"}.getStr("") != SharedInstanceMintedSchemaId:
    raise newException(ValueError,
      "the shared-instance registration record at " & path &
      " carries schemaId `" & doc{"schemaId"}.getStr("") &
      "`; this build reads `" & SharedInstanceMintedSchemaId & "` only")
  let rows = doc{"registrations"}
  if rows.isNil or rows.kind != JArray:
    return
  var ambiguous: seq[string] = @[]
  for row in rows:
    if row.kind != JObject:
      continue
    let serviceName = row{"serviceName"}.getStr("")
    let member = row{"member"}.getStr("")
    let mintedId = row{"mintedId"}.getStr("")
    if member.len == 0 or mintedId.len == 0:
      continue
    result[serviceName & ":" & member] = mintedId
    if member in result and result[member] != mintedId:
      ambiguous.add(member)
    else:
      result[member] = mintedId
  for member in ambiguous:
    result.del(member)

proc substituteMintedAttributes*(serviceName: string;
                                 command: seq[string];
                                 minted: Table[string, string]):
                                 seq[string] =
  ## Replace every `@minted:<member>@` token in `command` with what the
  ## instance minted for that member.
  ##
  ## WHOLE-TOKEN ONLY, not a substring rewrite, and that is deliberate:
  ## a flag written `--client-id=@minted:x@` is a shape this does NOT
  ## resolve, and it is better to refuse it than to rewrite inside an
  ## argument where the author may have meant the text. The refusal
  ## names the token, so the author learns the shape rather than
  ## debugging an issuer error.
  for token in command:
    if not (token.startsWith(MintedAttributeTokenPrefix) and
            token.endsWith(MintedAttributeTokenSuffix) and
            token.len > MintedAttributeTokenPrefix.len +
              MintedAttributeTokenSuffix.len - 1):
      if token.contains(MintedAttributeTokenPrefix):
        raise newException(ValueError,
          "service `" & serviceName & "`: the argument `" & token &
          "` embeds a minted-attribute token inside a larger " &
          "argument. The token is resolved as a WHOLE argument only, " &
          "so write it as its own `args` element (`\"--client-id\", " &
          "\"" & MintedAttributeTokenPrefix & "<member>" &
          MintedAttributeTokenSuffix & "\"`). Rewriting inside an " &
          "argument would guess at text the author may have meant.")
      result.add(token)
      continue
    let member = token[MintedAttributeTokenPrefix.len ..
      token.len - MintedAttributeTokenSuffix.len - 1]
    let qualified = serviceName & ":" & member
    if minted.hasKey(qualified):
      result.add(minted[qualified])
    elif minted.hasKey(member):
      result.add(minted[member])
    else:
      var known: seq[string] = @[]
      for key in minted.keys:
        if ':' notin key:
          known.add(key)
      known.sort()
      # D-SS10 (§7.1) requires an early read to report WHICH ATTRIBUTE,
      # WHICH RESOURCE and WHICH EDGE would have ordered it. All three
      # are named below. Before §7.1 this refusal named the member and
      # the registered set, which told the author what was missing but
      # not what was supposed to have produced it -- and "what orders
      # this" is the question an author reading it is actually asking.
      raise newException(ValueError,
        "service `" & serviceName & "`: the resource attribute `" &
        ClientIdAttributeName & "` of " &
        registrationResourceLabel(serviceName, member) &
        " IS NOT COMPUTED, so the argument `" & token &
        "` cannot be concretized. That attribute is computed when the " &
        "registration resource reconciles, and the edge that orders " &
        "the reconcile before this read is " &
        registrationOrderingEdgeOfService(serviceName) &
        ". A shared service registers a member only if its `service` " &
        "block `converge`s the contribution point that member was " &
        "contributed to, and only once `repro up` has converged that " &
        "instance. Registered members: " &
        (if known.len == 0: "(none)" else: known.join(", ")) &
        ". Leaving the token verbatim or substituting an empty string " &
        "would reach the service as a credential it cannot use: an " &
        "empty string is indistinguishable from a legitimately empty " &
        "value, which is the one answer " &
        "Shared-Development-Services.md D-SS10 forbids.")

proc serviceSpecFromSummary*(projectRoot: string;
                             service: DevEnvServiceSummary;
                             minted = initTable[string, string]()):
                             ServiceSpec =
  result.name = service.name
  result.readinessKind = "none"
  result.readinessTimeoutMs = DefaultServiceReadinessTimeoutMs
  let text = service.metadataText.strip()
  # Shared-Development-Services L9: EMPTY METADATA IS NO LONGER A
  # REFUSAL, and that one line is what makes the gate's "declared once"
  # reachable rather than only describable.
  #
  # Before this, a service declared ONLY as a typed `service` block
  # raised here -- `mergeTypedServiceFacts` appends such a service with
  # `metadata: ""` -- so every recipe that wanted a supervised service
  # still had to write a `servicePlaceholder`, whatever the typed block
  # carried. L8 gave the record its fields; this gives the reader a
  # route that does not need the JSON at all.
  #
  # A SERVICE THAT DECLARED NEITHER IS STILL REFUSED, by the command
  # check below, and the message names both halves.
  let metadata =
    if text.len == 0:
      newJObject()
    else:
      parseJson(text)
  if text.len > 0 and metadata.kind != JObject:
    raise newException(ValueError,
      "service " & service.name & ": its supervisor metadata is a " &
      $metadata.kind & " rather than a JSON object. Refused rather " &
      "than treated as absent, because treating it as absent would " &
      "silently fall through to the typed `service` block's facts and " &
      "supervise something the author did not write.")
  result.command = metadata{"command"}.stringArray()
  if result.command.len == 0:
    # Shared-Development-Services L8: fall back to the TYPED `service`
    # block's own command, which now reaches this record.
    #
    # THE FALLBACK IS ONE-WAY AND THE DIRECTION MATTERS. A placeholder
    # that states a command keeps stating it, because a recipe carrying
    # both is a recipe mid-migration and silently preferring the typed
    # one would change what it runs. A placeholder that states NONE now
    # has somewhere to get one, which is what makes a service declarable
    # once.
    result.command = service.typedCommand
  if result.command.len == 0:
    raise newException(ValueError,
      "service " & service.name & " declares no command: its " &
      "supervisor metadata has no `command` and its typed `service` " &
      "block declares no `executable` either. One of the two has to " &
      "say what to run." &
      (if text.len == 0:
         " This service has no `servicePlaceholder` at all, so the " &
         "typed block is the only source: give it an `executable`."
       else: ""))
  # Shared-Development-Services L8: argv is concretized LATE, and this
  # is where late is. Every `@minted:<member>@` token becomes the
  # identifier the shared instance minted when the registration
  # reconciled -- which happened in `repro up` before the supervisor was
  # launched, i.e. before this runs.
  result.command = substituteMintedAttributes(service.name,
    result.command, minted)
  # Shared-Development-Services L9: `cwd` falls back to the typed
  # `workingDirectory`, through ONE relative-path resolution against the
  # project root rather than two. `sharedServiceInstanceLaunch` reuses
  # this proc precisely so the daemon and the supervisor resolve the
  # same bytes; a second resolution here would reintroduce the split it
  # was written to close.
  result.cwd = metadata{"cwd"}.getStr("")
  if result.cwd.len == 0:
    result.cwd = service.workingDirectory
  if result.cwd.len == 0:
    result.cwd = projectRoot
  elif not result.cwd.isAbsolute:
    result.cwd = projectRoot / result.cwd
  result.dependsOn = metadata{"dependsOn"}.stringArray()
  let placeholderReadiness =
    metadata.hasKey("readiness") and metadata["readiness"].kind == JObject
  # BOTH SIDES DECLARING A PROBE IS A REFUSAL, not a precedence
  # decision, and it is the one place L9 does NOT copy L8's one-way
  # fallback. L8's reasoning for preferring the placeholder's COMMAND
  # was that a recipe carrying both is mid-migration and a silent switch
  # would change what it runs. For readiness the same silence has a
  # worse outcome: the losing probe is the one the author wrote LAST,
  # and a dependent then starts against an instance that is listening
  # and not seeded. There is no reading of two probes that is safe, so
  # the author is asked which one they meant.
  if placeholderReadiness and service.readinessKind.len > 0:
    raise newException(ValueError,
      "service `" & service.name & "`: a readiness probe is declared " &
      "TWICE -- once in the `servicePlaceholder`'s metadata (`" &
      metadata["readiness"]{"kind"}.getStr("") & "`) and once on the " &
      "typed `service` block (`readiness " & service.readinessKind &
      "`). One service cannot have two answers to \"when is this " &
      "ready\": whichever lost would be the probe a dependent does " &
      "NOT wait on, and a dependent that starts against a listening " &
      "but unseeded instance fails intermittently rather than loudly. " &
      "Delete the placeholder's `readiness` block -- the typed setter " &
      "is the surface Shared-Development-Services.md §9.1 writes.")
  if placeholderReadiness:
    let readiness = metadata["readiness"]
    result.readinessKind = readiness{"kind"}.getStr("none")
    result.readinessPath = readiness{"path"}.getStr("")
    if result.readinessPath.len > 0 and not result.readinessPath.isAbsolute:
      result.readinessPath = projectRoot / result.readinessPath
    result.readinessUrl = readiness{"url"}.getStr("")
    result.readinessTimeoutMs = readiness{"timeoutMs"}.getInt(
      DefaultServiceReadinessTimeoutMs)
  elif service.readinessKind.len > 0:
    # The typed probe. The WORD is checked here rather than trusted,
    # for `summaryDeclaredIdentityAndScope`'s reason: `readinessOk`
    # reports an unrecognised kind as NEVER READY, so a kind this build
    # does not know would hang the session until its timeout with
    # nothing said.
    case service.readinessKind.normalize()
    of "none", "fileexists", "httpget":
      result.readinessKind = service.readinessKind
    else:
      raise newException(ValueError,
        "service `" & service.name & "`: the dev-env artifact records " &
        "the readiness kind `" & service.readinessKind & "`, which is " &
        "not a kind this build knows (`none`, `fileExists`, " &
        "`httpGet`). Reading it as `none` would report the service " &
        "ready as soon as it is spawned; reading it as anything else " &
        "would hang the session until its timeout. Both are silent.")
    result.readinessPath = service.readinessPath
    if result.readinessPath.len > 0 and not result.readinessPath.isAbsolute:
      result.readinessPath = projectRoot / result.readinessPath
    result.readinessUrl = service.readinessUrl
    result.readinessTimeoutMs =
      if service.readinessTimeoutMs > 0:
        int(service.readinessTimeoutMs)
      else:
        DefaultServiceReadinessTimeoutMs
  if metadata.hasKey("resources") and metadata["resources"].kind == JArray:
    for item in metadata["resources"]:
      if item.kind != JObject:
        continue
      var path = item{"path"}.getStr("")
      if path.len > 0 and not path.isAbsolute:
        path = projectRoot / path
      result.resources.add((kind: item{"kind"}.getStr("directory"),
        path: path))
  # L9: the typed `stateDirectory` setters are APPENDED to whatever the
  # placeholder declared rather than replacing it. `resources` is a
  # LIST, and both lanes name directories to create: a service
  # mid-migration that declared one of each must get both, and creating
  # a directory twice is idempotent where failing to create one is not.
  for dir in service.stateDirectories:
    if dir.len == 0:
      continue
    var path = dir
    if not path.isAbsolute:
      path = projectRoot / path
    var seen = false
    for existing in result.resources:
      if existing.path == path:
        seen = true
    if not seen:
      result.resources.add((kind: "directory", path: path))

proc summaryDeclaredIdentityAndScope*(
    service: DevEnvServiceSummary):
    tuple[declared: bool; identity: ServiceIdentityDef;
          scope: ServiceScope] =
  ## Shared-Development-Services L8: the typed `service` block's
  ## identity and scope, read from the record they NOW reach.
  ##
  ## This is the channel L7's review said did not exist -- "there is no
  ## field an identity or a scope could travel in, so no amount of
  ## routing on the PRODUCING side closes it; the typed interface has to
  ## reach the CONSUMING path first". It reaches it here.
  ##
  ## `declared == false` means the record carries the empty string,
  ## which is what a provider built before the field existed reports.
  ## The caller then falls back to the interface lift, so nothing that
  ## worked at L7 stops working.
  ##
  ## AN UNKNOWN WORD IS A REFUSAL, NOT A DEFAULT. `scope: "workspce"`
  ## must not read as `project` -- that is a narrower sharing boundary
  ## than the author asked for, silently, which is the exact failure
  ## §4.4 and L4's degradation report exist to prevent.
  if service.identityKind.len == 0 and service.scope.len == 0:
    return (declared: false, identity: ServiceIdentityDef(kind: sikDerived,
      stableId: ""), scope: sscProject)
  var identity = ServiceIdentityDef(kind: sikDerived, stableId: "")
  case service.identityKind
  of "", "derived": identity.kind = sikDerived
  of "stable":
    identity.kind = sikStable
    identity.stableId = service.identityStableId
  else:
    raise newException(ValueError,
      "service `" & service.name & "`: the dev-env artifact records " &
      "the identity kind `" & service.identityKind & "`, which is not " &
      "a kind this build knows (`derived` or `stable`). Reading it as " &
      "a default would silently pick an instance key the recipe did " &
      "not declare.")
  var scope = sscProject
  case service.scope
  of "", "project": scope = sscProject
  of "workspace": scope = sscWorkspace
  of "user": scope = sscUser
  of "system": scope = sscSystem
  else:
    raise newException(ValueError,
      "service `" & service.name & "`: the dev-env artifact records " &
      "the scope `" & service.scope & "`, which is not a scope this " &
      "build knows (`project`, `workspace`, `user`, `system`). " &
      "Reading it as `project` would narrow the sharing boundary the " &
      "recipe declared, silently.")
  (declared: true, identity: identity, scope: scope)

proc appendSessionEvent*(outDir: string; kind, service, detail: string) =
  ## Append one event to the dev session's OWN `events.jsonl`, in the
  ## same schema the supervisor's `emitEvent` writes.
  ##
  ## Shared-Development-Services D-SS10 (§7.1). `emitEvent` is bound to a
  ## live `SessionState`, and the ordering D-SS10 establishes happens
  ## BEFORE the supervisor exists: `repro up` converges the shared
  ## instance, waits for its declared readiness and reconciles the
  ## registration, and only then launches the supervisor. Those three
  ## facts have to land in the same append-only log as the supervisor's,
  ## because a reader asking "did the registration wait for readiness"
  ## should not have to join two files on timestamps.
  ##
  ## ONE SCHEMA ID, not a second one. A reader (or a test) that knows
  ## `reprobuild.dev-session.event.v1` must be able to read these rows,
  ## and giving the pre-supervisor rows their own id would make every
  ## such reader wrong by omission.
  ##
  ## `sessionId` is empty here and that is honest: the session does not
  ## have one until the supervisor publishes it. An invented id would be
  ## a value no other surface agrees with.
  let node = %*{
    "schemaId": EventSchemaId,
    "time": nowIso(),
    "sessionId": "",
    "kind": kind,
    "service": service,
    "watchPath": "",
    "detail": detail,
    "cycle": 0
  }
  createDir(extendedPath(outDir.sessionDir))
  let path = outDir.sessionDir / EventLogFile
  let line = $node & "\n"
  if fileExists(extendedPath(path)):
    writeFile(extendedPath(path), readFile(extendedPath(path)) & line)
  else:
    writeFile(extendedPath(path), line)

proc sessionEventLogPath*(outDir: string): string =
  ## Where `appendSessionEvent` writes, and where the supervisor's
  ## `emitEvent` writes. Exported so a caller does not have to
  ## reconstruct `session/events.jsonl` from two constants.
  outDir.sessionDir / EventLogFile

proc sharedServiceInstanceLaunch*(projectRoot: string;
    service: DevEnvServiceSummary):
    tuple[command: seq[string]; workingDir: string;
          readinessKind, readinessPath, readinessUrl: string;
          readinessTimeoutMs: int] =
  ## The argv, working directory AND DECLARED READINESS a shared instance
  ## is materialised with, read through the SAME `serviceSpecFromSummary`
  ## the supervisor uses for a session-owned service.
  ##
  ## Reused rather than re-parsed so that the command the daemon runs and
  ## the command the supervisor would have run are the same bytes,
  ## including the `cwd` resolution against the project root. Two readers
  ## of `{"command": [...]}` is how an instance gets started with a
  ## relative path one of them resolved and the other did not.
  ##
  ## THE READINESS FIELDS ARE D-SS10's (§7.1), AND THEIR ABSENCE HERE WAS
  ## A SILENT DROP. Before they were added, this proc returned the
  ## command and the working directory only, and
  ## `serviceSpecsFromArtifact` skips every service with an `instance:`
  ## block — so a typed `readiness httpGet(...)` on a SHARED service was
  ## parsed, validated, carried through the artifact at envelope 4,
  ## printed by `repro dev-env --json`, and then probed by nothing at
  ## all. The declared fact existed and no code read it. They are
  ## returned from THIS proc rather than re-read at the call site for the
  ## reason the paragraph above gives: one reading of one declaration.
  let spec = serviceSpecFromSummary(projectRoot, service)
  (command: spec.command, workingDir: spec.cwd,
   readinessKind: spec.readinessKind, readinessPath: spec.readinessPath,
   readinessUrl: spec.readinessUrl,
   readinessTimeoutMs: spec.readinessTimeoutMs)

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

proc serviceSpecsFromArtifact(artifact: DevEnvArtifact;
                              minted = initTable[string, string]()):
                              seq[ServiceSpec] =
  ## Shared-Development-Services L7 (§4.5): a service that declares an
  ## `instance` block is NOT started by this session. It is materialised
  ## once, by the daemon, under its `(identity, scope, environment)` key,
  ## and this session holds a reference-counted lease on it.
  ##
  ## THE SKIP IS HERE, IN THE ONE PLACE THE SPEC LIST IS BUILT, and that
  ## is deliberate: `serviceSpecsFromArtifact` feeds the start order, the
  ## readiness budget (`derivedReadyTimeoutMs`), the stop sequence and
  ## the published session state, so skipping anywhere downstream would
  ## leave a session waiting for the readiness of a service it never
  ## started. A session that started its own copy would also defeat the
  ## whole design: three projects would run three instances while the
  ## registry recorded one.
  var specs: seq[ServiceSpec] = @[]
  for service in artifact.services:
    if sharedServiceInstanceOf(service).declared:
      continue
    specs.add(serviceSpecFromSummary(artifact.projectRoot, service,
      minted))
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
  # Shared-Development-Services L9: THE TYPED TIMEOUT IS READ HERE TOO,
  # and leaving it out was a real silent drop found by going looking
  # rather than by a failure.
  #
  # This proc sizes the PARENT's wait (`derivedReadyTimeoutMs`), while
  # `serviceSpecFromSummary` sizes the SUPERVISOR's. A typed service
  # declaring `timeoutMs = 600000` would have been supervised for ten
  # minutes and waited on by its parent for ninety seconds plus the
  # margin — so `repro up` would have abandoned a healthy first boot and
  # reported failure, which is the defect
  # `issues/2026-10-04-repro-up-abandons-any-service-slower-than-ten-
  # seconds.md` describes, reintroduced through the new channel. Two
  # readers of one declaration is how they stop agreeing; this is the
  # second reader, reading the same two lanes in the same order.
  if service.readinessKind.len > 0 and service.readinessTimeoutMs > 0:
    result = int(service.readinessTimeoutMs)
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
  # Shared-Development-Services L7 (§4.5): a service that declares an
  # `instance` block is EXCLUDED, and the exclusion is load-bearing
  # rather than tidy. The supervisor does not start it
  # (`serviceSpecsFromArtifact` skips it), so its declared readiness
  # timeout is not time the supervisor can spend -- counting it would
  # make the parent wait for a service nothing is waiting on, which is
  # the SAME disagreement-between-two-processes-about-a-duration defect
  # the derivation itself replaced, pointing the other way. The two
  # skips read the ONE declaration parser so they cannot disagree about
  # which services those are.
  var declared = 0
  for service in artifact.services:
    if sharedServiceInstanceOf(service).declared:
      continue
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

proc derivedStopTimeoutMs*(metadata: JsonNode): int =
  ## ``repro down``'s wait, DERIVED from the services the session says it is
  ## running rather than fixed at ten seconds.
  ##
  ## THE DERIVATION IS NOT THE START-SIDE ONE, and copying that one would
  ## have been wrong twice over. ``derivedReadyTimeoutMs`` sums what each
  ## service DECLARES it needs to become ready; nothing in the service
  ## metadata schema declares anything about stopping, so there is no
  ## equivalent declaration to sum -- see ``DevSessionServiceStopGraceMs``.
  ## And the two numbers are about different work: a service that takes ten
  ## minutes to warm a cache still dies on the first SIGTERM.
  ##
  ## So the number comes from what ``stopServices`` ACTUALLY DOES. It walks
  ## the service list in reverse, one at a time -- ``for i in
  ## countdown(...): state.stopService(i)`` -- and each ``stopService``
  ## allows ``DevSessionServiceStopGraceMs`` between ``terminate()`` and
  ## ``kill()``. The sum, not the maximum, for exactly the reason the start
  ## side sums: the stops are SEQUENTIAL, so three services that each take
  ## the full grace cost three graces end to end, and a waiter given one
  ## grace plus margin would abandon the third while the supervisor was
  ## still legitimately working through it.
  ##
  ## Read from ``session.json``'s ``services`` array, which is the LIVE
  ## service set rather than the declared one. That is the right list here
  ## and the wrong one on the start side, because ``startServices`` is
  ## sequential: the array only ever holds the services startup REACHED, so
  ## a session that declares four and died on its second derives two graces
  ## rather than four, and ``repro down`` does not hold a wait open for
  ## services that were never reached at all.
  ##
  ## It is a CEILING, not a census, and the one place it over-counts is
  ## worth naming because the obvious reading of "live" is wrong there.
  ## ``startService`` appends its ``ServiceRuntime`` and writes state BEFORE
  ## ``startProcess``, so a service whose spawn raised is in the array with
  ## no process. ``stopService`` returns immediately on such an entry
  ## (``runtime.process.isNil``), so it costs no grace while still being
  ## counted -- the derivation is long by one grace, never short, and the
  ## loop returns the moment the status reads ``down``.
  ##
  ## Metadata without a readable ``services`` array derives the bare margin,
  ## which is the ten seconds this wait used to be.
  ##
  ## The nil checks are load-bearing, not defensive noise. ``{}`` returns a
  ## NIL ``JsonNode`` for a key that is not there, and ``kind`` is a plain
  ## field on a ``ref`` -- so ``metadata{"services"}.kind`` SEGVs on a
  ## ``session.json`` that carries no ``services`` key, which is a file a
  ## reader can legitimately meet (a hand-edited session directory, a
  ## truncated write by an older build). ``getStr``/``getInt`` are nil-safe
  ## and ``kind`` is not; the difference is easy to miss because every
  ## other read in this module goes through the safe ones. Measured: a
  ## one-line Nim program doing ``parseJson("""{"a":1}"""){"services"}.kind``
  ## dies with ``SIGSEGV: Illegal storage access``.
  var services = 0
  if not metadata.isNil:
    let list = metadata{"services"}
    if not list.isNil and list.kind == JArray:
      services = list.len
  services * DevSessionServiceStopGraceMs + DevSessionStopMarginMs

proc stopBudget*(metadata: JsonNode; explicitMs: int): DevSessionStopBudget =
  ## ``explicitMs`` is ``--stop-timeout`` in milliseconds, or 0 when the user
  ## did not pass it.
  ##
  ## An explicit value WINS, for the reason ``readyBudget`` gives, and the
  ## flag exists at all because a derived default demonstrably cannot cover
  ## every stack. In ``dev`` mode the supervisor's stop is not bounded by the
  ## graces this derives from: the watch loop only tests ``stopRequested()``
  ## between cycles, so a stop that arrives while a watch task is running
  ## waits for that task, and a watch task is an arbitrary user command.
  ## Deriving a wait from the supervisor's own per-service graces is right
  ## for what the supervisor does once it has STARTED stopping; nothing in
  ## this module can bound the time until it starts. A caller who knows
  ## their stack needs longer -- or a CI step that must not hang -- has to
  ## be able to say so.
  ##
  ## IN ``dev`` MODE TODAY THE FLAG CANNOT RESCUE THE STOP, and that is a
  ## filed defect rather than a property of this derivation, so do not read
  ## the paragraph above as "raise it and a dev session will stop". The
  ## stop request lives under ``.repro``, which
  ## ``watch.nim``'s ``isNonSourceOrIgnoredPath`` discards, so the watch
  ## loop is never woken BY it: only an unrelated source edit gets it to
  ## the ``stopRequested()`` check. No finite wait covers that. See
  ## ``reprobuild-specs`` issue
  ## ``2026-10-10-a-repro-dev-session-cannot-be-stopped-by-repro-down``;
  ## it is also the deterministic cause of this suite's one red case.
  let derived = metadata.derivedStopTimeoutMs()
  if explicitMs > 0:
    DevSessionStopBudget(timeoutMs: explicitMs, explicit: true,
      derivedMs: derived)
  else:
    DevSessionStopBudget(timeoutMs: derived, explicit: false,
      derivedMs: derived)

proc describe*(budget: DevSessionStopBudget): string =
  ## One clause naming the wait and whose it is, read by both the
  ## announcement ``repro down`` prints before waiting and the diagnostic it
  ## prints if the wait expires, so the two cannot disagree.
  if budget.explicit:
    $budget.timeoutMs & " ms (--stop-timeout; the session's live services " &
      "would derive " & $budget.derivedMs & " ms)"
  else:
    $budget.timeoutMs & " ms (derived: " &
      $((budget.derivedMs - DevSessionStopMarginMs) div
        DevSessionServiceStopGraceMs) &
      " live service(s) x " & $DevSessionServiceStopGraceMs &
      " ms stop grace + " & $DevSessionStopMarginMs &
      " ms margin; override with --stop-timeout=MS)"

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
  ##   running": see the FOUR sites where that exception is built, one in
  ##   phase 1 and three at the end, and the paragraph above the last three
  ##   for which of them a real session can reach.
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
        # WHAT THIS ARM OBSERVED: that ``http-ready.json`` is absent. That
        # is the whole of it. No bind has been published, so no status has
        # been read -- and none COULD be, because there is no address to
        # read one from.
        #
        # So this message does not say "the session was left running",
        # which is what it said when the readiness work landed. That is a
        # claim about a process this arm has no witness for, and it is the
        # same unfounded assertion the expiry diagnostic below had removed
        # from it (see the comment there) -- reintroduced one phase
        # earlier. ``startBackgroundSupervisor`` does not license it
        # either: on POSIX it checks ``execShellCmd`` of a command whose
        # last token is ``&``, so the shell reports 0 as soon as the job is
        # BACKGROUNDED. A ``publicCliPath`` that does not exist, a
        # supervisor that aborts in its first millisecond, and a supervisor
        # that is alive and slow are indistinguishable from that exit code.
        # It is a launch check, not a liveness check.
        #
        # What is left is the narrower statement that is true in every
        # arm -- this process stopped nothing -- plus the one artifact that
        # can say what the supervisor did, which is its log.
        raise newException(DevSessionStillStartingError,
          "dev session is still starting: its control API had not published " &
            readyFile & " after the parent waited " &
            $int((now - started) * 1000.0) & " ms, so no session status " &
            "was read -- with no published bind there was no address to " &
            "read one from\n" &
            "  that wait was " & budget.describe() & "\n" &
            "  what the session is doing cannot be told from here; the " &
            "supervisor log is the place to look: " &
            (config.outDir.sessionDir / "supervisor.log") & "\n" &
            config.eventLogHint() & "\n" &
            "  this command stopped nothing, so a supervisor may still be " &
            "running: `repro down` stops it if it is, and a second `repro " &
            "up` would contend with it if it is")
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

  # WHAT THIS MESSAGE MAY ASSERT IS BOUNDED BY WHAT THE LOOP OBSERVED. Two
  # of the three arms below are things the loop can have seen through the
  # real CLI; the middle one is a DEFENSIVE GUARD against a reply this
  # module's own control API cannot produce, and saying so is the point of
  # this paragraph -- it used to claim all three were reachable.
  #
  # Why the middle arm is unreachable here. It needs ``/status`` to answer
  # 2xx with JSON whose ``status`` is absent or empty. The handler in this
  # file has exactly two answers: it serves ``session.json`` verbatim, or it
  # returns 404 when that file is missing. Every ``session.json`` this
  # module writes comes from ``stateJson``, which stamps ``"status":
  # state.status`` unconditionally, and ``state.status`` is already
  # ``"starting"`` at the first ``writeState()`` before the control-API
  # child is even spawned -- so a served body always carries a non-empty
  # status. The 404 raises in ``httpGetJson``, a torn read of the file
  # raises in ``parseJson``, and both land in the third arm via
  # ``controlApiStatus``'s ``nil``.
  #
  # It is KEPT rather than deleted, and the rule that condemned the
  # ``session.json`` fallback in ``controlApiStatus`` does not reach it. That
  # fallback could turn a failure into a SUCCESS -- exit 0 on a stale
  # file -- which is why an untested branch was not good enough for it. This
  # arm cannot: every path out of here raises. The worst a wrong guard can
  # do is word a diagnostic badly, and the thing it guards against is a
  # peer answering at the published bind that is not this module's control
  # API at all -- a port reused by something else, or a future second
  # implementation of ``/status``. Falling into the third arm's "every poll
  # failed" text there would be the false statement, since a poll did
  # succeed.
  #
  # The guard is covered by
  # ``e2e_dev_session_wait_reports_a_peer_that_publishes_no_status``, which
  # stands a real loopback server in front of a real session directory,
  # because an uncovered guard is indistinguishable from dead code.
  #
  # The version this replaces had one arm and asserted two facts it had not
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

proc readinessProbeSatisfied*(url: string): bool =
  ## The `httpGet` probe, as the resource lane's installed prober.
  ##
  ## This is `readinessOk`'s `httpget` arm, lifted to a named export so
  ## `repro_resources/readiness_edge.nim` can be handed THE SAME
  ## predicate the supervisor applies to a session-owned service. A
  ## second, slightly different notion of "the issuer is answering" is
  ## exactly the drift that made L9 refuse a probe declared in two
  ## lanes.
  if url.len == 0:
    return false
  try:
    let response = httpRequest(url, "/")
    response.status >= 200 and response.status < 500
  except CatchableError:
    false

proc readinessOk(spec: ServiceSpec): bool =
  case spec.readinessKind.normalize()
  of "", "none":
    true
  of "fileexists", "file", "path":
    spec.readinessPath.len > 0 and fileExists(extendedPath(spec.readinessPath))
  of "httpget":
    # DELEGATED rather than duplicated. D-SS10 hands the same predicate
    # to the resource lane as the installed `httpGet` prober, and two
    # copies of "the issuer is answering" is the drift L9 refuses a
    # twice-declared probe to avoid.
    readinessProbeSatisfied(spec.readinessUrl)
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
      while waited < DevSessionServiceStopGraceMs and runtime.process.running():
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

type InputSnapshot = seq[tuple[path: string; exists: bool; digest: Hash]]

proc snapshotInputs(paths: openArray[string]): InputSnapshot =
  ## The content of each watched input as a cycle is about to read it.
  for path in paths:
    var entry = (path: path, exists: false, digest: Hash(0))
    try:
      entry.digest = hash(readFile(extendedPath(path)))
      entry.exists = true
    except CatchableError:
      discard
    result.add(entry)

proc inputChangedSince(snapshot: InputSnapshot;
                       paths: openArray[string]): string =
  ## The first watched input whose content differs from ``snapshot``, or ""
  ## when none does. Content, not mtime: an edit that keeps the size and lands
  ## within the filesystem's timestamp granularity is still an edit. An input
  ## the snapshot never saw (the cycle widened the input set) has nothing to
  ## compare against and is not reported.
  for path in paths:
    var before = -1
    for i, entry in snapshot:
      if entry.path == path:
        before = i
        break
    if before < 0:
      continue
    let now = snapshotInputs([path])[0]
    if now.exists != snapshot[before].exists or
        now.digest != snapshot[before].digest:
      return path
  ""

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
  # AN EDIT MADE WHILE A CYCLE RUNS MUST START ANOTHER CYCLE. The watcher is
  # opened only after a cycle finishes, so a change written while a task was
  # running produced no event at all: the session went idle with the task's
  # output describing the OLD input until some later, unrelated edit. Under
  # load the window is the whole task run. So each cycle remembers the content
  # of the inputs it is about to read, and the next idle wait first compares
  # them; a difference is reported as the change the watcher could not see.
  var cycleInputs = snapshotInputs(eventInputPaths(artifact, state))
  if artifact.tasks.len > 0:
    state.runWatchCycle(config, artifact, artifactPath)
  # THE STOP REQUEST IS POLLED, NOT WATCHED FOR. ``stop.request.json`` is in
  # ``eventInputPaths``, but it lives under ``.repro/``, and the filesystem
  # watcher drops every event under a ``.repro`` component as build-output
  # noise (fc8d425a8). So the watch delivered the stop request to nobody,
  # ``waitForEvent`` waited for a source edit that never came, and ``repro
  # down`` timed out with the session still "up" and its services running.
  # The cancel check is the watcher's own way out of a blocking wait; it is
  # consulted on every poll on every platform.
  let stopPath = state.stopRequestPath
  let stopCheck: FilesystemWatchCancelCheck =
    proc(): bool = fileExists(extendedPath(stopPath))
  while not state.stopRequested():
    let paths = eventInputPaths(artifact, state)
    state.emitEvent("watch.idle")
    var watcher = openFilesystemWatcher(paths)
    try:
      # Opened BEFORE the comparison, so an edit landing in between is caught
      # by one or the other.
      let missed = inputChangedSince(cycleInputs, paths)
      let event =
        if missed.len > 0:
          FilesystemWatchEvent(path: missed,
            detail: "changed while the previous cycle ran")
        else:
          try:
            watcher.waitForEvent(cancelCheck = stopCheck)
          except IOError:
            if state.stopRequested():
              break
            raise
      if state.stopRequested():
        break
      if event.path == state.stopRequestPath or
          event.path.startsWith(state.sessionDir):
        cycleInputs = snapshotInputs(paths)  # or it would be reported again
        continue
      state.lastWatchPath = event.path
      state.emitEvent("watch.filesystem.changed", watchPath = event.path,
        detail = event.detail)
      discard watcher.drainDebouncedEvents(config.debounceMs)
      cycleInputs = snapshotInputs(paths)
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
    specs = serviceSpecsFromArtifact(artifact,
      readSharedInstanceMinted(config.outDir))
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
