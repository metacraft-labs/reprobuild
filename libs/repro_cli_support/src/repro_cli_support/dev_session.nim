import std/[algorithm, atomics, hashes, json, net, options, os, osproc, sequtils,
            strtabs, strutils, tables, times]

import cbor
import repro_core
import repro_dev_env_activation
import repro_dev_env_artifacts
import repro_dev_env_engine
from repro_interface_artifacts import seededSourcePackageEnvironmentNames
import repro_provider_runtime
import repro_project_dsl                 # ServiceIdentityDef / ServiceScope
import repro_resources/service_identity  # the (identity, scope, environment) key
import repro_resources/service_registry  # the snapshot codec + lease words
import repro_resources/readiness_edge    # D-SS10 (§7.1): the edge's own names
import repro_cli_support/service_registrar  # §7.3: the env var a refusal names
import repro_cli_support/watch
import repro_cli_support/session_process_owner

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
    sessionId*: string
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
    parentPid*: int
    supervised*: bool
    sessionId*: string
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
    consumedActionIds*: seq[string]
      ## Shared-Development-Services F1 (§4.8 / D-SS15), SECOND HALF:
      ## the ids of the build actions whose outputs this service NAMES,
      ## carried from `DevEnvServiceSummary.consumedActionIds`.
      ##
      ## This is the ORDERING EDGE, and it is the edge that already
      ## exists rather than a new one: `args <output>.path` and
      ## `runtimeFile <output>` record the producing action's id on the
      ## service record, so the dev session reads an IDENTIFIER MATCH.
      ## `devSessionStartPlan` folds these into the SAME topological
      ## walk `dependsOn` goes through, so an action and a service are
      ## two kinds of node in one order rather than two orderings.

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
    httpPid: int
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
    "httpPid": state.httpPid,
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
    ## the choice taken. Its cost used to be named here rather than
    ## hidden: a `keep` holder's consumer id was not written into a lease
    ## record (`mergeHolderDeadlines` dropped it), so a daemon restart
    ## could not enumerate the holders of an instance held only by `keep`
    ## holders, and §4.5 rule 1 then REFUSED `--replace` and refused to
    ## decide a release.
    ##
    ## STATE-RECORD v4 REMOVED THAT COST. Keep holders are written by
    ## name (`ResourceStateRecord.keepHolders`, with `keepHoldersKnown`
    ## saying the list is complete), so a daemon restart enumerates them
    ## and `--replace` refuses by NAMING the holder instead of refusing
    ## because it cannot. The default no longer trades a refusal for
    ## anything; a dated default would still trade a reaped database for
    ## one. Only a record written BEFORE v4 keeps the old behaviour.
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
  IssuerMintedAttributeTokenPrefix* = "@issuer-minted:"
    ## Shared-Development-Services §7.2 -- THE TOKEN A CONSUMER WRITES
    ## WHEN A DEVELOPMENT IDENTIFIER WILL NOT DO.
    ##
    ## `@minted:<member>@` takes whatever the installed registrar
    ## produced, which is what makes the offline path work: §7.2 keeps
    ## the development registrar as the default because "requiring one
    ## [an issuer] to bring a stack up would make the offline path
    ## impossible". `@issuer-minted:<member>@` is the same read with the
    ## question §7.2 asks for -- "a consumer that requires an
    ## issuer-minted id must be able to REFUSE a development one by
    ## asking" -- and it refuses by name, saying what it got, who
    ## produced it and what it needed.
    ##
    ## IT SHARES THE SUFFIX AND NOT THE PREFIX, and the spelling is
    ## load-bearing: `@issuer-minted:` does NOT contain `@minted:` (the
    ## character before `minted:` is `-`, not `@`), so the two token
    ## families cannot be confused by the substring test that catches an
    ## embedded token. A test pins that non-containment, because a
    ## future rename to `@minted-by-issuer:` would silently make every
    ## such token look like an embedded `@minted:` and be refused for
    ## the wrong reason.
  InstanceAttributeTokenPrefix* = "@instance-attribute:"
    ## Shared-Development-Services §7.3 — THE TOKEN A CONSUMER WRITES
    ## FOR A COMPUTED ATTRIBUTE OF THE RUNNING INSTANCE.
    ##
    ## §9.3's corrected worked example:
    ##
    ## ```nim
    ## args "--issuer",    "@instance-attribute:issuer@"
    ##      "--client-id", "@issuer-minted:isonim-site@"
    ## ```
    ##
    ## A SIBLING OF `@issuer-minted:`, DELIBERATELY ON THE SAME LANE.
    ## §9.3 originally wrote `sso.issuer`, a member on the lifted handle,
    ## and §7.3 corrected it rather than implementing it: the handle is
    ## resolved at EXPANSION, and the issuer URL does not exist then --
    ## it is a property of a running instance, which port it bound and
    ## which hostname the selected environment gave it. "A field on an
    ## expansion-time value would have to be either empty or a guess,
    ## and §7.2 already settles what to do with a value that cannot be
    ## known yet: refuse."
    ##
    ## The second half of that argument is why this is not a NEW
    ## mechanism either: "The minted client id is exactly the same kind
    ## of thing and already has a lane ... Giving the issuer a second,
    ## different mechanism would mean two ways to carry one class of
    ## value, and the one that looked simpler would be the one that
    ## cannot work." So this token is resolved by the same proc, out of
    ## the same session document, read back from the same durable
    ## instance record across sessions.
    ##
    ## PREFIX NON-CONTAINMENT, as load-bearing here as it is for
    ## `@issuer-minted:`: `@instance-attribute:` contains neither
    ## `@minted:` nor `@issuer-minted:`, and neither of them contains
    ## it, so the substring test that catches an EMBEDDED token cannot
    ## confuse the three families. A test pins all six directions,
    ## because a rename that broke one would refuse a token for the
    ## wrong reason rather than fail to compile.
    ##
    ## IT REQUIRES THE `issuer` PROVENANCE AND HAS NO PERMISSIVE
    ## SPELLING, which is the one place it diverges from the minted
    ## pair. `@minted:` exists beside `@issuer-minted:` because §7.2
    ## keeps the offline path working: a locally derived client id is a
    ## real, usable development credential. There is no offline
    ## counterpart of an issuer URL -- an issuer either exists at some
    ## address or it does not, and a guessed one is not a degraded
    ## version of the real thing but a wrong answer that fails
    ## elsewhere. So a consumer that asks for an instance attribute is
    ## asking about the world, and the answer is the running instance's
    ## or it is a refusal.
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

type
  SharedInstanceAttributeRow* = tuple[serviceName, name, value,
                                      registrar: string;
                                      provenance: RegistrarProvenance]
    ## Shared-Development-Services §7.3 — one row of the session
    ## document's `instanceAttributes`.
    ##
    ## `serviceName` is the SHARED SERVICE the attribute belongs to, not
    ## the consuming one, exactly as it is on a minted row: a session may
    ## resolve two shared services and both may report an `issuer`, and
    ## the qualified key is what tells them apart.

