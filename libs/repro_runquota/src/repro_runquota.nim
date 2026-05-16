import std/[json, strutils]

import runquota_client
import runquota_codec
import runquota_core
import runquota_exec

type
  ReproRunQuotaError* = object of CatchableError

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

proc effectiveCpu(request: ReproResourceRequest): uint32 =
  if request.cpuMilli == 0'u32: 1000'u32 else: request.cpuMilli

proc effectiveMemory(request: ReproResourceRequest): uint64 =
  if request.memoryBytes == 0'u64: 128'u64 * 1024'u64 * 1024'u64
  else: request.memoryBytes

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

proc runWithRunQuota*(request: ReproResourceRequest;
                      command: ReproCommandSpec): ReproRunQuotaExecution =
  var client = connectDefault()
  try:
    var session = client.registerSession("reprobuild action", "0.1.0")
    try:
      let execution = session.runWithLease(
        request.toRunQuotaRequest(),
        command.argv,
        cwd = command.cwd,
        env = command.env,
        stdoutLimit = command.stdoutLimit,
        stderrLimit = command.stderrLimit)
      result = ReproRunQuotaExecution(
        leaseId: execution.leaseId,
        exitCode: execution.process.exitCode,
        exited: execution.process.exited,
        signaled: execution.process.signaled,
        signal: execution.process.signal,
        stdout: execution.process.stdout,
        stderr: execution.process.stderr,
        stdoutBytes: execution.stdoutBytes,
        stderrBytes: execution.stderrBytes,
        elapsedMillis: execution.process.elapsedMillis,
        peakResidentMemoryBytes: execution.process.peakResidentMemoryBytes,
        processCount: execution.process.processCount,
        backendName: execution.backend.name,
        leaseFinishedSent: execution.leaseFinishedSent,
        leaseReleased: execution.leaseReleased)
    finally:
      if session.active:
        session.closeSession()
  except CatchableError as err:
    raise newException(ReproRunQuotaError, err.msg)
  finally:
    client.close()

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
    writeFile(resultPath, $executionJson(runWithRunQuota(request, command)))
  except CatchableError as err:
    var failed = ReproRunQuotaExecution(
      exitCode: 1,
      exited: true,
      stderr: err.msg,
      backendName: "runquota-client")
    writeFile(resultPath, $executionJson(failed, err.msg))
  0
