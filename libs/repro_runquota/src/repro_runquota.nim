import std/[json, os, strutils, tables]
from repro_core/paths import extendedPath

# Windows: the sibling runquota repository now ships a Windows port
# (named-pipe transport + Job-Object-based process spawning), so the real
# runquota_* libraries link cleanly on every platform we target.
import runquota_client
import runquota_codec
import runquota_core
import runquota_ipc except connectDefault
import runquota_process
import runquota_protocol

type
  ReproRunQuotaError* = object of CatchableError

  ReproRunQuotaSession* = ref object
    client: RunQuotaClient
    session: RunQuotaSession
    nextCandidateId: uint64
    active*: bool

  ReproResourceRequest* = object
    label*: string
    commandStatsId*: string
    cpuMilli*: uint32
    memoryBytes*: uint64
    namedPool*: string
    namedPoolUnits*: uint32

  ReproCommandSpec* = object
    argv*: seq[string]
    cwd*: string
    env*: seq[string]
    stdoutLimit*: int
    stderrLimit*: int

  ReproRunQuotaExecution* = object
    leaseId*: uint64
    exitCode*: int
    exited*: bool
    signaled*: bool
    signal*: int
    stdout*: string
    stderr*: string
    stdoutBytes*: uint64
    stderrBytes*: uint64
    elapsedMillis*: uint64
    peakResidentMemoryBytes*: uint64
    processCount*: uint32
    backendName*: string
    leaseFinishedSent*: bool
    leaseReleased*: bool

  ReproRunQuotaRunningProcess* = object
    lease: RunQuotaLease
    child: LaunchedProcess
    active*: bool
    completed*: bool
    execution*: ReproRunQuotaExecution

  ReproRunQuotaQueuedProcess* = object
    candidateId*: uint64
    lease: RunQuotaLease
    command: ReproCommandSpec
    active*: bool

  ReproRunQuotaGrant* = object
    candidateId*: uint64
    queued*: bool
    active*: bool
    diagnostic*: string
    lease: RunQuotaLease

  ReproRunQuotaOfferKind* = enum
    rqokStarted
    rqokQueued

  ReproRunQuotaOffer* = object
    kind*: ReproRunQuotaOfferKind
    running*: ReproRunQuotaRunningProcess
    queued*: ReproRunQuotaQueuedProcess

proc effectiveCpu(request: ReproResourceRequest): uint32 =
  if request.cpuMilli == 0'u32: 1000'u32 else: request.cpuMilli

proc effectiveMemory(request: ReproResourceRequest): uint64 =
  if request.memoryBytes == 0'u64: 128'u64 * 1024'u64 * 1024'u64
  else: request.memoryBytes

# Windows: now that the runquota Windows port is live, these helpers compile
# unconditionally; the daemon and host backend take care of the platform
# differences underneath the public API.
proc toRunQuotaRequest*(request: ReproResourceRequest): ResourceRequest =
  let cpu = request.effectiveCpu()
  var resources = resourceVector(milliCpu(cpu), bytes(request.effectiveMemory()))
  if request.namedPool.len > 0 and request.namedPoolUnits > 0'u32:
    resources = resources.withNamedPool(request.namedPool, request.namedPoolUnits)
  result = ResourceRequest(
    label: request.label,
    commandStatsId: request.commandStatsId,
    resources: resources,
    deadline: noDeadline(),
    priority: priorityNormal,
    metadata: metadataNone())

proc diagnosticText(diagnostic: Diagnostic): string =
  if diagnostic.detail.len > 0:
    diagnostic.message & ": " & diagnostic.detail
  else:
    diagnostic.message

proc waitForQueuedGrant(session: var RunQuotaSession;
                        request: ResourceRequest): RunQuotaLease =
  const CandidateId = 1'u64
  let firstDecisions = session.offerCandidates([toCandidate(CandidateId, request)])
  var sawQueued = false
  for decision in firstDecisions:
    if decision.clientCandidateId != CandidateId:
      continue
    if decision.lease.active and not decision.queued:
      return decision.lease
    if decision.lease.active and decision.queued:
      sawQueued = true
    else:
      raise newException(ReproRunQuotaError,
        "runquota denied lease: " & decision.diagnostic.diagnosticText())
  if not sawQueued:
    raise newException(ReproRunQuotaError,
      "runquota did not return a decision for the offered lease")

  while true:
    for decision in session.pollNextGrant():
      if decision.clientCandidateId != CandidateId:
        continue
      if decision.lease.active and not decision.queued:
        return decision.lease
      if not decision.lease.active:
        raise newException(ReproRunQuotaError,
          "runquota denied queued lease: " & decision.diagnostic.diagnosticText())
    sleep(25)