proc writeSharedInstanceMinted*(outDir: string;
    entries: openArray[tuple[serviceName, member, mintedId: string;
                             provenance: RegistrarProvenance]];
    attributes: openArray[SharedInstanceAttributeRow] = []) =
  ## Record what the instance minted, WITH the provenance of each row,
  ## and what it reported about ITSELF (§7.3).
  ##
  ## §7.2: the mark travels with the value. This file is the only thing
  ## standing between `repro up`'s registrar and the supervisor child's
  ## argv, so a row written here without its stamp is a value that
  ## arrives at the point of use indistinguishable from an issuer's --
  ## the defect §7.2 names, at the one hop where it would be invisible.
  ##
  ## ONE DOCUMENT FOR BOTH ROW SETS, and the argument is
  ## `mergeSharedInstanceMinted`': "A second file would mean two readers
  ## at the point of use, and `substituteMintedAttributes` takes ONE
  ## table; the one that happened to be read first would silently win a
  ## member both held." §7.3's attributes are the same class of value on
  ## the same lane, so a second file for them would reintroduce exactly
  ## that, one row set over.
  ##
  ## `attributes` DEFAULTS TO EMPTY, AND THIS PROC WRITES WHAT IT IS
  ## GIVEN. A caller that passes none writes none, which is what the
  ## owner's converge wants: the file is rewritten unconditionally on
  ## every `repro up` precisely so a previous run's rows cannot resolve
  ## a token the recipe no longer declares, and §7.3's anti-staleness
  ## rule needs that to be true of an issuer URL too. A caller that
  ## wants to ADD rows to what is on disk uses
  ## `mergeSharedInstanceMinted`, which is the F5 cross-session path.
  createDir(extendedPath(outDir.sessionDir))
  var rows = newJArray()
  for entry in entries:
    rows.add(%*{"serviceName": entry.serviceName, "member": entry.member,
      "mintedId": entry.mintedId,
      MintedProvenanceField: $entry.provenance})
  var attrRows = newJArray()
  for attr in attributes:
    attrRows.add(%*{"serviceName": attr.serviceName, "name": attr.name,
      "value": attr.value, "registrar": attr.registrar,
      MintedProvenanceField: $attr.provenance})
  let doc = %*{"schemaId": SharedInstanceMintedSchemaId}
  doc["registrations"] = rows
  doc[InstanceAttributesField] = attrRows
  writeFile(extendedPath(outDir.sharedInstanceMintedPath), $doc & "\n")

proc writeSharedInstanceMinted*(outDir: string;
    entries: openArray[tuple[serviceName, member, mintedId: string]]) =
  ## The UNSTAMPED writer, for a caller that has no provenance to state.
  ##
  ## It writes `provenance: unstamped` rather than omitting the key: an
  ## omitted key and an explicit `unstamped` read the same, and writing
  ## it makes the file say out loud that nothing claimed these rows.
  ## `@issuer-minted:` refuses them; `@minted:` resolves them.
  var stamped: seq[tuple[serviceName, member, mintedId: string;
                         provenance: RegistrarProvenance]] = @[]
  for entry in entries:
    stamped.add((serviceName: entry.serviceName, member: entry.member,
      mintedId: entry.mintedId, provenance: rprUnstamped))
  writeSharedInstanceMinted(outDir, stamped)

type
  MintedAttribute* = object
    ## One row of `SharedInstanceMintedFile`, as a consumer sees it: the
    ## identifier AND where it came from.
    ##
    ## §7.2 asks for a fact carried WITH the value rather than a naming
    ## convention, and this object is where that is true at the point of
    ## use: `substituteMintedAttributes` has the stamp in its hand at the
    ## moment it decides whether to concretize a token.
    value*: string
    provenance*: RegistrarProvenance
    registeredMember: string
      ## The reader carries the member name alongside both lookup aliases.
      ## A member can contain colons, so its name cannot be recovered by
      ## inspecting whether a table key looks service-qualified. Empty for
      ## caller-built tables, whose keys are reported verbatim instead.

  InstanceAttribute* = object
    ## Shared-Development-Services §7.3 — one computed attribute of the
    ## running instance, as a consumer sees it at the point of use.
    ##
    ## `MintedAttribute` WITH THE REGISTRAR'S NAME, and the extra field
    ## is the difference between a usable refusal and a puzzling one. A
    ## minted id that fails the provenance question is refused with the
    ## session event log named as the place that says which registrar
    ## ran; an attribute's refusal can do better, because the row itself
    ## records who reported it -- and "the issuer URL you were given came
    ## from `external:/path/to/script`" is the sentence that ends the
    ## investigation.
    value*: string
    provenance*: RegistrarProvenance
    registrar*: string

proc readSharedInstanceRecord*(outDir: string):
    tuple[registrations: seq[tuple[serviceName, member, mintedId: string;
                                   provenance: RegistrarProvenance]];
          attributes: seq[SharedInstanceAttributeRow]] =
  ## THE ONE PARSE of this document: both row sets, as written, in file
  ## order, with their stamps decoded.
  ##
  ## Every other reader here is a projection of this one.
  ## `readSharedInstanceMintedRows` takes the registrations,
  ## `readSharedInstanceAttributeRows` the attributes, the two table
  ## folds derive from those, and `readSharedInstanceMinted` drops the
  ## stamp from one of the folds. None of them parses the file a second
  ## time, because two readings of one document are two things that can
  ## disagree, and the disagreements that matter here -- one reader
  ## seeing a stamp and the other not, one reader seeing an attribute
  ## row and the other not -- are the whole defect.
  result.registrations = @[]
  result.attributes = @[]
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
  # §7.3's rows, read BEFORE the registrations' early return, so a
  # document with attributes and no `registrations` key does not drop
  # them. The schema id is NOT bumped for this field, for the reason
  # the durable record's `provenance` was not: this document is
  # session-local and rewritten by every `repro up` before the
  # supervisor starts, so there is no older writer to be compatible
  # with -- and an absent key reads as "this instance reported none",
  # which is the truth about a file an older build wrote.
  let attrRows = doc{InstanceAttributesField}
  if not attrRows.isNil and attrRows.kind == JArray:
    for row in attrRows:
      if row.kind != JObject:
        continue
      let name = row{"name"}.getStr("")
      let value = row{"value"}.getStr("")
      # A ROW WITH NO NAME OR NO VALUE IS SKIPPED, not refused, and the
      # asymmetry with the DURABLE record (which refuses both) is
      # deliberate: this document's rows are skipped the same way a
      # minted row with no `member` is skipped three screens down,
      # because the point of use refuses by name for the attribute the
      # RECIPE asked for. Refusing the whole file here would turn one
      # malformed row into a session that cannot start for a service
      # that never asked for an attribute.
      if name.len == 0 or value.len == 0:
        continue
      result.attributes.add((serviceName: row{"serviceName"}.getStr(""),
        name: name, value: value,
        registrar: row{"registrar"}.getStr(""),
        provenance: parseRegistrarProvenance(
          row{MintedProvenanceField}.getStr(""))))
  let rows = doc{"registrations"}
  if rows.isNil or rows.kind != JArray:
    return
  for row in rows:
    if row.kind != JObject:
      continue
    let serviceName = row{"serviceName"}.getStr("")
    let member = row{"member"}.getStr("")
    let mintedId = row{"mintedId"}.getStr("")
    if member.len == 0 or mintedId.len == 0:
      continue
    # AN UNKNOWN PROVENANCE WORD IS `unstamped`, NOT A GUESS AND NOT A
    # PARSE FAILURE -- `parseRegistrarProvenance`, the ONE decode, which
    # the durable registration record shares. See its own comment for
    # why `issuer` is the one answer it must not reach for.
    result.registrations.add((serviceName: serviceName, member: member,
      mintedId: mintedId,
      provenance: parseRegistrarProvenance(
        row{MintedProvenanceField}.getStr(""))))

