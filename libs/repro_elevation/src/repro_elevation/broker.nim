## Broker launch, broker entrypoint, and the parent-side driver
## (M81 deliverables 3, 5, 6, 7).
##
## Per Elevation-And-Privileged-Operations.md "The Privileged-Broker
## Model": the broker is the SAME `repro` binary, re-execed with a
## hidden `--privileged-broker --channel <name> --token <nonce>`
## entrypoint. The parent launches exactly ONE broker when the
## privileged set is non-empty and `repro` is not already elevated
## (Windows: `ShellExecuteEx` with the `runas` verb — one UAC prompt
## on the secure desktop), drives it over the authenticated RBEB
## channel, and the broker exits on `Done`.
##
## Three roles live here:
##
##   * `launchBroker`      — parent: spawn the one elevated child.
##   * `runBrokerSession`  — broker: the `--privileged-broker` loop.
##   * `driveBrokerApply`  — parent: stream operations, collect
##                           results + apply-log records, send Done.
##
## `applyPrivilegedSetInProcess` is the already-elevated fast path:
## the SAME dispatch, no broker, no channel.

import std/[random]

import ./dispatch
import ./elevation_state
import ./errors
import ./fixture_driver
import ./ipc
import ./operations
import ./protocol

const
  BrokerModeFlag* = "--privileged-broker"
  BrokerChannelFlag* = "--channel"
  BrokerTokenFlag* = "--token"
  BrokerProtocolVersion*: uint16 = 1
  BrokerFilePrefixFlag* = "--file-prefix"
    ## Test-only flag: the gate passes the broker the sandbox prefix
    ## for `pokFixtureFile`. In production M69 the broker derives its
    ## sandbox-free system paths from the operation kinds themselves.

var brokerLaunchCounter {.threadvar.}: int
  ## Process-local count of how many brokers this process has
  ## launched. The M81 gate asserts it is EXACTLY 1 per apply with
  ## privileged work — one elevation event, one broker process.

proc brokerLaunchCount*(): int =
  ## How many brokers the parent has spawned in this process. Test
  ## infrastructure for the "exactly one broker" gate assertion.
  brokerLaunchCounter

proc resetBrokerLaunchCount*() =
  ## Test helper: zero the launch counter before an apply so the
  ## gate can assert the per-apply count.
  brokerLaunchCounter = 0

# ---------------------------------------------------------------------------
# Nonce generation. A cryptographically-random hex token; it is on
# the broker's command line and echoed in the Hello frame.
# ---------------------------------------------------------------------------

proc generateNonce*(): string =
  ## 128-bit random hex nonce. Seeded from `urandom` where available
  ## via `randomize()`; this is a local-IPC auth token, not a
  ## long-lived key, so a 128-bit value is ample.
  var r = initRand()
  result = newStringOfCap(32)
  for _ in 0 ..< 32:
    result.add("0123456789abcdef"[r.rand(15)])

# ---------------------------------------------------------------------------
# Apply-log + result aggregation, returned to the parent's caller so
# it can write the unified apply.log and decide the exit code.
# ---------------------------------------------------------------------------

type
  PrivilegedApplyOutcome* = object
    ## The result of applying the privileged set (via the broker OR
    ## the in-process fast path). `applyLog` is the streamed
    ## structured record set the parent folds into `apply.log`.
    results*: seq[OperationResultFrame]
    applyLog*: seq[ApplyLogRecord]
    allApplied*: bool
      ## True only when every operation applied or was a no-op with
      ## no drift / error.

proc summarize(outcome: var PrivilegedApplyOutcome) =
  outcome.allApplied = true
  for r in outcome.results:
    if not r.ok:
      outcome.allApplied = false
      break

# ===========================================================================
# Parent: launch the one broker.
# ===========================================================================

type
  BrokerLaunchResult* = object
    pid*: int
    nonce*: string

