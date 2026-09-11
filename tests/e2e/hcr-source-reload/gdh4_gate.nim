## GDH-M4 gate driver — the coordinator half.
##
## Design: `codetracer-specs/Planned-Features/`
##         `GDScript-Hot-Reload-Multi-Version-Sources.md` §4.2-§4.4.
## Milestone: the `GDH-M4` block, gates `gdh4_second_reload_is_distinct` and
##            `gdh4_unnegotiated_capability_is_refused_not_ignored`.
##
## `allowed_mocks: none`. The peer is a real process
## (`gdh4_source_reload_host.c`) linking the production C agent; the transport
## is a real `AF_UNIX` socket; the framing and the message types are the
## production `repro_hcr_agent` ones.
##
## Harness rules this file is written to (see
## `codetracer-specs/Testing/Verification-Harness-Traps.md`):
##
##   * **A missing reply is diagnosed, never waited out.** Every read is
##     preceded by a `poll(2)` with an explicit bound, and the three outcomes —
##     a frame arrived, the bound elapsed, the peer closed — are three
##     DIFFERENT named verdicts. A gate that "detected" the one-shot agent by
##     hanging would not have distinguished it from a driver bug (trap 1/3), so
##     this driver never blocks on a socket read at all.
##   * **Both directions are logged.** The full transcript is printed on every
##     failure, so a reply that did not arrive can be seen not to have been
##     sent (the milestone's `anti_vacuity` for arm 2).
##   * **The wire is not graded by the wire.** Each applied generation is also
##     checked against the host's own stdout report and against the file the
##     host wrote, so the acknowledgement is not the only witness (trap 2).
##   * **`SIGPIPE` is ignored** so that a host which closed the socket produces
##     a catchable error with a name, rather than killing this process with a
##     signal that no verdict could be attached to.

import std/[json, net, os, osproc, posix, streams, strtabs, strutils, times]

import repro_hcr_agent

type
  GateError = object of CatchableError
    gate: string

  ReadOutcome = enum
    roMessage
    roTimedOut
    roPeerClosed
    roProtocolError
      ## The host sent a frame the protocol REFUSES. This is a verdict about
      ## the host, so it must be a red GATE and not a `DRIVER-FAIL` — the two
      ## are kept apart everywhere in this file because a harness that reports
      ## its own bug as a caught defect is how a mutation arm gets counted as
      ## killed without ever having run.

  ReadResult = object
    outcome: ReadOutcome
    message: HcrAgentMessage
    detail: string

const
  ReplyBoundMs = 5000
    ## How long a `sourceReloadResult` is allowed to take. The bound exists so
    ## that "no reply" is a MEASUREMENT with a number attached, not the absence
    ## of one.
  SourcePath = "res://gdh4/probe.gd"

var transcriptLines: seq[string] = @[]

let verbose = getEnv("GDH4_VERBOSE", "").len > 0

proc note(direction, summary: string) =
  transcriptLines.add direction & " " & summary
  if verbose:
    stderr.writeLine "[gdh4] " & direction & " " & summary

proc trace(what: string) =
  if verbose:
    stderr.writeLine "[gdh4] . " & what

proc dumpTranscript() =
  stderr.writeLine "  --- socket transcript (" & $transcriptLines.len &
    " frames, both directions) ---"
  if transcriptLines.len == 0:
    stderr.writeLine "  (empty: not one frame crossed the socket in either " &
      "direction, so the handshake itself did not happen)"
  for line in transcriptLines:
    stderr.writeLine "  " & line

proc gateFail(gate, message: string) =
  ## Every failure carries the gate it belongs to, so an arm can be required to
  ## go red IN THE GATE IT IS AIMED AT rather than anywhere at all.
  var err = newException(GateError, "GDH4-FAIL[" & gate & "]: " & message)
  err.gate = gate
  raise err