proc readSharedInstanceAttributeRows*(outDir: string):
    seq[SharedInstanceAttributeRow] =
  ## §7.3's rows AS WRITTEN. A projection of `readSharedInstanceRecord`.
  ##
  ## IT EXISTS AS A SEPARATE SURFACE for `readSharedInstanceMintedRows`'
  ## reason: the fold below is lossy (it drops a bare name two services
  ## disagree about), so the cross-session merge -- which has to REWRITE
  ## the file -- cannot reconstruct the rows from it.
  readSharedInstanceRecord(outDir).attributes

proc readSharedInstanceAttributes*(outDir: string):
    Table[string, InstanceAttribute] =
  ## §7.3's attributes, keyed `<serviceName>:<name>` and also by the
  ## bare `<name>`.
  ##
  ## BOTH KEYS AND THE SAME AMBIGUITY RULE as the minted fold, because
  ## the reason is the same one: a consuming service writes the NAME it
  ## needs (`@instance-attribute:issuer@`) and does not generally know
  ## which shared service reported it, while a session that resolved TWO
  ## shared services each reporting an `issuer` must not have one of
  ## them silently chosen for it. Two disagreeing services drop the bare
  ## key, so the token refuses and the author qualifies it.
  result = initTable[string, InstanceAttribute]()
  var ambiguous: seq[string] = @[]
  for row in readSharedInstanceAttributeRows(outDir):
    let attr = InstanceAttribute(value: row.value,
      provenance: row.provenance, registrar: row.registrar)
    result[row.serviceName & ":" & row.name] = attr
    if row.name in result and result[row.name] != attr:
      ambiguous.add(row.name)
    else:
      result[row.name] = attr
  for name in ambiguous:
    result.del(name)

proc readSharedInstanceMintedRows*(outDir: string):
    seq[tuple[serviceName, member, mintedId: string;
              provenance: RegistrarProvenance]] =
  ## The file's minted rows AS WRITTEN, in file order, with the stamp
  ## decoded. A projection of `readSharedInstanceRecord`, which is
  ## THE ONE PARSE of this document.
  ## `readSharedInstanceMintedAttributes` folds these rows into the
  ## lookup table and `readSharedInstanceMinted` drops the stamp from
  ## that; neither parses the file, because two readings of one document
  ## are two things that can disagree, and the disagreement that matters
  ## here -- one reader seeing a stamp and the other not -- is the whole
  ## defect.
  ##
  ## IT EXISTS AS A SEPARATE SURFACE BECAUSE THE TABLE IS LOSSY. The
  ## table keys on `<serviceName>:<member>` and on the bare `<member>`,
  ## and drops the bare key when two services disagree -- so a caller
  ## that has to REWRITE the file (L9 F5's resolver, merging what
  ## another project's instance minted into this session's rows) cannot
  ## reconstruct the rows from it. A merge built on the table would
  ## quietly re-attribute every row to whichever service sorted first.
  readSharedInstanceRecord(outDir).registrations

proc readSharedInstanceMintedAttributes*(outDir: string):
    Table[string, MintedAttribute] =
  ## The minted table WITH provenance, keyed `<serviceName>:<member>` and
  ## also by the bare `<member>`. Folded from
  ## `readSharedInstanceMintedRows`, which is the one parse.
  result = initTable[string, MintedAttribute]()
  var ambiguous: seq[string] = @[]
  for row in readSharedInstanceMintedRows(outDir):
    let attr = MintedAttribute(value: row.mintedId,
      provenance: row.provenance, registeredMember: row.member)
    result[row.serviceName & ":" & row.member] = attr
    if row.member in result and result[row.member] != attr:
      ambiguous.add(row.member)
    else:
      result[row.member] = attr
  for member in ambiguous:
    result.del(member)

proc mergeSharedInstanceMinted*(outDir: string;
    entries: openArray[tuple[serviceName, member, mintedId: string;
                             provenance: RegistrarProvenance]];
    attributes: openArray[SharedInstanceAttributeRow] = []) =
  ## Add rows to this session's minted record, keeping what is already
  ## there and REPLACING a row with the same `(serviceName, member)`.
  ##
  ## WHY A MERGE AND NOT A SECOND FILE (L9 F5). A project may both
  ## DECLARE a shared service and RESOLVE another project's — `repro up`
  ## converges its own declarations first and writes their rows, then
  ## the resolver runs. A second file would mean two readers at the
  ## point of use, and `substituteMintedAttributes` takes ONE table; the
  ## one that happened to be read first would silently win a member both
  ## held. One document, one reader, one ambiguity rule — and the
  ## ambiguity rule is already `readSharedInstanceMintedAttributes`',
  ## which drops a bare member two services disagree about rather than
  ## picking one.
  ##
  ## REPLACE RATHER THAN APPEND on a repeated key, because the caller
  ## that repeats one is reading the SAME instance again in the same
  ## process and the later read is the current one. Appending would
  ## leave two rows whose values the fold then has to choose between,
  ## and the fold's rule would delete the bare key — turning a
  ## re-resolution into a refusal.
  ##
  ## §7.3'S ATTRIBUTE ROWS MERGE BY `(serviceName, name)`, on the same
  ## rule and for the same reason. The one thing this proc must not do is
  ## read the file, ignore one of its two row sets, and write it back:
  ## that is a silent drop with a merge's name on it, and it is the shape
  ## the registration half already had to be careful about. Both row sets
  ## are read, both are merged, both are written.
  let record = readSharedInstanceRecord(outDir)
  var rows = record.registrations
  for entry in entries:
    var replaced = false
    for i in 0 ..< rows.len:
      if rows[i].serviceName == entry.serviceName and
         rows[i].member == entry.member:
        rows[i] = entry
        replaced = true
        break
    if not replaced:
      rows.add(entry)
  var attrRows = record.attributes
  for attr in attributes:
    var replaced = false
    for i in 0 ..< attrRows.len:
      if attrRows[i].serviceName == attr.serviceName and
         attrRows[i].name == attr.name:
        attrRows[i] = attr
        replaced = true
        break
    if not replaced:
      attrRows.add(attr)
  writeSharedInstanceMinted(outDir, rows, attrRows)

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
  ## PROVENANCE-BLIND BY CONSTRUCTION, and kept for the callers that
  ## genuinely do not ask: it is derived from
  ## `readSharedInstanceMintedAttributes` by dropping the stamp, so it
  ## cannot see a row the stamped reader does not.
  result = initTable[string, string]()
  for key, attr in readSharedInstanceMintedAttributes(outDir):
    result[key] = attr.value