when defined(windows):
  type
    HANDLE = pointer
    DWORD = uint32
    BOOL = int32
    LPCWSTR = ptr UncheckedArray[uint16]
    ULONG_PTR = uint

    SHELLEXECUTEINFOW = object
      cbSize: DWORD
      fMask: ULONG_PTR
      hwnd: HANDLE
      lpVerb: LPCWSTR
      lpFile: LPCWSTR
      lpParameters: LPCWSTR
      lpDirectory: LPCWSTR
      nShow: int32
      hInstApp: HANDLE
      lpIDList: pointer
      lpClass: LPCWSTR
      hkeyClass: HANDLE
      dwHotKey: DWORD
      hIcon: HANDLE
      hProcess: HANDLE

  type
    STARTUPINFOW = object
      cb: DWORD
      lpReserved: LPCWSTR
      lpDesktop: LPCWSTR
      lpTitle: LPCWSTR
      dwX, dwY, dwXSize, dwYSize: DWORD
      dwXCountChars, dwYCountChars: DWORD
      dwFillAttribute, dwFlags: DWORD
      wShowWindow, cbReserved2: uint16
      lpReserved2: pointer
      hStdInput, hStdOutput, hStdError: HANDLE

    PROCESS_INFORMATION = object
      hProcess: HANDLE
      hThread: HANDLE
      dwProcessId: DWORD
      dwThreadId: DWORD

  const
    SEE_MASK_NOCLOSEPROCESS: ULONG_PTR = 0x00000040
    SEE_MASK_NO_CONSOLE: ULONG_PTR = 0x00008000
    SEE_MASK_FLAG_NO_UI: ULONG_PTR = 0x00000400
    SW_HIDE: int32 = 0
    ERROR_CANCELLED: DWORD = 1223
    INFINITE: DWORD = 0xFFFFFFFF'u32
    WAIT_OBJECT_0: DWORD = 0
    CREATE_NO_WINDOW: DWORD = 0x08000000

  proc ShellExecuteExW(pExecInfo: ptr SHELLEXECUTEINFOW): BOOL
    {.importc, stdcall, dynlib: "shell32".}

  proc CreateProcessW(lpApplicationName: LPCWSTR;
                      lpCommandLine: ptr UncheckedArray[uint16];
                      lpProcessAttributes: pointer;
                      lpThreadAttributes: pointer;
                      bInheritHandles: BOOL;
                      dwCreationFlags: DWORD;
                      lpEnvironment: pointer;
                      lpCurrentDirectory: LPCWSTR;
                      lpStartupInfo: ptr STARTUPINFOW;
                      lpProcessInformation: ptr PROCESS_INFORMATION): BOOL
    {.importc, stdcall, dynlib: "kernel32".}

  proc GetLastError(): DWORD
    {.importc, stdcall, dynlib: "kernel32".}

  proc GetProcessId(process: HANDLE): DWORD
    {.importc, stdcall, dynlib: "kernel32".}

  proc WaitForSingleObject(handle: HANDLE; ms: DWORD): DWORD
    {.importc, stdcall, dynlib: "kernel32".}

  proc GetExitCodeProcess(process: HANDLE; exitCode: ptr DWORD): BOOL
    {.importc, stdcall, dynlib: "kernel32".}

  proc CloseHandle(h: HANDLE): BOOL
    {.importc, stdcall, dynlib: "kernel32".}

  proc utf16z(s: string): seq[uint16] =
    result = @[]
    var i = 0
    while i < s.len:
      let b0 = uint32(byte(s[i]))
      var cp: uint32
      var adv: int
      if b0 < 0x80: cp = b0; adv = 1
      elif (b0 and 0xE0) == 0xC0 and i + 1 < s.len:
        cp = ((b0 and 0x1F) shl 6) or (uint32(byte(s[i+1])) and 0x3F); adv = 2
      elif (b0 and 0xF0) == 0xE0 and i + 2 < s.len:
        cp = ((b0 and 0x0F) shl 12) or
             ((uint32(byte(s[i+1])) and 0x3F) shl 6) or
             (uint32(byte(s[i+2])) and 0x3F); adv = 3
      else: cp = b0; adv = 1
      if cp <= 0xFFFF: result.add(uint16(cp))
      else:
        let c = cp - 0x10000
        result.add(uint16(0xD800 + (c shr 10)))
        result.add(uint16(0xDC00 + (c and 0x3FF)))
      i += adv
    result.add(0'u16)

  type
    WindowsBrokerProcess* = object
      ## Handle to the launched broker, so the parent can later
      ## confirm the one-shot broker has exited.
      hProcess: HANDLE
      pid: int

  proc quoteArg(s: string): string =
    ## Minimal command-line quoting: wrap an argument containing a
    ## space (the exe path can) in double quotes.
    if s.len > 0 and ' ' notin s:
      s
    else:
      "\"" & s & "\""

  proc brokerParams(nonce: string;
                    extraArgs: openArray[string]): string =
    result = BrokerModeFlag & " " & BrokerChannelFlag & " " &
      quoteArg(pipeNameForNonce(nonce)) & " " & BrokerTokenFlag &
      " " & nonce
    for a in extraArgs:
      result.add(" ")
      result.add(quoteArg(a))

  proc launchBrokerElevated(reproExe, nonce: string;
                            extraArgs: openArray[string]):
      WindowsBrokerProcess =
    ## Launch the ONE broker via `ShellExecuteEx` + the `runas` verb
    ## — the spec's baseline. This raises exactly one UAC prompt on
    ## the secure desktop for a non-elevated parent; a user-declined
    ## prompt surfaces as `ERROR_CANCELLED` -> `EElevationDeclined`.
    let params = brokerParams(nonce, extraArgs)
    var verbW = utf16z("runas")
    var fileW = utf16z(reproExe)
    var paramsW = utf16z(params)
    var info: SHELLEXECUTEINFOW
    info.cbSize = DWORD(sizeof(SHELLEXECUTEINFOW))
    info.fMask = SEE_MASK_NOCLOSEPROCESS or SEE_MASK_NO_CONSOLE or
      SEE_MASK_FLAG_NO_UI
    info.lpVerb = cast[LPCWSTR](addr verbW[0])
    info.lpFile = cast[LPCWSTR](addr fileW[0])
    info.lpParameters = cast[LPCWSTR](addr paramsW[0])
    info.nShow = SW_HIDE
    if ShellExecuteExW(addr info) == 0:
      let err = GetLastError()
      if err == ERROR_CANCELLED:
        raiseElevationDeclined()
      raiseBrokerLaunch("ShellExecuteEx(runas) failed (status " &
        $err & ")")
    if info.hProcess == nil:
      raiseBrokerLaunch("ShellExecuteEx(runas) returned no process handle")
    result.hProcess = info.hProcess
    result.pid = int(GetProcessId(info.hProcess))

  proc launchBrokerInheritingToken(reproExe, nonce: string;
                                   extraArgs: openArray[string]):
      WindowsBrokerProcess =
    ## Launch the broker via `CreateProcess` — the child inherits the
    ## CURRENT process token. Used ONLY when the parent is itself
    ## already elevated: the broker child is then elevated by
    ## inheritance, with no `runas` verb and no prompt. `runas` from
    ## an already-elevated, possibly System-integrity process fails
    ## `ERROR_ACCESS_DENIED`; token inheritance is both correct and
    ## prompt-free here. (For a non-elevated parent the
    ## `ShellExecuteEx`+`runas` path above is the one that elevates.)
    var cmdLine = quoteArg(reproExe) & " " & brokerParams(nonce, extraArgs)
    var cmdW = utf16z(cmdLine)
    var si: STARTUPINFOW
    si.cb = DWORD(sizeof(STARTUPINFOW))
    var pi: PROCESS_INFORMATION
    if CreateProcessW(nil, cast[ptr UncheckedArray[uint16]](addr cmdW[0]),
        nil, nil, 0, CREATE_NO_WINDOW, nil, nil, addr si, addr pi) == 0:
      raiseBrokerLaunch("CreateProcess for the broker failed (status " &
        $GetLastError() & ")")
    discard CloseHandle(pi.hThread)
    result.hProcess = pi.hProcess
    result.pid = int(pi.dwProcessId)

  proc launchBrokerWindows(reproExe, nonce: string;
                           extraArgs: openArray[string]):
      WindowsBrokerProcess =
    ## Launch EXACTLY ONE broker. The launch primitive depends on the
    ## parent's own elevation:
    ##
    ##   * parent NOT elevated  -> `ShellExecuteEx`+`runas`: the
    ##     spec's baseline; raises one UAC prompt; the child runs
    ##     elevated.
    ##   * parent ALREADY elevated -> `CreateProcess`: the child
    ##     inherits the elevated token; no prompt, no `runas`.
    ##
    ## Production `repro` only reaches this proc when the partition
    ## has privileged work; an already-elevated `repro` uses the
    ## in-process fast path and never launches a broker — so the
    ## `CreateProcess` branch is reached only by a forced broker
    ## (the M81 gate's already-elevated topology test).
    if isProcessElevated():
      launchBrokerInheritingToken(reproExe, nonce, extraArgs)
    else:
      launchBrokerElevated(reproExe, nonce, extraArgs)

  proc waitForExit*(p: var WindowsBrokerProcess): int =
    ## Block until the broker exits; return its exit code. The
    ## process handle is closed afterwards.
    discard WaitForSingleObject(p.hProcess, INFINITE)
    var code: DWORD = 0
    discard GetExitCodeProcess(p.hProcess, addr code)
    discard CloseHandle(p.hProcess)
    p.hProcess = nil
    int(code)

  proc brokerProcessId*(p: WindowsBrokerProcess): int = p.pid

  proc OpenProcess(desiredAccess: DWORD; inheritHandle: BOOL;
                   processId: DWORD): HANDLE
    {.importc, stdcall, dynlib: "kernel32".}

  const
    STILL_ACTIVE: DWORD = 259
    PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000

  proc processStillAlive*(pid: int): bool =
    ## True when a process with the given PID is still running.
    ## Used by the gate to prove the one-shot broker has exited.
    if pid == 0:
      return false
    let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, DWORD(pid))
    if h == nil:
      return false                     # gone (or never existed)
    defer: discard CloseHandle(h)
    var code: DWORD = 0
    if GetExitCodeProcess(h, addr code) == 0:
      return false
    code == STILL_ACTIVE

  proc launchBrokerForGate*(reproExe, nonce: string;
                            filePrefix = ""): WindowsBrokerProcess =
    ## Launch ONE broker WITHOUT driving the channel — used by the
    ## M81 gate's auth / closed-set scenarios, which drive the RBEB
    ## conversation by hand. Production code uses `launchAndDriveBroker`.
    var extra: seq[string]
    if filePrefix.len > 0:
      extra.add(BrokerFilePrefixFlag)
      extra.add(filePrefix)
    result = launchBrokerWindows(reproExe, nonce, extra)
    inc brokerLaunchCounter