proc waitReadable(sock: Socket; timeoutMs: int): bool =
  trace("poll for readability, bound " & $timeoutMs & " ms")
  var pfd = TPollfd(fd: sock.getFd().cint, events: POLLIN, revents: 0)
  var remaining = timeoutMs
  while true:
    let started = epochTime()
    let rc = poll(addr pfd, Tnfds(1), remaining.cint)
    if rc > 0:
      trace("poll -> readable, revents=" & $pfd.revents)
      return true
    if rc == 0:
      trace("poll -> bound elapsed")
      return false
    if errno != EINTR:
      trace("poll -> error errno=" & $errno)
      return false
    trace("poll -> EINTR")
    remaining -= int((epochTime() - started) * 1000.0)
    if remaining <= 0:
      return false

proc readWithBound(conn: HcrAgentSocketConnection; client: var HcrCoordinatorClient;
                   boundMs: int): ReadResult =
  if not waitReadable(conn.socket, boundMs):
    return ReadResult(outcome: roTimedOut,
      detail: "no frame became readable within " & $boundMs &
        " ms; the host is alive and silent")
  try:
    let message = client.receiveAgentMessage(conn)
    note("host -> coordinator", message.kind.kindName)
    ReadResult(outcome: roMessage, message: message)
  except IOError as err:
    ReadResult(outcome: roPeerClosed,
      detail: "the host closed the connection: " & err.msg)
  except OSError as err:
    ReadResult(outcome: roPeerClosed,
      detail: "the host's socket errored: " & err.msg)
  except ValueError as err:
    note("host -> coordinator", "REFUSED BY THE PROTOCOL")
    ReadResult(outcome: roProtocolError,
      detail: "the host sent a frame the protocol refuses: " & err.msg)

proc boundSocket(sock: Socket; boundMs: int) =
  ## Put a hard ceiling on every blocking socket operation this driver makes.
  ##
  ## This is not belt-and-braces, it is the fix for a measured defect in an
  ## EARLIER version of this very file. With the one-shot-poll falsifier arm in
  ## place, the host closes the socket after the first notification; the
  ## driver's next `send` then spun at 99% CPU inside `std/net` and the arm
  ## was recorded as **rc 124**. Traps 1 and 3 are explicit that a hang is not
  ## a diagnosis and that an arm which "detects" a defect by hanging has not
  ## been distinguished from a driver bug — so the arm was a CHECK-FAIL, not a
  ## kill, until this bound existed. Every socket wait in this driver is now
  ## bounded, and the bound's expiry is a NAMED verdict.
  var tv = Timeval(tv_sec: posix.Time(boundMs div 1000),
                   tv_usec: Suseconds((boundMs mod 1000) * 1000))
  let fd = sock.getFd()
  discard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, addr tv, SockLen(sizeof(tv)))
  discard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, addr tv, SockLen(sizeof(tv)))

proc peerRevents(sock: Socket): cshort =
  ## `POLLHUP` / `POLLERR` are reported whether or not they were requested, so
  ## this answers "is the peer still there" without consuming anything.
  var pfd = TPollfd(fd: sock.getFd().cint, events: POLLOUT, revents: 0)
  if poll(addr pfd, Tnfds(1), 0.cint) <= 0:
    return 0
  pfd.revents

proc sendChecked(conn: HcrAgentSocketConnection; client: var HcrCoordinatorClient;
                 message: HcrAgentMessage; gate: string) =
  let revents = peerRevents(conn.socket)
  if (revents and (POLLHUP or POLLERR or POLLNVAL)) != 0:
    note("coordinator -> host", message.kind.kindName & " (NOT SENT: peer gone)")
    gateFail(gate,
      "the host had already closed the connection when a " &
        message.kind.kindName & " was due to be sent (poll revents=" &
        $revents & ", POLLHUP=" & $POLLHUP & "). The session served fewer " &
        "messages than the gate sent: this is the one-patch-per-process " &
        "limit, observed as a NAMED closed socket rather than as a stall.")
  try:
    client.sendCoordinatorMessage(conn, message)
    note("coordinator -> host", message.kind.kindName)
  except OSError as err:
    # A closed peer is reported by NAME here. Without the SIGPIPE disposition
    # below this would have been a signal death with no verdict attached.
    note("coordinator -> host", message.kind.kindName & " (SEND FAILED)")
    gateFail(gate,
      "the host closed the connection before a " & message.kind.kindName &
        " could be sent (" & err.msg & "). The session served fewer messages " &
        "than the gate sent, which is the one-patch-per-process limit.")