proc substituteMintedAttributes*(serviceName: string;
                                 command: seq[string];
                                 minted: Table[string, MintedAttribute];
                                 attributes =
                                   initTable[string, InstanceAttribute]()):
                                 seq[string] =
  ## Replace every `@minted:<member>@`, `@issuer-minted:<member>@` and
  ## `@instance-attribute:<name>@` token in `command` with what the
  ## instance minted for that member or reported about itself.
  ##
  ## WHOLE-TOKEN ONLY, not a substring rewrite, and that is deliberate:
  ## a flag written `--client-id=@minted:x@` is a shape this does NOT
  ## resolve, and it is better to refuse it than to rewrite inside an
  ## argument where the author may have meant the text. The refusal
  ## names the token, so the author learns the shape rather than
  ## debugging an issuer error.
  ##
  ## §7.2: THIS IS THE POINT OF USE, so it is where the question gets
  ## asked. `@minted:` takes what the installed registrar produced --
  ## development or issuer -- and `@issuer-minted:` refuses anything the
  ## issuer did not mint, naming what it got and what it needed. The
  ## decision reads the row's PROVENANCE and never the shape of the
  ## identifier: a consumer that pattern-matched an issuer's client id
  ## would be wrong the first time that issuer changed its format.
  ## §7.3: AND THIS IS WHERE THE INSTANCE ATTRIBUTE LANDS, beside the
  ## minted id and not on a mechanism of its own. "So the issuer is
  ## delivered as an instance attribute in argv, beside the minted id,
  ## and §9.3's `sso.issuer` spelling is corrected rather than
  ## implemented. Both values are concretized late." An absent attribute
  ## REFUSES by name -- which attribute, which instance, and what would
  ## supply it -- because §7.2's prohibition applies with its full force
  ## to a URL: an empty `--issuer` fails at authentication time,
  ## somewhere else, with nothing pointing back here.
  for token in command:
    # §7.3's token, handled FIRST and on its own, because it resolves
    # from a different table and asks a different question. It is a
    # whole-argument token under the same rule as the other two.
    if token.startsWith(InstanceAttributeTokenPrefix) and
       token.endsWith(MintedAttributeTokenSuffix) and
       token.len > InstanceAttributeTokenPrefix.len +
         MintedAttributeTokenSuffix.len - 1:
      let name = token[InstanceAttributeTokenPrefix.len ..
        token.len - MintedAttributeTokenSuffix.len - 1]
      let qualified = serviceName & ":" & name
      var attr: InstanceAttribute
      var found = false
      if attributes.hasKey(qualified):
        attr = attributes[qualified]
        found = true
      elif attributes.hasKey(name):
        attr = attributes[name]
        found = true
      if not found:
        var known: seq[string] = @[]
        for key in attributes.keys:
          if ':' notin key:
            known.add(key)
        known.sort()
        # THE REFUSAL NAMES THE ATTRIBUTE, THE INSTANCE AND WHAT WOULD
        # SUPPLY IT, which is what §7.1 asks of an early read and what
        # §7.3 needs of an absent one. The available names are listed
        # because the overwhelmingly common cause is a MISSPELLING, and
        # a refusal that says `issuer` is unavailable while the instance
        # reported `issuerUrl` has already answered the question if it
        # prints both.
        raise newException(ValueError,
          "service `" & serviceName & "`: the instance attribute `" &
          name & "` is NOT AVAILABLE, so the argument `" & token &
          "` cannot be concretized. An instance attribute is a property " &
          "of a RUNNING instance (Shared-Development-Services.md §7.3) " &
          "-- for `" & IssuerAttributeName & "`, which address it bound " &
          "and which hostname the selected environment gave it -- so it " &
          "does not exist at expansion and is not a field on the " &
          "service handle. It is reported by the REGISTRAR that spoke " &
          "to the instance, in its `" &
          InstanceAttributesField & "` answer, and recorded on the " &
          "instance's own registration record. Attributes this session " &
          "has: " & (if known.len == 0: "(none)" else: known.join(", ")) &
          ". " &
          (if known.len == 0:
             "NONE AT ALL means either that no registrar reported any " &
             "-- reprobuild's own development registrar reports none, " &
             "because it speaks to no issuer and so knows no issuer " &
             "URL -- or that this session never resolved the shared " &
             "service that owns this attribute. Declare the owning " &
             "project's registrar in `" &
             ServiceRegistrarProgramEnvVar & "` and converge again."
           else:
             "A name that is not in that list is usually a misspelling " &
             "of one that is.") &
          " Leaving the token verbatim or substituting an empty string " &
          "would reach the service as an issuer address it cannot use: " &
          "an empty string is indistinguishable from a legitimately " &
          "empty value, which is the one answer " &
          "Shared-Development-Services.md D-SS10 forbids, and the " &
          "verbatim token would be a URL nobody wrote.")
      if attr.provenance != rprIssuer:
        # §7.2's QUESTION, ASKED OF AN ATTRIBUTE. The clause is written
        # about a minted identifier, and an issuer URL is not minted --
        # but a WRONG one is just as silent, and the silence is the
        # defect rather than the minting. There is deliberately no
        # permissive spelling of this token (see
        # `InstanceAttributeTokenPrefix`): an issuer either exists at
        # some address or it does not, so there is nothing for a
        # development answer to be a usable degraded version OF.
        raise newException(ValueError,
          "service `" & serviceName & "`: the argument `" & token &
          "` reads the instance attribute `" & name &
          "`, and the recorded value carries provenance `" &
          $attr.provenance & "` instead of `" & $rprIssuer & "`. " &
          "It was reported by registrar `" &
          (if attr.registrar.len == 0: "(none recorded)"
           else: attr.registrar) &
          "`. An instance attribute says where a RUNNING instance can " &
          "be reached, and a value no registrar that spoke to the " &
          "instance claimed is a guess -- delivered, it would point " &
          "this service at an issuer that may not be the one serving " &
          "here, and the failure would arrive later as an " &
          "authentication error with nothing pointing back " &
          "(Shared-Development-Services.md §7.2, §7.3). Unlike `" &
          MintedAttributeTokenPrefix & "<member>" &
          MintedAttributeTokenSuffix & "` there is no offline spelling " &
          "of this token, because a guessed issuer URL is not a usable " &
          "development credential. Install the registrar supplied by " &
          "the project that OWNS this service (`" &
          ServiceRegistrarProgramEnvVar & "`), which is what " &
          "reports this attribute.")
      result.add(attr.value)
      continue
    var requireIssuer = false
    var member = ""
    var isToken = false
    if token.startsWith(IssuerMintedAttributeTokenPrefix) and
       token.endsWith(MintedAttributeTokenSuffix) and
       token.len > IssuerMintedAttributeTokenPrefix.len +
         MintedAttributeTokenSuffix.len - 1:
      requireIssuer = true
      isToken = true
      member = token[IssuerMintedAttributeTokenPrefix.len ..
        token.len - MintedAttributeTokenSuffix.len - 1]
    elif token.startsWith(MintedAttributeTokenPrefix) and
         token.endsWith(MintedAttributeTokenSuffix) and
         token.len > MintedAttributeTokenPrefix.len +
           MintedAttributeTokenSuffix.len - 1:
      isToken = true
      member = token[MintedAttributeTokenPrefix.len ..
        token.len - MintedAttributeTokenSuffix.len - 1]
    if not isToken:
      # BOTH prefixes are tested for the embedded shape, not just the
      # first. An argument carrying an embedded `@issuer-minted:` is the
      # same authoring mistake as one carrying an embedded `@minted:`,
      # and testing only the shorter prefix would let it through as
      # literal text -- a consumer launched with the token itself as its
      # client id, which is the silent form of this refusal.
      # §7.3's prefix is tested here too, and it has to be: an argument
      # written `--issuer=@instance-attribute:issuer@` is the same
      # authoring mistake, and omitting it from this list would let the
      # literal token text reach the service as its issuer URL. That is
      # not a hypothetical shape -- it is exactly what reprobuild did
      # with this token before §7.3 was implemented at all, for every
      # position: the token matched no prefix, so it was passed through
      # verbatim, and a consuming service received the text
      # `@instance-attribute:issuer@` as its `--issuer`.
      for prefix in [InstanceAttributeTokenPrefix,
                     IssuerMintedAttributeTokenPrefix,
                     MintedAttributeTokenPrefix]:
        if token.contains(prefix):
          raise newException(ValueError,
            "service `" & serviceName & "`: the argument `" & token &
            "` embeds " &
            (if prefix == InstanceAttributeTokenPrefix:
               "an instance-attribute" else: "a minted-attribute") &
            " token inside a larger " &
            "argument. The token is resolved as a WHOLE argument only, " &
            "so write it as its own `args` element (`\"" &
            (if prefix == InstanceAttributeTokenPrefix: "--issuer"
             else: "--client-id") & "\", " &
            "\"" & prefix &
            (if prefix == InstanceAttributeTokenPrefix: "<name>"
             else: "<member>") &
            MintedAttributeTokenSuffix & "\"`). Rewriting inside an " &
            "argument would guess at text the author may have meant.")
      result.add(token)
      continue
    let qualified = serviceName & ":" & member
    var attr: MintedAttribute
    var found = false
    if minted.hasKey(qualified):
      attr = minted[qualified]
      found = true
    elif minted.hasKey(member):
      attr = minted[member]
      found = true
    if found:
      if requireIssuer and attr.provenance != rprIssuer:
        raise newException(ValueError,
          "service `" & serviceName & "`: the argument `" & token &
          "` REQUIRES an issuer-minted `" & ClientIdAttributeName &
          "` for member `" & member & "`, and the registration of that " &
          "member carries provenance `" & $attr.provenance &
          "` instead of `" & $rprIssuer & "`. " &
          (if attr.provenance == rprDevelopment:
             "What this workspace has for that member is a DEVELOPMENT " &
             "identifier -- derived locally, offline, by a registrar " &
             "that spoke to no issuer. It is well-formed and no issuer " &
             "has ever heard of it, so substituting it would move this " &
             "failure to the issuer and turn it into an authentication " &
             "error with nothing pointing back here " &
             "(Shared-Development-Services.md §7.2)."
           else:
             "NOTHING CLAIMED that registration: it was produced with " &
             "no registrar identity declared, or recorded by a build " &
             "that predates provenance. An unstamped row is refused " &
             "rather than assumed -- assuming `" & $rprIssuer & "` is " &
             "the substitution §7.2 forbids.") &
          " Which registrar this session installed is recorded in the " &
          "session's `events.jsonl` under kind `" &
          RegistrarInstalledEventKind & "`, so \"the login failed\" and " &
          "\"this workspace never talked to an issuer\" are one " &
          "question. To bring the stack up offline anyway, write `" &
          MintedAttributeTokenPrefix & member &
          MintedAttributeTokenSuffix & "`, which accepts whichever " &
          "registrar is installed; to get a real one, install the " &
          "registrar supplied by the project that OWNS this service.")
      result.add(attr.value)
    else:
      var known: seq[string] = @[]
      for key, attr in minted:
        let memberName =
          if attr.registeredMember.len > 0: attr.registeredMember else: key
        if memberName notin known:
          known.add(memberName)
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