else:
  type
    WindowsBrokerProcess* = object
      pid: int

  proc launchBrokerWindows(reproExe, nonce: string;
                           extraArgs: openArray[string]):
      WindowsBrokerProcess =
    raiseNotImplementedPlatform("ShellExecuteEx(runas) broker launch")

  proc waitForExit*(p: var WindowsBrokerProcess): int =
    raiseNotImplementedPlatform("broker waitForExit")

  proc brokerProcessId*(p: WindowsBrokerProcess): int = p.pid

  proc processStillAlive*(pid: int): bool =
    raiseNotImplementedPlatform("processStillAlive")

  proc launchBrokerForGate*(reproExe, nonce: string;
                            filePrefix = ""): WindowsBrokerProcess =
    raiseNotImplementedPlatform("launchBrokerForGate")

# ===========================================================================
# Parent: drive the broker over the authenticated channel.
# ===========================================================================

proc driveBrokerApply*(ch: var ElevationChannel; nonce: string;
                       planned: openArray[PlannedOperation]):
    PrivilegedApplyOutcome =
  ## PARENT side of the RBEB conversation. Performs the
  ## `Hello`/`HelloAck` handshake (sending the nonce), streams each
  ## planned operation, collects its `ApplyLogRecord` + the
  ## `OperationResult`, then sends `Done`. The broker exits on
  ## `Done`.
  ch.sendFrame(encodeHello(HelloFrame(
    protocolVersion: BrokerProtocolVersion, nonce: nonce)))
  let ackFrame = ch.recvFrame()
  if ackFrame.messageType != rmtHelloAck:
    raiseProtocol("expected HelloAck, got message type " &
      $ackFrame.messageType)
  let ack = decodeHelloAck(ackFrame.body)
  if not ack.accepted:
    raiseChannelAuth("the broker rejected the handshake: " & ack.reason)
  if ack.protocolVersion != BrokerProtocolVersion:
    raiseProtocol("broker speaks RBEB protocol version " &
      $ack.protocolVersion & ", parent speaks " & $BrokerProtocolVersion)

  for plannedOp in planned:
    ch.sendFrame(encodeOperation(plannedOp))
    # Per operation the broker streams an ApplyLogRecord then an
    # OperationResult. Read until we have the result.
    var gotResult = false
    while not gotResult:
      let frame = ch.recvFrame()
      case frame.messageType
      of rmtApplyLogRecord:
        result.applyLog.add(decodeApplyLogRecord(frame.body))
      of rmtOperationResult:
        result.results.add(decodeOperationResult(frame.body))
        gotResult = true
      else:
        raiseProtocol("unexpected frame type " & $frame.messageType &
          " while awaiting an operation result")
  ch.sendFrame(encodeDone())
  summarize(result)

