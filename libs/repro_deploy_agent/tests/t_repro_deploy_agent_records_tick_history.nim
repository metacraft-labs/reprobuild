## Windows-Runner-Binary-Cache-Deploy — ``t_repro_deploy_agent_records_tick_history``.
##
## The follow-up gate to ``t_repro_deploy_agent_records_tick_status``. That
## one pinned the SNAPSHOT: one record, overwritten every tick, which answers
## "is it broken right now, and how stale is that answer" and nothing else.
##
## In the win-ci-bare-001 incident (2026-08-19/20) the box was wedged for
## THIRTEEN HOURS — 78 consecutive failing ticks. A snapshot would have shown
## the 78th instantly and left the other 77 unreconstructable, so the
## questions that actually dominate the troubleshooting stay unanswerable:
## when did this start, did it flap or fail continuously, and what was the
## last good tick before the first bad one.
##
## This gate pins the two sinks that answer them:
##
##   1. an APPEND-ONLY history at
##      ``<stateDir>/deploy-agent/<safe-target>.tick-history.jsonl`` — one
##      line per tick, in tick order, in the SAME schema as the snapshot so
##      one reader parses both. Failing ticks are appended WITH their error
##      text: a history that only records successes is worthless, and that
##      is the actual regression here.
##   2. the WINDOWS EVENT LOG mapping — event ids, entry types and message
##      construction. The decisions are portable code and are asserted on
##      every host; only the ``ReportEventW`` call itself is Windows-only,
##      and it is exercised on a real Windows box, not here (see
##      ``tickEventLogEnabled`` below).
##
## Plus the properties that make an unattended ten-minute loop safe to leave
## alone: the history is BOUNDED and compaction keeps the NEWEST entries; a
## torn tail from a crashed append costs one line and not the file; and any
## sink failing changes neither the exit code nor the other sinks.
##
## The apply hook is injected (a recording / failing / raising stub), so the
## whole gate is hermetic: no compiler, no network, no elevation.

import std/[json, os, strutils, tempfiles, unittest]

import repro_deploy_agent
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import repro_profile

const Target = "win-ci-bare-001"

# The incident's own error text, verbatim in shape: the string an operator
# needed and could not get. If the history does not carry it, this gate fails.
const NimMissingError =
  "nim was not found on PATH; the deploy agent cannot compile the profile"

# The Event Log sink is ON by default because a production box wants it. A
# test run must not deposit a few hundred entries in the developer's real
# Application log, so the whole module runs with it switched off and asserts
# on `tickEventFor`, which is exactly what the Windows path renders.
putEnv(TickEventLogEnvVar, "0")

type
  ApplyBehaviour = enum
    abSucceed          ## converge normally
    abFail             ## hook returns ok = false (what the incident produced)
    abRaise            ## hook raises — the tick never produces an outcome

var gApplyBehaviour = abSucceed
var gApplyCalls = 0

proc stubApply(m: DeployManifest): tuple[ok: bool; message: string] {.gcsafe.} =
  {.cast(gcsafe).}:
    inc gApplyCalls
    case gApplyBehaviour
    of abSucceed: result = (ok: true, message: "recorded")
    of abFail: result = (ok: false, message: NimMissingError)
    of abRaise: raise newException(CatchableError, NimMissingError)

proc writeManifestBytes(path: string; bytes: seq[byte]) =
  var s = newString(bytes.len)
  for i, b in bytes:
    s[i] = char(b)
  let dir = parentDir(path)
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)
  writeFile(path, s)

proc trivialAction(id: string): ProfileBuildAction =
  ProfileBuildAction(id: id, argv: @["/bin/true"], cwd: "",
    outputs: @[], commandStatsId: "tick-history.noop",
    requiresElevation: false, cacheable: false)

type Fixture = object
  root: string
  cfg: AgentConfig
  deps: AgentDeps
  signer: peerAuth.PeerKeypair
  manifestPath: string

proc newFixture(name: string): Fixture =
  let root = createTempDir("tick-history-" & name & "-", "")
  let signer = peerAuth.generateKeypair()
  let stateDir = root / "agent-state"
  createDir(stateDir)
  gApplyBehaviour = abSucceed
  gApplyCalls = 0
  result = Fixture(
    root: root,
    signer: signer,
    manifestPath: root / "manifests" / "latest.rdm",
    deps: AgentDeps(apply: stubApply))
  result.cfg = AgentConfig(
    target: Target,
    sources: @[result.manifestPath],
    anchors: anchorsFromKeypairs(@[signer.publicKey]),
    stateDir: stateDir,
    fetchTimeoutMs: 5000)