proc substituteMintedAttributes*(serviceName: string;
                                 command: seq[string];
                                 minted: Table[string, string];
                                 attributes =
                                   initTable[string, InstanceAttribute]()):
                                 seq[string] =
  ## The PROVENANCE-BLIND spelling, for a caller that holds only
  ## identifiers.
  ## Without registration metadata, diagnostic member names are the supplied
  ## keys verbatim, including any colons; no key spelling is guessed away.
  ##
  ## Every row it supplies is treated as `unstamped`, which is the truth
  ## about a table that cannot say otherwise -- so `@minted:` resolves
  ## and `@issuer-minted:` REFUSES. Fail-closed: the alternative, taking
  ## an unstamped row for the issuer's, is the one answer §7.2 forbids,
  ## and it would be reached by every caller that simply had not been
  ## updated.
  ##
  ## IT IS PROVENANCE-BLIND ABOUT THE MINTED TABLE ONLY. §7.3's
  ## attributes pass through with their own stamps intact, because this
  ## overload exists for a caller that holds a bare identifier table and
  ## not for one that wants the attribute question blurred -- and
  ## `@instance-attribute:` requires `issuer`, so stamping the
  ## attributes `unstamped` here would make every such token refuse for
  ## a reason the caller did not choose.
  var stamped = initTable[string, MintedAttribute]()
  for key, value in minted:
    stamped[key] = MintedAttribute(value: value, provenance: rprUnstamped)
  substituteMintedAttributes(serviceName, command, stamped, attributes)

proc serviceSpecFromSummary*(projectRoot: string;
                             service: DevEnvServiceSummary;
                             minted = initTable[string, MintedAttribute]();
                             attributes =
                               initTable[string, InstanceAttribute]()):
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
  # F1 (§4.8), second half: the ordering edge, carried verbatim. No
  # normalisation and no path resolution -- these are ACTION IDS, not
  # paths, which is the whole point of reading consumption from the
  # typed edge rather than from argv text.
  result.consumedActionIds = service.consumedActionIds
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
    result.command, minted, attributes)
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