proc requireMessage(res: ReadResult; gate, what: string): HcrAgentMessage =
  case res.outcome
  of roMessage:
    res.message
  of roTimedOut:
    gateFail(gate,
      "NO REPLY to " & what & " — " & res.detail &
        ". Design §4.4: an ignored notification is worse than a refused " &
        "session, and this is that failure observed. This is a named " &
        "absence-of-reply, not a hang: the driver bounded the wait and " &
        "returned.")
    res.message
  of roPeerClosed:
    gateFail(gate,
      "NO REPLY to " & what & " — " & res.detail &
        ". The reply was not sent; the transcript below shows what did cross " &
        "the socket in each direction.")
    res.message
  of roProtocolError:
    gateFail(gate, "the reply to " & what & " is not a valid message — " &
      res.detail)
    res.message

# ---------------------------------------------------------------------------
# Fixtures.
#
# v2 and v3 have the SAME line count and different content, deliberately. §4.3
# calls `lineTableDigest` "not decorative" precisely because a scheme keyed on
# line counts or path indices alone would look right on this pair and be wrong.
# The only things that distinguish these two generations are the bytes and the
# line-start offsets.
# ---------------------------------------------------------------------------

const SourceV2 = """extends Node

var counter := 0

func tick() -> int:
	counter += 2
	return counter
"""

const SourceV3 = """extends Node

var counter := 0

func tick() -> int:
	counter += 30303
	return counter * 7
"""

proc bytesOf(text: string): seq[byte] = bytesOfString(text)

proc changedFor(reloadId: string; generation: uint32;
                text: string): HcrSourceChanged =
  HcrSourceChanged(
    reloadId: reloadId,
    language: "gdscript",
    changedFiles: @[sourceChangedFile(SourcePath, generation, bytesOf(text))])

type
  HostRun = object
    listener: HcrAgentUnixListener
    conn: HcrAgentSocketConnection
    process: Process
    client: HcrCoordinatorClient
    applyDir: string

proc startHost(workDir, hostBin: string; advertiseReload: bool;
               gate: string): HostRun =
  createDir(workDir)
  result.applyDir = workDir / "applied"
  createDir(result.applyDir)
  # `sun_path` is 108 bytes, and a work dir under a long scratch root silently
  # exceeds it. The socket therefore lives in a SHORT directory chosen here,
  # and the length is asserted loudly rather than discovered as a bind failure
  # with no explanation.
  let socketBase = block:
    var candidate = getEnv("GDH4_SOCKET_DIR", "")
    if candidate.len == 0:
      candidate = getEnv("XDG_RUNTIME_DIR", "")
    if candidate.len == 0 or not dirExists(candidate):
      candidate = "/tmp"
    candidate
  # One socket per gate process; each mode runs in its own process, so the pid
  # is already unique per arm.
  let socketPath = socketBase / ("gdh4-" & $getCurrentProcessId() & ".sock")
  if socketPath.len >= 100:
    gateFail(gate, "the agent socket path is " & $socketPath.len &
      " bytes, which sun_path (108) cannot hold: " & socketPath &
      ". Set GDH4_SOCKET_DIR to a short directory.")
  removeFile(socketPath)
  result.listener = listenHcrAgentUnixSocket(socketPath)

  var env = newStringTable()
  for key, value in envPairs():
    env[key] = value
  env[ReproHcrAgentSocketEnv] = socketPath
  env["GDH4_APPLY_DIR"] = result.applyDir
  env["GDH4_MAX_WAIT_MS"] = "15000"
  if not advertiseReload:
    env["GDH4_NO_SOURCE_RELOAD"] = "1"
  else:
    env.del("GDH4_NO_SOURCE_RELOAD")

  result.process = startProcess(hostBin, workingDir = workDir, env = env,
    options = {poStdErrToStdOut})
  result.conn = acceptHcrAgentConnection(result.listener)
  boundSocket(result.conn.socket, ReplyBoundMs)
  result.client = initHcrCoordinatorClient(defaultDirectSupportProfile())

  # ---- anti-vacuity: the HANDSHAKE must have completed before any claim
  # about what the host did or did not answer. A host that failed to connect
  # also sends no reply, and the two must not be conflated.
  let hello = requireMessage(
    readWithBound(result.conn, result.client, ReplyBoundMs), gate,
    "the agent hello")
  if hello.kind != hmkHello:
    gateFail(gate, "the first frame was " & hello.kind.kindName & ", not hello")
  if result.client.session.state != hssAgentHelloReceived:
    gateFail(gate, "the session did not reach hssAgentHelloReceived")
  if not hello.hello.capabilities.contains("hcr-agent-protocol"):
    gateFail(gate, "the host did not advertise hcr-agent-protocol")

  sendChecked(result.conn, result.client,
    result.client.coordinatorHelloAckMessage(), gate)
  if result.client.session.state != hssNegotiated:
    gateFail(gate, "the session did not reach hssNegotiated after helloAck")