# ===========================================================================
# Parent: the full broker apply — launch ONE broker, drive it, wait
# for it to exit. This is the orchestration `repro infra apply` (M69)
# will call when the partition has privileged work and `repro` is not
# already elevated.
# ===========================================================================

type
  BrokerApplyResult* = object
    ## The outcome of a full broker-mediated privileged apply.
    outcome*: PrivilegedApplyOutcome
    brokerPid*: int
    brokerExitCode*: int

proc launchAndDriveBroker*(reproExe: string;
                           planned: openArray[PlannedOperation];
                           filePrefix = ""): BrokerApplyResult =
  ## PARENT: the complete one-broker apply.
  ##
  ##   1. mint a nonce and create the authenticated named pipe
  ##   2. launch EXACTLY ONE broker (`ShellExecuteEx`+`runas`)
  ##   3. accept the broker's connect-back, verifying its peer SID
  ##   4. drive the RBEB conversation (handshake, operations, Done)
  ##   5. wait for the one-shot broker to exit
  ##
  ## Raises `EElevationDeclined` if the user declines the prompt
  ## (the caller treats that as `--no-elevate`), `EBrokerLaunch` /
  ## `EBrokerLost` / `EChannelAuth` on the respective failures.
  let nonce = generateNonce()
  var ch = createListeningChannel(nonce)
  var channelClosed = false
  defer:
    if not channelClosed:
      ch.close()
  var extraArgs: seq[string]
  if filePrefix.len > 0:
    extraArgs.add(BrokerFilePrefixFlag)
    extraArgs.add(filePrefix)
  var proc0 = launchBrokerWindows(reproExe, nonce, extraArgs)
  inc brokerLaunchCounter
  result.brokerPid = brokerProcessId(proc0)
  acceptAuthenticatedClient(ch)
  result.outcome = driveBrokerApply(ch, nonce, planned)
  ch.close()
  channelClosed = true
  result.brokerExitCode = waitForExit(proc0)