# ───────────────────────────────────────────────────────────────────────
# Shared-Development-Services F1 (§4.8 / D-SS15), SECOND HALF —
# THE DEV SESSION BUILDS THE REPORTED ACTIONS, ORDERED BEFORE THE
# SERVICES THAT CONSUME THEIR OUTPUTS.
#
# WHAT WAS STILL ABSENT, in §4.8's own words: "Reporting an action is
# not running it. Nothing in this change makes the dev session BUILD the
# reported edges, so F1's clause is not met by it -- what is closed is
# F1's stated blocker ... and the remaining half is for the dev session
# to order the reported actions before the services it launches."
#
# So F1's measurement still reproduced after the actions channel landed:
# `repro up` reported the session up, the path reached the service's
# argv, and the FILE was never written. An action carried and not run is
# the same missing file with better bookkeeping.
#
# THE ORDER IS THE EXISTING ONE, NOT A NEW ONE. §7.1 settled that the
# readiness edge is "the `dependsOn` that already exists" and that "a
# service node's completion is its declared readiness"; the same
# principle decides this. `serviceStartOrder` already walks `dependsOn`
# as a DAG over service nodes, so an action becomes a NODE IN THAT WALK
# rather than a second sequencing concept: `devSessionStartPlan` folds
# `ServiceSpec.consumedActionIds` into the same depth-first visit, and
# the plan it returns is ONE topological order over both kinds of node.
# A test can therefore assert the ordering as an index comparison on the
# plan -- the action's step comes before its consumer's -- instead of
# inferring it from process timing.
#
# CONSUMPTION IS AN IDENTIFIER MATCH, read from the typed edge. That is
# §4.8's rule for the orphan diagnostic and it is the same rule here,
# from the same derivation (`typedServiceConsumedActionIds` in
# `repro_project_dsl/runtime_provider.nim`), because a diagnostic that
# refuses an unconsumed action and an ordering that builds a consumed
# one must not be able to disagree about what consumption is.
# ───────────────────────────────────────────────────────────────────────

type
  DevSessionStartStepKind* = enum
    dsskAction
      ## A build action the `devEnv:` body registered. It is BUILT.
    dsskService
      ## A service the session starts. It is not started by the action
      ## pass -- its presence in the plan is what makes the ORDERING
      ## claim readable, and its position is what the ordering is.

  DevSessionStartStep* = object
    ## One node of the session's start order. Two kinds in ONE list,
    ## deliberately: a plan that held actions and services in separate
    ## lists would state the order nowhere, which is how "ordered
    ## before" becomes an assertion about nothing.
    kind*: DevSessionStartStepKind
    action*: DevEnvActionSummary
      ## `dsskAction` only.
    consumers*: seq[string]
      ## `dsskAction` only: the names of the services whose
      ## `consumedActionIds` name this action, in plan order. Carried so
      ## a failure can say WHICH SERVICE will not start because of it --
      ## "an action failed" names the wrong half of the problem.
    service*: ServiceSpec
      ## `dsskService` only.

  DevSessionActionRunner* =
      proc (action: DevEnvActionSummary; projectRoot: string): string
    ## Build ONE dev-env action. Returns `""` on success and a reason
    ## otherwise.
    ##
    ## A CALLBACK FOR THE REASON `DevSessionProducerOpsResolver` IS ONE,
    ## plus a layering reason of its own. Lowering a `gnkAction` node
    ## into an engine `BuildAction` is `repro_cli_support.nim`'s
    ## `lowerGraphAction` -- the ONE lowering the build lane itself goes
    ## through -- and that module IMPORTS this one. Re-implementing the
    ## lowering here would be a second reading of the same payload, with
    ## its own notion of which argument carries the text and which
    ## carries the output path; two readings of one record is the defect
    ## shape this document keeps finding. So this module owns the ORDER
    ## and the caller owns HOW an action node becomes a run edge.

proc devSessionStartPlan*(actions: openArray[DevEnvActionSummary];
                          services: openArray[ServiceSpec]):
    seq[DevSessionStartStep] =
  ## ONE topological order over the actions a `devEnv:` body registered
  ## and the services the session starts, with every action placed
  ## BEFORE every service that names it.
  ##
  ## EVERY REPORTED ACTION IS IN THE PLAN, including one no SELECTED
  ## activity's service consumes. That direction is §4.8's own, stated
  ## there for the orphan check: the actions registry holds what every
  ## activity body of the package registered, while `services` is gated
  ## on `--activity`, so dropping an unclaimed action would make what
  ## the session builds a function of the selection. An action nothing
  ## in the PACKAGE consumes is already refused at evaluation by the
  ## `PRODUCED AND NEVER CONSUMED` diagnostic, so the set reaching here
  ## is consumed by something.
  # COPIED INTO LOCALS BEFORE THE NESTED VISITS, because an `openArray`
  # cannot be captured by a closure without violating memory safety and
  # the walk below is two mutually recursive nested procs. The copy is
  # also what lets the signature stay an `openArray`, so a caller with a
  # `seq` and a caller with an array both reach it without a conversion
  # at the call site.
  let actionList = @actions
  let specList = @services
  var actionAt = initTable[string, int]()
  for i, action in actionList:
    if action.actionId in actionAt:
      raise newException(ValueError,
        "two dev-env actions share the id `" & action.actionId &
        "`, so an ordering edge onto it would be ambiguous: a service " &
        "naming it could not say which of the two has to be built " &
        "first. Refused rather than resolved by position.")
    actionAt[action.actionId] = i

  # Which services name each action, in the order the services were
  # given. Built once, read by the plan and by the failure message.
  var consumersOf = initTable[string, seq[string]]()
  for spec in specList:
    for id in spec.consumedActionIds:
      if id notin actionAt:
        raise newException(ValueError,
          "service `" & spec.name & "` names the output of dev-env " &
          "action `" & id & "`, which this dev-env artifact does not " &
          "carry (" & $actionList.len & " action(s): " &
          actionList.mapIt(it.actionId).join(", ") & "). The service's " &
          "argv therefore holds a path nothing in this session will " &
          "write -- which is exactly the failure " &
          "Shared-Development-Services F1 measured -- so the session " &
          "is refused rather than started against a missing file.")
      if id notin consumersOf:
        consumersOf[id] = @[]
      if spec.name notin consumersOf[id]:
        consumersOf[id].add(spec.name)

  # The action-to-action edges, read off the SAME payload the build lane
  # reads. An action may declare `deps` on other actions (a rendered
  # file assembled from another rendered file); only deps that are
  # themselves actions of this dev-env are orderable here, and a dep on
  # anything else belongs to the build lane rather than to this session.
  var actionDeps = newSeq[seq[string]](actionList.len)
  for i, action in actionList:
    let payload =
      try:
        decodeBuildActionPayload(toBytes(action.payload))
      except CatchableError as err:
        raise newException(ValueError,
          "dev-env action `" & action.actionId & "` carries a payload " &
          "this build cannot decode (" & err.msg & "). Refused rather " &
          "than skipped: an action whose payload cannot be read is an " &
          "action whose output nothing will produce, and a service " &
          "names that output.")
    for dep in payload.deps:
      if dep in actionAt and dep != action.actionId:
        actionDeps[i].add(dep)

  var temporary: seq[string] = @[]
  var permanent: seq[string] = @[]
  var plan: seq[DevSessionStartStep] = @[]

  proc visitAction(index: int)
  proc visitSpec(index: int)

  proc visitAction(index: int) =
    let key = "action:" & actionList[index].actionId
    if permanent.find(key) >= 0:
      return
    if temporary.find(key) >= 0:
      raise newException(ValueError,
        "cycle in dev-env action dependencies at " &
        actionList[index].actionId)
    temporary.add(key)
    for dep in actionDeps[index]:
      visitAction(actionAt[dep])
    discard temporary.pop()
    permanent.add(key)
    plan.add(DevSessionStartStep(kind: dsskAction,
      action: actionList[index],
      consumers: consumersOf.getOrDefault(actionList[index].actionId, @[])))

  proc visitSpec(index: int) =
    let key = "service:" & specList[index].name
    if permanent.find(key) >= 0:
      return
    if temporary.find(key) >= 0:
      raise newException(ValueError,
        "cycle in dev service dependencies at " & specList[index].name)
    temporary.add(key)
    # THE ACTIONS FIRST, inside the same visit `dependsOn` goes through.
    # Putting them here rather than in a pass of their own is what makes
    # this one order instead of two: a service that depends on another
    # service which consumes an action gets that action ahead of BOTH,
    # with no second rule to state it.
    for id in specList[index].consumedActionIds:
      visitAction(actionAt[id])
    for dep in specList[index].dependsOn:
      let depIndex = specList.serviceIndex(dep)
      if depIndex < 0:
        raise newException(ValueError,
          "service " & specList[index].name &
          " depends on unknown service " & dep)
      visitSpec(depIndex)
    discard temporary.pop()
    permanent.add(key)
    plan.add(DevSessionStartStep(kind: dsskService,
      service: specList[index]))

  for i in 0 ..< specList.len:
    visitSpec(i)
  # Any action no listed service claimed, appended after the claimed
  # ones in declaration order. See the docstring: the set the session
  # builds must not be a function of `--activity`.
  for i in 0 ..< actionList.len:
    visitAction(i)
  plan