proc finish(run: var HostRun): tuple[output: string, exitCode: int] =
  run.conn.close()
  run.listener.close()
  result.output = run.process.outputStream.readAll()
  result.exitCode = run.process.waitForExit()
  run.process.close()

proc hostReport(output, gate: string): JsonNode =
  let trimmed = output.strip()
  if trimmed.len == 0:
    gateFail(gate, "the host printed nothing; there is no independent " &
      "account of the session to check the wire against")
  let braceAt = trimmed.find('{')
  if braceAt < 0:
    gateFail(gate, "the host's stdout is not JSON: " & trimmed)
  try:
    parseJson(trimmed[braceAt .. ^1])
  except JsonParsingError as err:
    gateFail(gate, "the host's stdout is not parseable JSON (" & err.msg &
      "): " & trimmed)
    newJNull()

proc expectApplied(res: HcrSourceReloadResult; gate, what: string):
    HcrSourceReloadAppliedFile =
  if res.outcome != hsroApplied:
    var detail = ""
    for refused in res.refusedFiles:
      detail.add " [" & refused.sourcePath & ": " & refused.reason & " — " &
        refused.detail & "]"
    gateFail(gate, what & " was not applied: outcome=" & $res.outcome &
      " reason=" & res.reason & detail)
  # `parseSourceReloadResult` already refuses `applied` with an empty
  # `appliedFiles`, but a gate that relied on a parser invariant it did not
  # state would pass for free if that invariant were ever relaxed.
  if res.appliedFiles.len != 1:
    gateFail(gate, what & " reported " & $res.appliedFiles.len &
      " applied files; exactly 1 was sent")
  res.appliedFiles[0]

# ---------------------------------------------------------------------------
# gdh4_second_reload_is_distinct
# ---------------------------------------------------------------------------