proc finishOutcome(completion: ProcessCompletion): LeaseFinishOutcome =
  if completion.cancelled or completion.timedOut:
    leaseFinishCancelled
  elif completion.signaled:
    leaseFinishCrashed
  elif completion.exited and completion.exitCode == 0:
    leaseFinishSucceeded
  else:
    leaseFinishFailed

proc acquireCliArgs*(request: ReproResourceRequest;
                     command: ReproCommandSpec): seq[string] =
  result = @[
    "acquire",
    "--cpu", $request.effectiveCpu(),
    "--mem", $request.effectiveMemory(),
    "--label", request.label,
    "--"
  ]
  result.add(command.argv)

proc helperCliArgs*(request: ReproResourceRequest;
                    command: ReproCommandSpec;
                    resultPath: string): seq[string] =
  result = @[
    "__repro-runquota-helper",
    "--result", resultPath,
    "--label", request.label,
    "--stats", request.commandStatsId,
    "--cpu", $request.effectiveCpu(),
    "--mem", $request.effectiveMemory(),
    "--pool", request.namedPool,
    "--pool-units", $request.namedPoolUnits,
    "--cwd", command.cwd,
    "--stdout-limit", $command.stdoutLimit,
    "--stderr-limit", $command.stderrLimit
  ]
  for entry in command.env:
    result.add("--env")
    result.add(entry)
  result.add("--")
  result.add(command.argv)

type
  RunQuotaProbeResult = object
    success: bool
    completed: bool

var probeSlot: RunQuotaProbeResult

proc runProbeOnce(arg: pointer) {.thread.} =
  var local = RunQuotaProbeResult(success: false, completed: false)
  try:
    var client = connectDefault()
    client.close()
    local.success = true
  except CatchableError:
    discard
  local.completed = true
  let slotPtr = cast[ptr RunQuotaProbeResult](arg)
  slotPtr[] = local

when defined(windows):
  proc waitNamedPipeW(name: WideCString; ms: uint32): int32 {.
    stdcall, dynlib: "kernel32", importc: "WaitNamedPipeW".}