proc buildDevEnvActions*(actions: openArray[DevEnvActionSummary];
                         services: openArray[ServiceSpec];
                         projectRoot: string;
                         run: DevSessionActionRunner):
    tuple[built: seq[string]; failure: string] =
  ## Build every action in `devSessionStartPlan` order. Returns the ids
  ## built, in that order, and `""` for `failure` when all of them
  ## succeeded.
  ##
  ## A FAILURE NAMES THE CONSUMING SERVICE, not only the action, and the
  ## caller stops the session on it. §4.8's whole complaint about F1's
  ## original defect is that the session came UP with the file missing;
  ## an action that fails and a session that starts anyway is the same
  ## outcome reached one step later. The services are started by the
  ## supervisor (and the shared instances by the daemon) only after this
  ## returns with no failure, which is the ordering stated as control
  ## flow rather than as a hope about timing.
  if run == nil:
    return (built: @[], failure:
      "no dev-env action runner was supplied, so the " &
      $actions.len & " action(s) this dev-env registered would be " &
      "reported and never built -- which is the half of " &
      "Shared-Development-Services F1 that this call exists to close. " &
      "Refused rather than skipped.")
  var plan: seq[DevSessionStartStep]
  try:
    plan = devSessionStartPlan(actions, services)
  except CatchableError as err:
    return (built: @[], failure: err.msg)
  var builtIds: seq[string] = @[]
  for step in plan:
    if step.kind != dsskAction:
      continue
    let reason = run(step.action, projectRoot)
    if reason.len > 0:
      let who =
        if step.consumers.len == 0: "no service of the selected activity"
        else: "service(s) " & step.consumers.join(", ")
      return (built: builtIds, failure:
        "dev-env action `" & step.action.actionId & "` FAILED to " &
        "build: " & reason & ". " & who.capitalizeAscii() &
        " name(s) its output on the command line, so the session is " &
        "refused rather than started against a file that was not " &
        "written (Shared-Development-Services §4.8 / D-SS15).")
    builtIds.add(step.action.actionId)
  (built: builtIds, failure: "")

proc serviceSpecsFromArtifact(artifact: DevEnvArtifact;
                              minted = initTable[string, MintedAttribute]();
                              attributes =
                                initTable[string, InstanceAttribute]()):
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
      minted, attributes))
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
  ## The exclusively locked supervisor clears a previous helper's marker
  ## before spawning its child. Helpers normally remove their own marker,
  ## but an abruptly killed helper or an older binary can leave one behind.
  ## The launching parent must not clear it: only the admitted owner may
  ## mutate this directory, and the parent instead checks its launch ID.
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

proc reusableDevSession*(config: DevSessionSupervisorConfig): JsonNode =
  ## Convergence can be repeated while a session is up. Admit that existing
  ## owner only through its live API and held lock; a persisted `up` record
  ## or an orphaned listener is insufficient proof of a running session.
  let metadataPath = config.outDir.sessionDir / MetadataFile
  if not fileExists(extendedPath(metadataPath)): return nil
  let persisted = readJsonFileResilient(metadataPath)
  let live = controlApiStatus(persisted{"httpBind"}.getStr())
  if live.isNil or
      live{"sessionId"}.getStr().len == 0 or
      live{"sessionId"}.getStr() != persisted{"sessionId"}.getStr() or
      live{"supervisorPid"}.getInt() != persisted{"supervisorPid"}.getInt() or
      live{"projectRoot"}.getStr() != config.projectRoot:
    return nil
  if not sessionProcessAlive(live{"supervisorPid"}.getInt()):
    raise newException(IOError,
      "the existing dev session control API outlived its supervisor; " &
      "stop that orphaned listener before starting another session")
  try:
    let unowned = acquireSessionProcessLock(config.outDir.sessionDir / "supervisor.lock")
    unowned.release()
    raise newException(IOError,
      "the existing live dev session has no supervisor ownership lock; " &
      "run `repro down` before starting it again")
  except SessionProcessBusyError:
    discard
  if live{"mode"}.getStr() != config.mode.modeName:
    raise newException(ValueError,
      "dev session is already running in " & live{"mode"}.getStr() &
      " mode; run `repro down` before changing its mode")
  if live{"status"}.getStr() != "up":
    raise newException(IOError,
      "the existing dev session reports " & live{"status"}.getStr() &
      "; wait for it or run `repro down` before starting another session")
  live

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

  proc checkTerminalLaunch() =
    if config.sessionId.len == 0: return
    let metadata = config.outDir.sessionDir / MetadataFile
    if not fileExists(extendedPath(metadata)): return
    let terminal = readJsonFileResilient(metadata)
    if terminal{"sessionId"}.getStr() == config.sessionId and
        terminal{"status"}.getStr() == "failed":
      raise newException(IOError,
        "dev session cannot start: " & terminal{"failure"}.getStr() & "\n" &
        "  the supervisor reported that after the parent waited " &
        $int((epochTime() - started) * 1000.0) & " ms of the " &
        $budget.timeoutMs & " ms allowed\n" & config.eventLogHint())

  var launchBind: JsonNode
  proc launchReady(): bool =
    if not fileExists(extendedPath(readyFile)): return false
    try:
      launchBind = readJsonFileResilient(readyFile)
      return config.sessionId.len == 0 or
        launchBind{"sessionId"}.getStr() == config.sessionId
    except IOError:
      return false # a helper can remove its marker while we open it

  # Phase 1 -- the control API's ``http-ready.json``. Bounded by
  # ``DevSessionControlApiTimeoutMs`` AND by the budget, whichever is
  # sooner; see that constant for why this phase is not given the whole
  # derived budget.
  let controlDeadline = min(deadline,
    started + DevSessionControlApiTimeoutMs.float / 1000.0)
  while not launchReady():
    checkTerminalLaunch()
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
  let httpBindValue = launchBind{"httpBind"}.getStr()

  # Phase 2 requires a live control API for success. A persisted terminal
  # failure tied to this exact launch remains reportable after its helper
  # has exited. ``statusReads`` and ``lastStatus`` bound what the expiry
  # diagnostic may assert about HTTP replies.
  var statusReads = 0
  var lastStatus = ""
  var sessionId = ""
  while true:
    checkTerminalLaunch()
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