# ===========================================================================
# Broker: the --privileged-broker session loop.
# ===========================================================================

proc runBrokerSession*(nonce: string; ctx: FixtureContext): int =
  ## BROKER side. Connects back to the parent, authenticates the
  ## nonce, then services `Operation` frames until `Done`. Each
  ## operation is dispatched through `dispatch.dispatchOperation`
  ## (the closed-set, re-observe / drift-checked path); the broker
  ## streams back an `ApplyLogRecord` then an `OperationResult`. It
  ## is one-shot: it returns (and the process exits) on `Done` or a
  ## channel drop.
  ##
  ## Returns the broker process exit code: 0 = clean.
  var ch = connectToParent(nonce)
  defer: ch.close()

  # Handshake: the parent's Hello must echo the nonce the broker was
  # launched with. A mismatch means an unrelated process connected —
  # reject and exit.
  let helloFrame = ch.recvFrame()
  if helloFrame.messageType != rmtHello:
    ch.sendFrame(encodeHelloAck(HelloAckFrame(accepted: false,
      protocolVersion: BrokerProtocolVersion,
      reason: "first frame was not Hello")))
    return 3
  let hello = decodeHello(helloFrame.body)
  if hello.nonce != nonce:
    ch.sendFrame(encodeHelloAck(HelloAckFrame(accepted: false,
      protocolVersion: BrokerProtocolVersion,
      reason: "nonce mismatch — refusing to serve an unauthenticated peer")))
    return 4
  ch.sendFrame(encodeHelloAck(HelloAckFrame(accepted: true,
    protocolVersion: BrokerProtocolVersion, reason: "")))

  var hadFailure = false
  while true:
    let frame = ch.recvFrame()
    case frame.messageType
    of rmtDone:
      break
    of rmtOperation:
      # `decodeOperation` rejects any frame that is not a recognized
      # typed PrivilegedOperation (closed-set guard) — that rejection
      # is an `EProtocol` and is caught here so the broker REPORTS
      # the rejection rather than crashing. The decoded
      # `WireOperation` carries the parent's plan baseline digest so
      # the broker's re-observe / drift gate distinguishes a safe
      # update from a genuine mid-flight drift.
      var dr: DispatchResult
      var resultFrame: OperationResultFrame
      var opAddress = ""
      var opKind = ""
      try:
        let wireOp = decodeOperation(frame.body)
        opAddress = wireOp.operation.address
        opKind = $wireOp.operation.kind
        dr = dispatchOperation(ctx, wireOp)
        resultFrame = toOperationResult(dr)
        ch.sendFrame(encodeApplyLogRecord(toApplyLogRecord(dr)))
      except EBrokerDrift as e:
        hadFailure = true
        ch.sendFrame(encodeApplyLogRecord(ApplyLogRecord(
          operationAddress: e.operationAddress,
          operationKind: e.operationKind,
          outcome: $doDrift,
          detail: e.msg,
          preWriteDigestHex: e.observedDigestHex,
          postWriteDigestHex: "")))
        resultFrame = OperationResultFrame(
          operationAddress: e.operationAddress,
          ok: false, driftDetected: true, diagnostic: e.msg)
      except EProtocol as e:
        # A frame that is not a recognized typed PrivilegedOperation,
        # or one that carries a sandbox-escape payload. The broker
        # REJECTS it — it executed nothing — and reports the
        # rejection rather than crashing.
        hadFailure = true
        ch.sendFrame(encodeApplyLogRecord(ApplyLogRecord(
          operationAddress: opAddress,
          operationKind: opKind,
          outcome: $doError,
          detail: "rejected: " & e.msg)))
        resultFrame = OperationResultFrame(
          operationAddress: opAddress,
          ok: false, driftDetected: false,
          diagnostic: "rejected non-PrivilegedOperation frame: " & e.msg)
      except CatchableError as e:
        hadFailure = true
        ch.sendFrame(encodeApplyLogRecord(ApplyLogRecord(
          operationAddress: opAddress,
          operationKind: opKind,
          outcome: $doError, detail: e.msg)))
        resultFrame = OperationResultFrame(
          operationAddress: opAddress,
          ok: false, driftDetected: false, diagnostic: e.msg)
      ch.sendFrame(encodeOperationResult(resultFrame))
    else:
      # Any other frame type at the request position is a protocol
      # violation — reject and stop.
      ch.sendFrame(encodeOperationResult(OperationResultFrame(
        operationAddress: "",
        ok: false, driftDetected: false,
        diagnostic: "unexpected frame type " & $frame.messageType)))
      return 5
  return (if hadFailure: 1 else: 0)