proc publish(f: Fixture; sequence: uint64; deploymentId: string) =
  ## Put a validly signed manifest for this target at the source path.
  var m = DeployManifest(
    target: Target, sequence: sequence, deploymentId: deploymentId,
    profileText: "", buildActions: @[trivialAction("act-" & deploymentId)])
  signManifest(f.signer, m)
  writeManifestBytes(f.manifestPath, encodeManifest(m))

proc history(f: Fixture): seq[JsonNode] =
  ## The history as a reader would see it. Its ABSENCE is the regression, so
  ## it fails with that in words rather than an empty seq nobody notices.
  let path = tickHistoryPath(f.cfg)
  doAssert fileExists(path), "no tick history was written at " & path
  readTickHistory(path)

proc historyLines(f: Fixture): seq[string] =
  for line in readFile(tickHistoryPath(f.cfg)).splitLines:
    if line.strip().len > 0:
      result.add(line)

proc syntheticRecord(deploymentId: string): TickStatusRecord =
  TickStatusRecord(
    timestamp: "2026-08-20T00:00:00Z", timestampUnix: 1_787_000_000'i64,
    outcome: "aoApplied", exitCode: 0, target: Target, sequence: 1'u64,
    deploymentId: deploymentId, message: "synthetic", errorCode: "", error: "")