proc selfSeededSourceRootUnsetOps(): seq[DevEnvShellOp] =
  ## Unset ops for the source roots this engine seeded for its OWN compiles
  ## (``REPROBUILD_SOURCE_ROOT`` from the monitor-shim resolution, the built
  ## ``*_SRC`` roots), so a service or task does not inherit them, as
  ## ``repro exec``'s command does not (Distribution-And-Packaging §5;
  ## reprobuild-pm issue 2026-09-30, exec leaks the engine's own source root).
  ##
  ## Withdrawn from the child's activation rather than from this process,
  ## unlike ``repro exec``: the supervisor keeps recomputing the dev env on
  ## every watch cycle (``computeFreshArtifact``), and those compiles still
  ## need the seeds. Passed as ``preOps``, which apply BEFORE the dev env's
  ## own ops, so a name the dev env sets itself keeps the dev env's value
  ## even when that value happens to equal the seed.
  for name in seededSourcePackageEnvironmentNames():
    result.add(DevEnvShellOp(kind: deskUnsetEnv, name: name))

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
    extraOps = state.producerOps(artifact),
    preOps = selfSeededSourceRootUnsetOps())
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
    extraOps = state.producerOps(artifact),
    preOps = selfSeededSourceRootUnsetOps())
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

proc startHttpServer(config: DevSessionSupervisorConfig): Process =
  let httpBindParts = parseHttpBind(config.httpBind)
  let args = @[
    "__repro-dev-session-http",
    "--session-dir", config.outDir.sessionDir,
    "--host", httpBindParts.host,
    "--port", $httpBindParts.port,
    "--parent-pid", $getCurrentProcessId(),
    "--supervised",
    "--session-id", config.sessionId
  ]
  startProcess(config.publicCliPath,
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
    sessionId: if config.sessionId.len > 0: config.sessionId else:
      "dev-session-" & $getCurrentProcessId() & "-" & $epochTime(),
    mode: config.mode,
    projectRoot: config.projectRoot,
    artifactPath: artifactPath,
    activity: config.activity,
    sessionDir: config.outDir.sessionDir,
    httpBind: "",
    status: "starting",
    terminalEvents: config.foreground)
  createDir(extendedPath(state.sessionDir))
  let ownership = acquireSessionProcessLock(state.sessionDir / "supervisor.lock")
  defer: ownership.release()
  # A child of an abruptly killed owner may still be observing its death.
  # Refuse before changing its record or marker; do not replace that listener.
  let httpPreflight = acquireSessionProcessLock(state.sessionDir / "http.lock")
  httpPreflight.release()
  try:
    removeFile(extendedPath(state.stopRequestPath))
  except OSError:
    discard
  state.writeState()
  # Before the control-API child can publish a bind, the PREVIOUS session's
  # published bind has to go: ``waitForReadyFile`` below checks for the file
  # before it sleeps, so a leftover one is what it returns, and this
  # supervisor would record a closed port as its own ``httpBind``. Only
  # this locked owner removes it; the parent checks the launch session ID.
  config.discardStaleControlApiBind()
  let httpProcess = config.startHttpServer()
  state.httpPid = httpProcess.processID()
  let httpPid = state.httpPid
  var httpStopped = false
  proc stopHttpServer() =
    if httpStopped: return
    if httpProcess.running(): httpProcess.kill()
    discard httpProcess.waitForExit()
    httpProcess.close()
    httpStopped = true
    let readyPath = config.readyPath
    try:
      if fileExists(extendedPath(readyPath)) and
          readJsonFileResilient(readyPath){"pid"}.getInt() == httpPid:
        removeFile(extendedPath(readyPath))
    except CatchableError:
      discard
  defer: stopHttpServer()
  state.writeState()
  let ready =
    try:
      waitForReadyFile(config.readyPath, 5000)
    except CatchableError as err:
      state.recordStartFailure("", err.msg)
      raise
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
      readSharedInstanceMintedAttributes(config.outDir),
      # §7.3: the SECOND row set of the same document, read at the same
      # point and passed down the same call chain. Read here rather than
      # inside `serviceSpecFromSummary` for the reason the minted table
      # is: one read per session, so every service in the session sees
      # one answer, and a test can hand the pair in directly.
      readSharedInstanceAttributes(config.outDir))
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
    stopHttpServer()
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
      # Queue the asynchronous acknowledgement before publishing the stop:
      # either the supervisor or the lifetime watchdog may then close this
      # process immediately. `repro down` still requires terminal metadata
      # before reporting success; a failed stop-file write cannot satisfy it.
      client.sendResponse(202, "application/json", "{\"stopping\":true}\n")
      writeJsonFile(sessionDir / StopRequestFile, %*{
        "schemaId": "reprobuild.dev-session.stop-request.v1",
        "source": "http",
        "time": nowIso()
      })
  of "/health":
    client.sendResponse(200, "text/plain", "ok\n")
  else:
    client.sendResponse(404, "application/json", "{\"error\":\"not found\"}\n")

proc runDevSessionHttpServer*(config: DevSessionHttpConfig): int =
  createDir(extendedPath(config.sessionDir))
  let parent = openSessionParent(config.parentPid)
  defer: parent.close()
  if not parent.alive(): return 0
  # Direct internal invocations own the supervisor slot themselves. Only a
  # child launched by the supervisor shares its parent's already-held slot.
  var supervisorSlot: SessionProcessLock
  if not config.supervised:
    supervisorSlot = acquireSessionProcessLock(config.sessionDir / "supervisor.lock")
  defer: supervisorSlot.release()
  let ownership = acquireSessionProcessLock(config.sessionDir / "http.lock")
  defer: ownership.release()
  defer: config.sessionDir.removeOwnedReady()
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
    "sessionId": config.sessionId,
    "httpBind": httpBindValue,
    "pid": getCurrentProcessId()
  })
  # Publish completely before the watchdog may remove the marker. A death
  # during publication must not race cleanup against a partial JSON write.
  var stopped: Atomic[bool]
  var watchdog: Thread[SessionWatchdogArgs]
  createThread(watchdog, watchSessionParent,
    (parent: parent, dir: config.sessionDir, stopped: addr stopped))
  defer:
    stopped.store(true)
    joinThread(watchdog)
  while not fileExists(extendedPath(config.sessionDir / StopRequestFile)):
    var client: owned(Socket)
    server.accept(client)
    if not client.isNil:
      client.handleHttpClient(config.sessionDir)
  0