# ===========================================================================
# Already-elevated fast path: same dispatch, no broker.
# ===========================================================================

proc applyPrivilegedSetInProcess*(ctx: FixtureContext;
                                  planned: openArray[PlannedOperation]):
    PrivilegedApplyOutcome =
  ## The already-elevated fast path (deliverable 2). `repro` already
  ## holds an elevated token, so the privileged set runs in-process
  ## through the SAME `dispatchOperation` the broker uses — no
  ## broker, no channel, no prompt. Drift and closed-set checks are
  ## identical.
  for plannedOp in planned:
    var dr: DispatchResult
    try:
      dr = dispatchOperation(ctx, plannedOp)
      result.applyLog.add(toApplyLogRecord(dr))
      result.results.add(toOperationResult(dr))
    except EBrokerDrift as e:
      result.applyLog.add(ApplyLogRecord(
        operationAddress: e.operationAddress,
        operationKind: e.operationKind,
        outcome: $doDrift, detail: e.msg,
        preWriteDigestHex: e.observedDigestHex))
      result.results.add(OperationResultFrame(
        operationAddress: e.operationAddress,
        ok: false, driftDetected: true, diagnostic: e.msg))
    except CatchableError as e:
      result.applyLog.add(ApplyLogRecord(
        operationAddress: plannedOp.operation.address,
        operationKind: $plannedOp.operation.kind,
        outcome: $doError, detail: e.msg))
      result.results.add(OperationResultFrame(
        operationAddress: plannedOp.operation.address,
        ok: false, driftDetected: false, diagnostic: e.msg))
  summarize(result)