proc runTwoReloads(workDir, hostBin: string; expectedNotifications: int) =
  const gate = "gdh4_second_reload_is_distinct"
  var run = startHost(workDir, hostBin, advertiseReload = true, gate = gate)

  if not run.client.session.hostAdvertisedSourceReload():
    gateFail(gate, "the host did not advertise " & HcrSourceReloadCapability &
      "; this gate is about a host that CAN reload")

  let changed2 = changedFor("gdh4-r-0002", 2'u32, SourceV2)
  sendChecked(run.conn, run.client,
    run.client.coordinatorSourceChangedMessage(changed2), gate)
  let msg2 = requireMessage(readWithBound(run.conn, run.client, ReplyBoundMs),
    gate, "the FIRST sourceChanged (generation 2)")
  if msg2.kind != hmkSourceReloadResult:
    gateFail(gate, "expected sourceReloadResult, got " & msg2.kind.kindName)
  let applied2 = expectApplied(msg2.sourceReloadResult, gate,
    "the first notification")
  trace("first notification applied, generation " & $applied2.generation)

  # The second notification is the whole gate. One reload is the case the
  # pre-GDH-M4 implementation accidentally handled and the case in which a
  # hardcoded generation is coincidentally correct (design §4.2).
  let changed3 = changedFor("gdh4-r-0003", 3'u32, SourceV3)
  trace("built the second notification")
  sendChecked(run.conn, run.client,
    run.client.coordinatorSourceChangedMessage(changed3), gate)
  let msg3 = requireMessage(readWithBound(run.conn, run.client, ReplyBoundMs),
    gate, "the SECOND sourceChanged (generation 3)")
  if msg3.kind != hmkSourceReloadResult:
    gateFail(gate, "expected sourceReloadResult, got " & msg3.kind.kindName)
  let applied3 = expectApplied(msg3.sourceReloadResult, gate,
    "the second notification")

  # ---- distinctness, the three axes the milestone names.
  if msg2.sourceReloadResult.reloadId == msg3.sourceReloadResult.reloadId:
    gateFail(gate, "both acknowledgements carry reloadId " &
      msg2.sourceReloadResult.reloadId)
  if applied2.generation == applied3.generation:
    gateFail(gate, "both acknowledgements carry generation " &
      $applied2.generation & "; a session that serves two reloads must " &
      "distinguish them")
  if applied2.generation != 2'u32:
    gateFail(gate, "the first acknowledgement carries generation " &
      $applied2.generation & ", expected 2")
  if applied3.generation != 3'u32:
    gateFail(gate, "the second acknowledgement carries generation " &
      $applied3.generation & ", expected 3")
  if applied2.appliedDigest == applied3.appliedDigest:
    gateFail(gate, "both acknowledgements carry appliedDigest " &
      applied2.appliedDigest & ", so the host applied the same bytes twice " &
      "or did not look at them at all")

  # ---- the digests are the HOST's recomputation over what it stored, and the
  # gate checks them against what the coordinator sent. Equality here is what
  # makes the distinctness above mean "two different versions" rather than
  # "two different arbitrary strings".
  let expected2 = sourceSnapshotDigest(bytesOf(SourceV2))
  let expected3 = sourceSnapshotDigest(bytesOf(SourceV3))
  if expected2 == expected3:
    gateFail(gate, "the two fixtures hash the same; the fixture pair cannot " &
      "distinguish anything and this gate would pass for free")
  if applied2.appliedDigest != expected2:
    gateFail(gate, "generation 2 was acknowledged with " &
      applied2.appliedDigest & " but the bytes sent hash to " & expected2)
  if applied3.appliedDigest != expected3:
    gateFail(gate, "generation 3 was acknowledged with " &
      applied3.appliedDigest & " but the bytes sent hash to " & expected3)

  # ---- §4.3's lineTableDigest case: the two generations have the SAME line
  # count, so anything keyed on the count alone cannot tell them apart.
  if sourceLineCount(bytesOf(SourceV2)) != sourceLineCount(bytesOf(SourceV3)):
    gateFail(gate, "the fixture pair no longer has equal line counts, so it " &
      "no longer exercises the case §4.3 built lineTableDigest for")
  if sourceLineTableDigest(bytesOf(SourceV2)) ==
      sourceLineTableDigest(bytesOf(SourceV3)):
    gateFail(gate, "the fixture pair has an identical line table")

  let (output, exitCode) = finish(run)
  if exitCode != 0:
    stderr.writeLine output
    gateFail(gate, "the host exited " & $exitCode)

  # ---- the host's OWN account, independent of the wire.
  let report = hostReport(output, gate)
  if report{"messagesHandled"}.getInt() != expectedNotifications:
    gateFail(gate, "the host says it handled " &
      $report{"messagesHandled"}.getInt() & " coordinator frames; " &
      $expectedNotifications & " were sent. A session that reads one frame " &
      "and stops is the defect GDH-M4 exists to remove.")
  let appliedList = report{"applied"}
  if appliedList.isNil or appliedList.kind != JArray or
      appliedList.len != expectedNotifications:
    gateFail(gate, "the host reports " &
      (if appliedList.isNil: "no" else: $appliedList.len) &
      " applied generations, expected " & $expectedNotifications)
  var seenGenerations: seq[int] = @[]
  for entry in appliedList:
    seenGenerations.add entry{"generation"}.getInt()
  if seenGenerations != @[2, 3]:
    gateFail(gate, "the host applied generations " & $seenGenerations &
      ", expected @[2, 3]")

  # ---- and the files it actually wrote.
  for (generation, text) in [(2, SourceV2), (3, SourceV3)]:
    let path = run.applyDir / ("applied-gen" & $generation & ".gd")
    if not fileExists(path):
      gateFail(gate, "the host did not write " & path &
        "; the acknowledgement claimed an apply that left no trace")
    let onDisk = readFile(path)
    if onDisk != text:
      gateFail(gate, "the bytes the host stored for generation " &
        $generation & " are not the bytes sent (" & $onDisk.len & " vs " &
        $text.len & " bytes)")

  echo "PASS: ", gate, " — two notifications, generations 2 and 3, distinct ",
    "reloadIds, distinct generations, distinct host-recomputed digests; ",
    expectedNotifications, " frames served in ONE process; both versions ",
    "present on disk with the bytes that were sent"

# ---------------------------------------------------------------------------
# The control arm for the gate above: ONE notification, acknowledged with
# generation 2. It is what makes "generation 3 was expected and 1 arrived"
# attributable to the second message rather than to the first.
# ---------------------------------------------------------------------------

proc runOneReload(workDir, hostBin: string) =
  const gate = "gdh4_second_reload_is_distinct.control"
  var run = startHost(workDir, hostBin, advertiseReload = true, gate = gate)
  let changed2 = changedFor("gdh4-r-0002", 2'u32, SourceV2)
  sendChecked(run.conn, run.client,
    run.client.coordinatorSourceChangedMessage(changed2), gate)
  let msg = requireMessage(readWithBound(run.conn, run.client, ReplyBoundMs),
    gate, "the only sourceChanged (generation 2)")
  if msg.kind != hmkSourceReloadResult:
    gateFail(gate, "expected sourceReloadResult, got " & msg.kind.kindName)
  let applied = expectApplied(msg.sourceReloadResult, gate,
    "the only notification")
  if applied.generation != 2'u32:
    gateFail(gate, "the single notification was acknowledged with generation " &
      $applied.generation & ", expected 2")
  let (output, exitCode) = finish(run)
  if exitCode != 0:
    stderr.writeLine output
    gateFail(gate, "the host exited " & $exitCode)
  let report = hostReport(output, gate)
  if report{"messagesHandled"}.getInt() != 1:
    gateFail(gate, "the host handled " & $report{"messagesHandled"}.getInt() &
      " frames for a single notification")
  echo "PASS: ", gate,
    " — one notification is acknowledged with generation 2"

# ---------------------------------------------------------------------------
# gdh4_unnegotiated_capability_is_refused_not_ignored
# ---------------------------------------------------------------------------

proc runUnnegotiated(workDir, hostBin: string) =
  const gate = "gdh4_unnegotiated_capability_is_refused_not_ignored"
  var run = startHost(workDir, hostBin, advertiseReload = false, gate = gate)

  # ---- anti-vacuity, in the order the milestone requires it: the handshake
  # COMPLETED (asserted in `startHost`), the capability list was RECEIVED, and
  # it does NOT contain `source-reload`. Only then is a refusal meaningful.
  if run.client.session.agentCapabilities.len == 0:
    gateFail(gate, "no capability list was received from the host, so " &
      "\"it did not advertise source-reload\" is not a measurement")
  if run.client.session.hostAdvertisedSourceReload():
    gateFail(gate, "the host DID advertise " & HcrSourceReloadCapability &
      "; this arm needs a host that did not")

  let changed = changedFor("gdh4-r-0002", 2'u32, SourceV2)
  sendChecked(run.conn, run.client,
    run.client.coordinatorSourceChangedMessage(changed), gate)
  let msg = requireMessage(readWithBound(run.conn, run.client, ReplyBoundMs),
    gate, "a sourceChanged sent to a host that did not advertise the capability")
  if msg.kind != hmkSourceReloadResult:
    gateFail(gate, "expected sourceReloadResult, got " & msg.kind.kindName)
  let res = msg.sourceReloadResult
  if res.outcome != hsroFailed:
    gateFail(gate, "expected outcome failed, got " & $res.outcome)
  if res.reason != HcrReloadReasonCapabilityNotNegotiated:
    gateFail(gate, "expected reason " &
      HcrReloadReasonCapabilityNotNegotiated & ", got \"" & res.reason & "\"")
  if res.refusedFiles.len != 1:
    gateFail(gate, "expected exactly one refused file, got " &
      $res.refusedFiles.len)
  if res.refusedFiles[0].reason != HcrReloadReasonCapabilityNotNegotiated:
    gateFail(gate, "the refused file's reason is \"" &
      res.refusedFiles[0].reason & "\"")
  if res.appliedFiles.len != 0:
    gateFail(gate, "a refused reload reported applied files")

  let (output, exitCode) = finish(run)
  if exitCode != 0:
    stderr.writeLine output
    gateFail(gate, "the host exited " & $exitCode)
  let report = hostReport(output, gate)
  if report{"advertisesSourceReload"}.getBool():
    gateFail(gate, "the host says it advertises " & HcrSourceReloadCapability)
  if report{"applied"}.len != 0:
    gateFail(gate, "the host applied " & $report{"applied"}.len &
      " generations despite refusing")
  # The host did not silently proceed: nothing was written.
  for entry in walkDir(run.applyDir):
    gateFail(gate, "the host wrote " & entry.path &
      " while refusing the reload; \"refused\" must mean nothing was applied")

  echo "PASS: ", gate, " — handshake completed, the capability list arrived ",
    "and did NOT contain ", HcrSourceReloadCapability,
    ", and the notification was answered failed/",
    HcrReloadReasonCapabilityNotNegotiated, " with nothing applied"

proc runNegotiatedControl(workDir, hostBin: string) =
  ## The control arm: the SAME message to a host that DID advertise must be
  ## applied — so the refusal above is shown to be caused by negotiation.
  const gate = "gdh4_unnegotiated_capability_is_refused_not_ignored.control"
  var run = startHost(workDir, hostBin, advertiseReload = true, gate = gate)
  if not run.client.session.hostAdvertisedSourceReload():
    gateFail(gate, "the control host did not advertise " &
      HcrSourceReloadCapability)
  let changed = changedFor("gdh4-r-0002", 2'u32, SourceV2)
  sendChecked(run.conn, run.client,
    run.client.coordinatorSourceChangedMessage(changed), gate)
  let msg = requireMessage(readWithBound(run.conn, run.client, ReplyBoundMs),
    gate, "the same sourceChanged, to a host that DID advertise")
  if msg.kind != hmkSourceReloadResult:
    gateFail(gate, "expected sourceReloadResult, got " & msg.kind.kindName)
  discard expectApplied(msg.sourceReloadResult, gate, "the control notification")
  let (output, exitCode) = finish(run)
  if exitCode != 0:
    stderr.writeLine output
    gateFail(gate, "the host exited " & $exitCode)
  echo "PASS: ", gate,
    " — the identical message to an advertising host is APPLIED, so the ",
    "refusal is attributable to negotiation"

when isMainModule:
  # Without this a host that closed the socket kills this process with SIGPIPE
  # and no verdict can be attached to the death. See trap 3: a boundary you do
  # not own may speak two shapes, and both must reduce to a KIND.
  signal(SIGPIPE, SIG_IGN)

  if paramCount() < 3:
    stderr.writeLine "usage: gdh4_gate <mode> <workdir> <hostbin>"
    quit 2
  let mode = paramStr(1)
  let workDir = paramStr(2)
  let hostBin = paramStr(3)
  if not fileExists(hostBin):
    stderr.writeLine "DRIVER-FAIL: no host binary at " & hostBin
    quit 2

  try:
    case mode
    of "two-reloads": runTwoReloads(workDir, hostBin, 2)
    of "one-reload": runOneReload(workDir, hostBin)
    of "unnegotiated": runUnnegotiated(workDir, hostBin)
    of "negotiated-control": runNegotiatedControl(workDir, hostBin)
    else:
      stderr.writeLine "DRIVER-FAIL: unknown mode " & mode
      quit 2
  except GateError as err:
    stderr.writeLine err.msg
    dumpTranscript()
    quit 1
  except CatchableError as err:
    # An unexpected exception is a DRIVER failure, not a red gate. The two are
    # kept apart on purpose: a harness that reported its own bug as a caught
    # defect is how a mutation arm gets counted as killed without ever running.
    stderr.writeLine "DRIVER-FAIL: " & $err.name & ": " & err.msg
    dumpTranscript()
    quit 2
  quit 0