suite "deploy agent keeps a durable HISTORY of every tick":

  test "successive ticks APPEND, in tick order, and do not overwrite":
    let f = newFixture("append")
    defer:
      try: removeDir(f.root) except CatchableError: discard

    # Nothing before the first tick — the history is the tick's doing.
    check not fileExists(tickHistoryPath(f.cfg))

    f.publish(1'u64, "dep-1")
    check runAgentTickRecorded(f.cfg, f.deps).outcome.kind == aoApplied
    check f.history().len == 1

    # Same desired state: a converged tick. It must still be recorded, or a
    # live loop and a dead one look identical from the history too.
    check runAgentTickRecorded(f.cfg, f.deps).outcome.kind == aoConverged
    f.publish(2'u64, "dep-2")
    check runAgentTickRecorded(f.cfg, f.deps).outcome.kind == aoApplied

    let entries = f.history()
    check entries.len == 3
    check entries[0]["outcome"].getStr() == "aoApplied"
    check entries[0]["deploymentId"].getStr() == "dep-1"
    check entries[1]["outcome"].getStr() == "aoConverged"
    check entries[1]["deploymentId"].getStr() == "dep-1"
    check entries[2]["outcome"].getStr() == "aoApplied"
    check entries[2]["deploymentId"].getStr() == "dep-2"

    # The SNAPSHOT still holds only the latest — the two files answer two
    # different questions and neither replaces the other.
    check parseJson(readFile(tickStatusPath(f.cfg)))["deploymentId"].getStr() ==
      "dep-2"

    # One line per tick, and each line is one line: a multi-line record would
    # let an error message containing a newline forge a record boundary.
    check f.historyLines().len == 3
    check not fileExists(tickHistoryPath(f.cfg) & ".tmp")

  test "a FAILING tick is appended WITH its error text":
    let f = newFixture("failing")
    defer:
      try: removeDir(f.root) except CatchableError: discard

    # The incident's shape: one good tick, then failure forever. The good
    # tick is the "last known good" an operator has to be able to find.
    f.publish(5'u64, "dep-5")
    check runAgentTickRecorded(f.cfg, f.deps).exitCode == 0

    gApplyBehaviour = abFail
    f.publish(6'u64, "dep-6")
    check runAgentTickRecorded(f.cfg, f.deps).exitCode == 1
    check runAgentTickRecorded(f.cfg, f.deps).exitCode == 1

    gApplyBehaviour = abRaise
    check runAgentTickRecorded(f.cfg, f.deps).exitCode == 1

    let entries = f.history()
    check entries.len == 4

    # "What was the last good tick before the first bad one?"
    check entries[0]["outcome"].getStr() == "aoApplied"
    check entries[0]["deploymentId"].getStr() == "dep-5"
    check entries[0]["exitCode"].getInt() == 0

    # "Did it flap, or fail continuously?" — both failing ticks are there,
    # each carrying the diagnosis, not just the most recent one.
    for i in 1 .. 2:
      check entries[i]["outcome"].getStr() == "aoApplyFailed"
      check entries[i]["exitCode"].getInt() == 1
      check entries[i]["errorCode"].getStr() == "apply_failed"
      check entries[i]["deploymentId"].getStr() == "dep-6"
      check NimMissingError in entries[i]["message"].getStr()

    # The tick that RAISED — the path that used to leave nothing anywhere.
    check entries[3]["outcome"].getStr() == TickRaisedOutcome
    check entries[3]["exitCode"].getInt() == 1
    check entries[3]["errorCode"].getStr() == "tick_raised"
    check NimMissingError in entries[3]["error"].getStr()

    # The state dir is byte-identical across all three failures — this is
    # why nothing else in it can answer the question.
    check readLastAppliedSequence(f.cfg) == 5'u64

  test "the history parses with the SAME code path as the status file":
    let f = newFixture("schema")
    defer:
      try: removeDir(f.root) except CatchableError: discard

    f.publish(3'u64, "dep-3")
    discard runAgentTickRecorded(f.cfg, f.deps)
    let entry = f.history()[0]
    let snapshot = parseJson(readFile(tickStatusPath(f.cfg)))

    # Same envelope identity, same fields, same values — a reader must not
    # need to know which file a record came out of.
    check entry["schemaId"].getStr() == TickStatusSchemaId
    check entry["schemaVersion"].getInt() == TickStatusSchemaVersion
    for key in ["schemaId", "schemaVersion", "outcome", "exitCode", "target",
                "sequence", "deploymentId", "message", "errorCode", "error"]:
      check entry.hasKey(key)
      check $entry[key] == $snapshot[key]

  test "the cap BOUNDS the file and compaction keeps the NEWEST entries":
    let f = newFixture("cap")
    defer:
      try: removeDir(f.root) except CatchableError: discard

    let path = tickHistoryPath(f.cfg)
    for i in 0 ..< 12:
      appendTickHistory(path, syntheticRecord("dep-" & $i), maxEntries = 5)

    let entries = readTickHistory(path)
    check entries.len == 5
    # Newest five, oldest first — losing the RECENT end to rotation would be
    # worse than not rotating at all.
    for i in 0 ..< 5:
      check entries[i]["deploymentId"].getStr() == "dep-" & $(i + 7)
    check not fileExists(path & ".tmp")

    # The production default is a real bound, not a disabled one.
    check TickHistoryDefaultMaxEntries > 0
    check TickHistoryDefaultMaxEntries == 2016     # 14 days of 10-min ticks

  test "the cap bounds the file through a REAL tick loop too":
    let f = newFixture("cap-live")
    defer:
      try: removeDir(f.root) except CatchableError: discard
    putEnv(TickHistoryMaxEntriesEnvVar, "3")
    defer: delEnv(TickHistoryMaxEntriesEnvVar)

    check tickHistoryMaxEntries() == 3
    for seq in 1'u64 .. 6'u64:
      f.publish(seq, "dep-" & $seq)
      check runAgentTickRecorded(f.cfg, f.deps).exitCode == 0

    let entries = f.history()
    check entries.len == 3
    check entries[0]["deploymentId"].getStr() == "dep-4"
    check entries[1]["deploymentId"].getStr() == "dep-5"
    check entries[2]["deploymentId"].getStr() == "dep-6"
    check not fileExists(tickHistoryPath(f.cfg) & ".tmp")

    # A fat-fingered override falls back to the bounded default rather than
    # to "unbounded".
    putEnv(TickHistoryMaxEntriesEnvVar, "not-a-number")
    check tickHistoryMaxEntries() == TickHistoryDefaultMaxEntries
    putEnv(TickHistoryMaxEntriesEnvVar, "0")
    check tickHistoryMaxEntries() == TickHistoryDefaultMaxEntries

  test "unbounded free text is truncated in the history, not in the snapshot":
    let f = newFixture("truncate")
    defer:
      try: removeDir(f.root) except CatchableError: discard

    # An exception message can be a compiler dump; 2016 of them are not a
    # bound. The snapshot is one record, so it keeps the full text.
    let huge = "x".repeat(TickHistoryMaxTextChars * 3)
    recordTick(f.cfg.stateDir, f.cfg.target, tickStatusForRaise(Target, huge))

    let entry = f.history()[0]
    check entry["error"].getStr().len ==
      TickHistoryMaxTextChars + TickHistoryTruncationSuffix.len
    check entry["error"].getStr().endsWith(TickHistoryTruncationSuffix)
    check parseJson(readFile(tickStatusPath(f.cfg)))["error"].getStr().len ==
      huge.len

  test "a torn tail costs one line, not the file":
    let f = newFixture("torn")
    defer:
      try: removeDir(f.root) except CatchableError: discard

    # What a crash (or a full disk) mid-append leaves behind: a complete
    # record, then a fragment with no newline after it.
    let path = tickHistoryPath(f.cfg)
    createDir(parentDir(path))
    writeFile(path,
      renderTickHistoryLine(syntheticRecord("dep-good")) &
      """{"schemaId":"reprobuild.deploy-agent.tick-st""")

    appendTickHistory(path, syntheticRecord("dep-after"),
      maxEntries = TickHistoryDefaultMaxEntries)

    let entries = readTickHistory(path)
    check entries.len == 2
    check entries[0]["deploymentId"].getStr() == "dep-good"
    # The new record is intact rather than glued onto the fragment.
    check entries[1]["deploymentId"].getStr() == "dep-after"

  test "a history-sink failure changes neither the exit code nor the snapshot":
    let f = newFixture("history-sabotage")
    defer:
      try: removeDir(f.root) except CatchableError: discard

    # A directory where the log must go: every append fails, forever.
    createDir(parentDir(tickHistoryPath(f.cfg)))
    createDir(tickHistoryPath(f.cfg))

    gApplyBehaviour = abFail
    f.publish(8'u64, "dep-8")
    let tick = runAgentTickRecorded(f.cfg, f.deps)
    # Best effort: the sink failure changed NOTHING about the tick itself.
    check tick.raised == false
    check tick.outcome.kind == aoApplyFailed
    check tick.exitCode == 1
    check NimMissingError in tick.outcome.message

    # …and the OTHER sink still landed the record.
    check fileExists(tickStatusPath(f.cfg))
    let snapshot = parseJson(readFile(tickStatusPath(f.cfg)))
    check snapshot["outcome"].getStr() == "aoApplyFailed"
    check snapshot["deploymentId"].getStr() == "dep-8"
    check NimMissingError in snapshot["message"].getStr()

  test "a snapshot-sink failure does not stop the history":
    let f = newFixture("status-sabotage")
    defer:
      try: removeDir(f.root) except CatchableError: discard

    # The mirror image: the snapshot's staging path is unwritable, so the
    # snapshot cannot be replaced. The history must still record the tick —
    # otherwise one broken sink erases the whole tick from the record.
    createDir(parentDir(tickStatusPath(f.cfg)))
    createDir(tickStatusPath(f.cfg) & ".tmp")

    gApplyBehaviour = abRaise
    f.publish(9'u64, "dep-9")
    let tick = runAgentTickRecorded(f.cfg, f.deps)
    check tick.raised
    check tick.exitCode == 1
    check NimMissingError in tick.error

    check not fileExists(tickStatusPath(f.cfg))     # the sabotaged sink
    let entries = f.history()                       # the surviving one
    check entries.len == 1
    check entries[0]["outcome"].getStr() == TickRaisedOutcome
    check NimMissingError in entries[0]["error"].getStr()

  test "the 0/1/2 exit-code mapping is unchanged by any of this":
    check deployAgentExitCode(aoApplied) == 0
    check deployAgentExitCode(aoConverged) == 0
    check deployAgentExitCode(aoWaiting) == 0
    check deployAgentExitCode(aoApplyFailed) == 1
    check deployAgentExitCode(aoSourceError) == 1
    check deployAgentExitCode(aoRejected) == 2
    check deployAgentExitCode(aoAmbiguous) == 2
    # NOT 1: retrying on the timer will not fix a wrong recipient key.
    check deployAgentExitCode(aoSecretsFailed) == 2

    var seen = 0
    for kind in AgentOutcomeKind:
      check deployAgentExitCode(kind) in [0, 1, 2]
      inc seen
    check seen == 8

suite "deploy agent maps every tick onto a Windows event":

  test "every outcome has a DISTINCT id, and every id is renderable":
    var ids: seq[int] = @[]
    for kind in AgentOutcomeKind:
      let id = tickEventId($kind)
      check id notin ids
      ids.add(id)
    check tickEventId(TickRaisedOutcome) notin ids
    ids.add(tickEventId(TickRaisedOutcome))
    check ids.len == 9

    # 1..1000 is not decoration: the source is registered against
    # EventCreate.exe's stock message table, which covers exactly that
    # range. An id outside it renders as "description ... cannot be found"
    # and buries the diagnosis.
    for id in ids:
      check id >= 1
      check id <= 1000

    # An outcome name this build does not know is a distinct, non-silent id.
    check tickEventId("aoSomethingFromTheFuture") == EventIdTickUnknownOutcome
    check EventIdTickUnknownOutcome notin ids

  test "the id encodes the exit-code class, so an admin can filter on it":
    # 10x = exit 0, 11x = exit 1 (retryable), 12x = exit 2 (operator acts).
    for kind in AgentOutcomeKind:
      let id = tickEventId($kind)
      check id div 10 == 10 + deployAgentExitCode(kind)
    check tickEventId(TickRaisedOutcome) == EventIdTickRaised

  test "entry type is Error for failures and Information for success":
    proc entryTypeOf(kind: AgentOutcomeKind): TickEventEntryType =
      tickEventEntryType(TickStatusRecord(outcome: $kind,
        exitCode: deployAgentExitCode(kind)))
    check entryTypeOf(aoApplied) == teInformation
    check entryTypeOf(aoConverged) == teInformation
    check entryTypeOf(aoWaiting) == teInformation
    check entryTypeOf(aoApplyFailed) == teError
    check entryTypeOf(aoSourceError) == teError
    check entryTypeOf(aoRejected) == teError
    check entryTypeOf(aoAmbiguous) == teError
    check entryTypeOf(aoSecretsFailed) == teError
    check tickEventEntryType(tickStatusForRaise(Target, "boom")) == teError
    # Unknown outcome: not a failure we can name, but not nothing either.
    check tickEventEntryType(TickStatusRecord(outcome: "aoFuture",
      exitCode: 0)) == teWarning

  test "the event message carries the DIAGNOSIS, not just a code":
    # The whole point of this sink: readable in Event Viewer on a box whose
    # state dir has been wiped, with nothing to correlate.
    var rec = tickStatusForRaise(Target, NimMissingError)
    let event = tickEventFor(rec, "C:\\state\\deploy-agent\\t.tick-history.jsonl")
    check event.eventId == EventIdTickRaised
    check event.entryType == teError
    check NimMissingError in event.message
    check Target in event.message
    check TickRaisedOutcome in event.message
    check "exit code    : 1" in event.message
    check "tick_raised" in event.message
    check "t.tick-history.jsonl" in event.message

    # A successful tick names what it applied, so a timeline built from the
    # log alone still shows which deployment landed when.
    var ok = TickStatusRecord(outcome: "aoApplied", exitCode: 0,
      target: Target, sequence: 42'u64, deploymentId: "dep-42",
      message: "applied", errorCode: "", timestamp: "2026-08-20T01:02:03Z")
    let okEvent = tickEventFor(ok)
    check okEvent.eventId == EventIdTickApplied
    check okEvent.entryType == teInformation
    check "sequence     : 42" in okEvent.message
    check "dep-42" in okEvent.message
    check "2026-08-20T01:02:03Z" in okEvent.message
    # No empty rows for fields this outcome does not have.
    check "error        :" notin okEvent.message

  test "the event message is bounded below the ReportEvent string limit":
    var rec = tickStatusForRaise(Target, "y".repeat(200_000))
    let event = tickEventFor(rec)
    check event.message.len <= TickEventMaxMessageChars + 20
    check event.message.endsWith("...[truncated]\n")

  test "the sink is on by default and switchable off":
    let saved = getEnv(TickEventLogEnvVar)
    defer: putEnv(TickEventLogEnvVar, saved)
    delEnv(TickEventLogEnvVar)
    check tickEventLogEnabled()
    for off in ["0", "off", "false", "no", "OFF"]:
      putEnv(TickEventLogEnvVar, off)
      check not tickEventLogEnabled()
    putEnv(TickEventLogEnvVar, "1")
    check tickEventLogEnabled()

  test "reporting is best effort — it never raises and never blocks a tick":
    # Portable: off Windows this is a no-op, and on Windows the call is
    # wrapped so a refused registration or a refused report cannot escape.
    # What is NOT covered here is the ReportEventW round trip itself; that
    # is verified on a real Windows host with `Get-WinEvent`.
    let saved = getEnv(TickEventLogEnvVar)
    defer: putEnv(TickEventLogEnvVar, saved)
    putEnv(TickEventLogEnvVar, "0")
    reportTickEvent(tickStatusForRaise(Target, NimMissingError))
    reportTickEvent(TickStatusRecord(outcome: "aoFuture", exitCode: 7))