# ===========================================================================
# --no-elevate / declined-prompt: report every privileged op skipped.
# ===========================================================================

proc reportPrivilegedSetSkipped*(planned: openArray[PlannedOperation]):
    PrivilegedApplyOutcome =
  ## `--no-elevate` (deliverable 6) and the user-declined-prompt path
  ## (which the spec makes equivalent): the non-privileged subset is
  ## applied elsewhere; here every privileged operation is reported
  ## skipped with `EElevationRequired` context. Nothing is mutated.
  for plannedOp in planned:
    let op = plannedOp.operation
    result.results.add(OperationResultFrame(
      operationAddress: op.address,
      ok: false, driftDetected: false,
      diagnostic: "skipped: requires elevation (EElevationRequired); " &
        "re-run without --no-elevate, or accept the elevation prompt"))
    result.applyLog.add(ApplyLogRecord(
      operationAddress: op.address,
      operationKind: $op.kind,
      outcome: "skipped",
      detail: "privileged operation skipped (no elevation)"))
  result.allApplied = false

# ===========================================================================
# Broker-mode command-line parsing (for the repro --privileged-broker
# entrypoint).
# ===========================================================================

type
  BrokerModeArgs* = object
    isBrokerMode*: bool
    channel*: string
    token*: string
    filePrefix*: string

proc parseBrokerModeArgs*(args: openArray[string]): BrokerModeArgs =
  ## Parse `--privileged-broker --channel <name> --token <nonce>
  ## [--file-prefix <dir>]`. Returns `isBrokerMode == false` when the
  ## first arg is not `--privileged-broker`.
  if args.len == 0 or args[0] != BrokerModeFlag:
    result.isBrokerMode = false
    return
  result.isBrokerMode = true
  var i = 1
  while i < args.len:
    case args[i]
    of BrokerChannelFlag:
      if i + 1 >= args.len:
        raiseProtocol("--channel requires a value")
      result.channel = args[i + 1]
      i += 2
    of BrokerTokenFlag:
      if i + 1 >= args.len:
        raiseProtocol("--token requires a value")
      result.token = args[i + 1]
      i += 2
    of BrokerFilePrefixFlag:
      if i + 1 >= args.len:
        raiseProtocol("--file-prefix requires a value")
      result.filePrefix = args[i + 1]
      i += 2
    else:
      raiseProtocol("unknown privileged-broker argument '" & args[i] & "'")
  if result.token.len == 0:
    raiseProtocol("--privileged-broker requires a --token nonce")