proc isRunQuotaDaemonReachable*(): bool =
  ## Cheap probe used by the CLI to decide whether to fall back to the
  ## path-mode bypass.
  ##
  ## Two-phase: a fast existence check via ``WaitNamedPipeW`` (Windows)
  ## or a direct connect attempt (POSIX). If the daemon isn't running,
  ## the existence check fails in milliseconds. If a daemon IS running
  ## but is wedged (pipe exists, handshake never completes — the
  ## stale-runquotad scenario from memory), the responsiveness check
  ## runs on a separate thread with a 2-second deadline so the build
  ## never blocks forever. On timeout the probe thread is intentionally
  ## leaked: joinThread would block on the wedged I/O too, and the
  ## process is about to fall back to bypass anyway.
  when defined(windows):
    let endpoint = defaultEndpoint()
    if endpoint.kind == endpointNamedPipe:
      let wide = newWideCString(endpoint.path)
      if waitNamedPipeW(wide, 100'u32) == 0:
        return false  # pipe doesn't exist / no instance free — daemon down
  probeSlot = RunQuotaProbeResult(success: false, completed: false)
  var thr: Thread[pointer]
  createThread(thr, runProbeOnce, cast[pointer](addr probeSlot))
  const deadlineMs = 2000
  let pollMs = 25
  var waited = 0
  while waited < deadlineMs:
    if probeSlot.completed:
      break
    sleep(pollMs)
    waited += pollMs
  if not probeSlot.completed:
    return false
  joinThread(thr)
  probeSlot.success

proc runWithRunQuota*(request: ReproResourceRequest;
                      command: ReproCommandSpec): ReproRunQuotaExecution =
  var client = connectDefault()
  try:
    var session = client.registerSession("reprobuild action", "0.1.0")
    var lease = session.waitForQueuedGrant(request.toRunQuotaRequest())
    result.leaseId = lease.id.value
    try:
      lease.markStarting()
      var child = launchProcess(commandSpec(
        command.argv,
        cwd = command.cwd,
        env = command.env,
        stdoutLimit = command.stdoutLimit,
        stderrLimit = command.stderrLimit))
      lease.markRunning(
        childProcessId = child.info.processId,
        processGroupId = child.info.processGroupId,
        cleanupRegistered = true)
      let completion = child.waitForCompletion()
      child.close()
      lease.finish(
        outcome = finishOutcome(completion),
        exitCode = if completion.exited: uint32(max(completion.exitCode, 0)) else: 0'u32,
        signal = if completion.signaled: uint32(max(completion.signal, 0)) else: 0'u32,
        peakMemoryBytes = completion.peakResidentMemoryBytes,
        processCount = completion.processCount)
      result = ReproRunQuotaExecution(
        leaseId: lease.id.value,
        exitCode: completion.exitCode,
        exited: completion.exited,
        signaled: completion.signaled,
        signal: completion.signal,
        stdout: completion.stdout,
        stderr: completion.stderr,
        stdoutBytes: completion.stdoutBytes,
        stderrBytes: completion.stderrBytes,
        elapsedMillis: completion.elapsedMillis,
        peakResidentMemoryBytes: completion.peakResidentMemoryBytes,
        processCount: completion.processCount,
        backendName: child.info.backend.name,
        leaseFinishedSent: true)
    except CatchableError:
      if lease.active and lease.state == leaseClientStarting:
        lease.finish(outcome = leaseFinishLaunchFailed)
        result.leaseFinishedSent = true
      raise
    finally:
      if lease.active:
        lease.release()
        result.leaseReleased = true
      if session.active:
        session.closeSession()
  except CatchableError as err:
    raise newException(ReproRunQuotaError, err.msg)
  finally:
    client.close()

proc executionFromCompletion(leaseId: uint64; completion: ProcessCompletion;
                             backendName: string; leaseFinishedSent,
                             leaseReleased: bool): ReproRunQuotaExecution =
  ReproRunQuotaExecution(
    leaseId: leaseId,
    exitCode: completion.exitCode,
    exited: completion.exited,
    signaled: completion.signaled,
    signal: completion.signal,
    stdout: completion.stdout,
    stderr: completion.stderr,
    stdoutBytes: completion.stdoutBytes,
    stderrBytes: completion.stderrBytes,
    elapsedMillis: completion.elapsedMillis,
    peakResidentMemoryBytes: completion.peakResidentMemoryBytes,
    processCount: completion.processCount,
    backendName: backendName,
    leaseFinishedSent: leaseFinishedSent,
    leaseReleased: leaseReleased)

proc openRunQuotaSession*(name = "reprobuild action";
                          version = "0.1.0"): ReproRunQuotaSession =
  result = ReproRunQuotaSession()
  try:
    result.client = connectDefault()
    result.session = result.client.registerSession(name, version)
    result.nextCandidateId = 1'u64
    result.active = true
  except CatchableError as err:
    result.client.close()
    raise newException(ReproRunQuotaError, err.msg)

proc close*(session: ReproRunQuotaSession) =
  if session.isNil:
    return
  try:
    if session.active and session.session.active:
      session.session.closeSession()
  finally:
    session.client.close()
    session.active = false

proc startGrantedWithRunQuota(session: ReproRunQuotaSession;
                              lease: RunQuotaLease;
                              command: ReproCommandSpec):
    ReproRunQuotaRunningProcess =
  if not session.active:
    raise newException(ReproRunQuotaError, "runquota session is not active")
  var lease = lease
  try:
    lease.markStarting()
    var child = launchProcess(commandSpec(
      command.argv,
      cwd = command.cwd,
      env = command.env,
      stdoutLimit = command.stdoutLimit,
      stderrLimit = command.stderrLimit))
    lease.markRunning(
      childProcessId = child.info.processId,
      processGroupId = child.info.processGroupId,
      cleanupRegistered = true)
    return ReproRunQuotaRunningProcess(
      lease: lease,
      child: child,
      active: true,
      completed: false)
  except CatchableError:
    if lease.active and lease.state == leaseClientStarting:
      lease.finish(outcome = leaseFinishLaunchFailed)
    if lease.active:
      lease.release()
    raise

proc startWithRunQuota*(session: ReproRunQuotaSession;
                        request: ReproResourceRequest;
                        command: ReproCommandSpec):
    ReproRunQuotaRunningProcess =
  if not session.active:
    raise newException(ReproRunQuotaError, "runquota session is not active")
  try:
    let lease = session.session.waitForQueuedGrant(request.toRunQuotaRequest())
    return session.startGrantedWithRunQuota(lease, command)
  except CatchableError as err:
    raise newException(ReproRunQuotaError, err.msg)

proc offerWithRunQuota*(session: ReproRunQuotaSession;
                        request: ReproResourceRequest;
                        command: ReproCommandSpec): ReproRunQuotaOffer =
  if not session.active:
    raise newException(ReproRunQuotaError, "runquota session is not active")
  try:
    let candidateId = session.nextCandidateId
    inc session.nextCandidateId
    let decisions = session.session.offerCandidates(
      [toCandidate(candidateId, request.toRunQuotaRequest())])
    for decision in decisions:
      if decision.clientCandidateId != candidateId:
        continue
      if decision.lease.active and not decision.queued:
        return ReproRunQuotaOffer(
          kind: rqokStarted,
          running: session.startGrantedWithRunQuota(decision.lease, command))
      if decision.lease.active and decision.queued:
        return ReproRunQuotaOffer(
          kind: rqokQueued,
          queued: ReproRunQuotaQueuedProcess(
            candidateId: candidateId,
            lease: decision.lease,
            command: command,
            active: true))
      raise newException(ReproRunQuotaError,
        "runquota denied lease: " & decision.diagnostic.diagnosticText())
    raise newException(ReproRunQuotaError,
      "runquota did not return a decision for the offered lease")
  except CatchableError as err:
    raise newException(ReproRunQuotaError, err.msg)

proc maxOfferBatchSize*(session: ReproRunQuotaSession): int =
  ## Maximum number of candidates the daemon will accept in a single
  ## OfferCandidates frame. Negotiated at Hello time. Falls back to the
  ## protocol default if the session is not (yet) active.
  if session.isNil or not session.active:
    return int(DefaultMaxCandidatesPerBatch)
  let limit = session.client.flow.maxCandidatesPerBatch
  if limit == 0'u32:
    int(DefaultMaxCandidatesPerBatch)
  else:
    int(limit)

proc offerWithRunQuotaBatch*(session: ReproRunQuotaSession;
                             requests: openArray[ReproResourceRequest];
                             commands: openArray[ReproCommandSpec]):
    seq[ReproRunQuotaOffer] =
  ## Pipelined launch: submit up to ``maxCandidatesPerBatch`` candidates
  ## to the daemon in a single round-trip, then start the granted ones
  ## locally. Returns one offer per input, in the same order. Granted
  ## offers spawn their child process; queued offers carry the lease so
  ## the scheduler can adopt them later via ``pollRunQuotaGrants``.
  ##
  ## This eliminates the previous O(N) round-trip blow-up where the
  ## scheduler waited on every offer response before issuing the next
  ## one — the dominant contributor to the runquota=on vs runquota=off
  ## ratio gap at parallel=32.
  if requests.len != commands.len:
    raise newException(ReproRunQuotaError,
      "runquota batch offer: requests and commands have different lengths")
  if not session.active:
    raise newException(ReproRunQuotaError, "runquota session is not active")
  result = newSeq[ReproRunQuotaOffer](requests.len)
  if requests.len == 0:
    return
  let batchLimit = max(1, session.maxOfferBatchSize())
  var processed = 0
  try:
    while processed < requests.len:
      let chunk = min(batchLimit, requests.len - processed)
      var candidates = newSeq[LeaseCandidate](chunk)
      var candidateIds = newSeq[uint64](chunk)
      for i in 0 ..< chunk:
        let cid = session.nextCandidateId
        inc session.nextCandidateId
        candidateIds[i] = cid
        candidates[i] = toCandidate(cid, requests[processed + i].toRunQuotaRequest())
      let decisions = session.session.offerCandidates(candidates)
      var decisionByCid = initTable[uint64, OfferedLease]()
      for decision in decisions:
        decisionByCid[decision.clientCandidateId] = decision
      for i in 0 ..< chunk:
        let cid = candidateIds[i]
        let inputIndex = processed + i
        if not decisionByCid.hasKey(cid):
          raise newException(ReproRunQuotaError,
            "runquota did not return a decision for offered candidate " & $cid)
        let decision = decisionByCid[cid]
        if decision.lease.active and not decision.queued:
          result[inputIndex] = ReproRunQuotaOffer(
            kind: rqokStarted,
            running: session.startGrantedWithRunQuota(
              decision.lease, commands[inputIndex]))
        elif decision.lease.active and decision.queued:
          result[inputIndex] = ReproRunQuotaOffer(
            kind: rqokQueued,
            queued: ReproRunQuotaQueuedProcess(
              candidateId: cid,
              lease: decision.lease,
              command: commands[inputIndex],
              active: true))
        else:
          raise newException(ReproRunQuotaError,
            "runquota denied lease: " & decision.diagnostic.diagnosticText())
      processed += chunk
  except CatchableError as err:
    raise newException(ReproRunQuotaError, err.msg)

proc pollRunQuotaGrants*(session: ReproRunQuotaSession):
    seq[ReproRunQuotaGrant] =
  if not session.active:
    raise newException(ReproRunQuotaError, "runquota session is not active")
  try:
    for decision in session.session.pollNextGrant():
      result.add(ReproRunQuotaGrant(
        candidateId: decision.clientCandidateId,
        queued: decision.queued,
        active: decision.lease.active,
        diagnostic: decision.diagnostic.diagnosticText(),
        lease: decision.lease))
  except CatchableError as err:
    raise newException(ReproRunQuotaError, err.msg)

proc startGrantedWithRunQuota*(session: ReproRunQuotaSession;
                               queued: var ReproRunQuotaQueuedProcess;
                               grant: ReproRunQuotaGrant):
    ReproRunQuotaRunningProcess =
  if not queued.active:
    raise newException(ReproRunQuotaError, "runquota queued process is not active")
  if grant.candidateId != queued.candidateId:
    raise newException(ReproRunQuotaError, "runquota grant candidate mismatch")
  if not grant.active or grant.queued:
    raise newException(ReproRunQuotaError,
      "runquota denied queued lease: " & grant.diagnostic)
  queued.active = false
  session.startGrantedWithRunQuota(grant.lease, queued.command)

proc cancelQueued*(queued: var ReproRunQuotaQueuedProcess) =
  if not queued.active:
    return
  if queued.lease.active:
    queued.lease.release()
  queued.active = false

proc pollCompletion*(running: var ReproRunQuotaRunningProcess): bool =
  if running.completed:
    return true
  if not running.active:
    return false
  running.child.pollCompletion()

proc finishCompleted*(running: var ReproRunQuotaRunningProcess):
    ReproRunQuotaExecution =
  if running.completed:
    return running.execution
  if not running.active:
    raise newException(ReproRunQuotaError, "runquota process is not active")
  try:
    if not running.child.pollCompletion():
      discard running.child.waitForCompletion()
    let completion = running.child.completion
    running.child.close()
    var leaseFinishedSent = false
    var leaseReleased = false
    try:
      running.lease.finish(
        outcome = finishOutcome(completion),
        exitCode = if completion.exited: uint32(max(completion.exitCode, 0)) else: 0'u32,
        signal = if completion.signaled: uint32(max(completion.signal, 0)) else: 0'u32,
        peakMemoryBytes = completion.peakResidentMemoryBytes,
        processCount = completion.processCount)
      leaseFinishedSent = true
    finally:
      if running.lease.active:
        running.lease.release()
        leaseReleased = true
    running.execution = executionFromCompletion(
      running.lease.id.value,
      completion,
      running.child.info.backend.name,
      leaseFinishedSent,
      leaseReleased)
    running.completed = true
    running.active = false
    running.execution
  except CatchableError as err:
    raise newException(ReproRunQuotaError, err.msg)

proc cancelAndWait*(running: var ReproRunQuotaRunningProcess):
    ReproRunQuotaExecution =
  if running.completed:
    return running.execution
  if not running.active:
    raise newException(ReproRunQuotaError, "runquota process is not active")
  try:
    let completion = running.child.cancelAndWait()
    running.child.close()
    var leaseFinishedSent = false
    var leaseReleased = false
    try:
      running.lease.finish(
        outcome = finishOutcome(completion),
        exitCode = if completion.exited: uint32(max(completion.exitCode, 0)) else: 0'u32,
        signal = if completion.signaled: uint32(max(completion.signal, 0)) else: 0'u32,
        peakMemoryBytes = completion.peakResidentMemoryBytes,
        processCount = completion.processCount)
      leaseFinishedSent = true
    finally:
      if running.lease.active:
        running.lease.release()
        leaseReleased = true
    running.execution = executionFromCompletion(
      running.lease.id.value,
      completion,
      running.child.info.backend.name,
      leaseFinishedSent,
      leaseReleased)
    running.completed = true
    running.active = false
    running.execution
  except CatchableError as err:
    raise newException(ReproRunQuotaError, err.msg)

proc executionJson(execution: ReproRunQuotaExecution; runnerError = ""): JsonNode =
  %*{
    "runner_error": runnerError,
    "lease_id": execution.leaseId,
    "exit_code": execution.exitCode,
    "exited": execution.exited,
    "signaled": execution.signaled,
    "signal": execution.signal,
    "stdout": execution.stdout,
    "stderr": execution.stderr,
    "backend_name": execution.backendName,
    "runquota_socket": getEnv("RUNQUOTA_SOCKET", ""),
    "lease_finished_sent": execution.leaseFinishedSent,
    "lease_released": execution.leaseReleased
  }

proc runRunQuotaHelperCli*(args: openArray[string]): int =
  var request = ReproResourceRequest()
  var command = ReproCommandSpec()
  var resultPath = ""
  var i = 0
  while i < args.len:
    case args[i]
    of "--result":
      if i + 1 >= args.len: return 2
      resultPath = args[i + 1]
      i += 2
    of "--label":
      if i + 1 >= args.len: return 2
      request.label = args[i + 1]
      i += 2
    of "--stats":
      if i + 1 >= args.len: return 2
      request.commandStatsId = args[i + 1]
      i += 2
    of "--cpu":
      if i + 1 >= args.len: return 2
      request.cpuMilli = uint32(parseUInt(args[i + 1]))
      i += 2
    of "--mem":
      if i + 1 >= args.len: return 2
      request.memoryBytes = parseUInt(args[i + 1])
      i += 2
    of "--pool":
      if i + 1 >= args.len: return 2
      request.namedPool = args[i + 1]
      i += 2
    of "--pool-units":
      if i + 1 >= args.len: return 2
      request.namedPoolUnits = uint32(parseUInt(args[i + 1]))
      i += 2
    of "--cwd":
      if i + 1 >= args.len: return 2
      command.cwd = args[i + 1]
      i += 2
    of "--stdout-limit":
      if i + 1 >= args.len: return 2
      command.stdoutLimit = parseInt(args[i + 1])
      i += 2
    of "--stderr-limit":
      if i + 1 >= args.len: return 2
      command.stderrLimit = parseInt(args[i + 1])
      i += 2
    of "--env":
      if i + 1 >= args.len: return 2
      command.env.add(args[i + 1])
      i += 2
    of "--":
      if i + 1 >= args.len: return 2
      command.argv = @args[i + 1 .. ^1]
      i = args.len
    else:
      return 2
  if resultPath.len == 0 or command.argv.len == 0:
    return 2
  try:
    writeFile(extendedPath(resultPath), $executionJson(runWithRunQuota(request, command)))
  except CatchableError as err:
    var failed = ReproRunQuotaExecution(
      exitCode: 1,
      exited: true,
      stderr: err.msg,
      backendName: "runquota-client")
    writeFile(extendedPath(resultPath), $executionJson(failed, err.msg))
  0
