## Windows-Runner-Binary-Cache-Deploy — ``t_repro_deploy_agent_records_tick_status``.
##
## The regression gate for the win-ci-bare-001 incident (2026-08-19/20): a
## production runner wedged for THIRTEEN HOURS while looking healthy, because
## every tick's outcome went only to stdout/stderr — which Task Scheduler
## discards — and everything the agent persists advances only on SUCCESS.
##
## Pins that EVERY tick leaves one durable, machine-readable record at
## ``<stateDir>/deploy-agent/<safe-target>.last-tick.json``:
##
##   1. a SUCCESSFUL tick records the success outcome, with the sequence and
##      deployment id, and a fresh timestamp;
##   2. a FAILING tick records the failure INCLUDING the error text — this is
##      the actual regression; the incident is worthless as a test if only the
##      happy path is covered. Both failure shapes are covered: the apply hook
##      that returns failure (what the missing-`nim` incident actually
##      produced, via the hook's own `except`) and the tick that RAISES (the
##      path that previously returned 1 having written nothing at all);
##   3. the non-zero outcome kinds that never reach an apply — `aoSourceError`,
##      `aoRejected` — are recorded too;
##   4. the record is valid JSON under the declared schema, and the write is
##      atomic: no `.tmp` litter after a good write, and a FAILED write leaves
##      the PREVIOUS record intact rather than destroying the only evidence of
##      the last failure — while changing neither the exit code nor the error;
##   5. the 0/1/2 exit-code mapping is UNCHANGED by any of the above, asserted
##      over every `AgentOutcomeKind`.
##
## The apply hook is injected (a recording / failing / raising stub), so the
## whole gate is hermetic: no compiler, no network, no elevation.

import std/[json, os, strutils, tempfiles, times, unittest]

import repro_deploy_agent
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import repro_profile

const Target = "win-ci-bare-001"

# The incident's own error text, verbatim in shape: the string an operator
# needed and could not get. If the record does not carry it, this gate fails.
const NimMissingError =
  "nim was not found on PATH; the deploy agent cannot compile the profile"

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
    outputs: @[], commandStatsId: "tick-status.noop",
    requiresElevation: false, cacheable: false)

type Fixture = object
  root: string
  cfg: AgentConfig
  deps: AgentDeps
  signer: peerAuth.PeerKeypair
  manifestPath: string

proc newFixture(name: string): Fixture =
  let root = createTempDir("tick-status-" & name & "-", "")
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

proc statusJson(f: Fixture): JsonNode =
  ## The record as a probe would read it. A MISSING record is the regression
  ## itself, so it fails with that in words rather than an opaque IOError.
  let path = tickStatusPath(f.cfg)
  doAssert fileExists(path), "no tick status record was written at " & path
  parseJson(readFile(path))

suite "deploy agent records every tick's outcome durably":

  test "a successful tick records the success outcome":
    let f = newFixture("success")
    defer:
      try: removeDir(f.root) except CatchableError: discard

    # Nothing written before the first tick — the record is the tick's doing.
    check not fileExists(tickStatusPath(f.cfg))

    f.publish(7'u64, "dep-7")
    let before = getTime().toUnix()
    let tick = runAgentTickRecorded(f.cfg, f.deps)
    check tick.raised == false
    check tick.outcome.kind == aoApplied
    check tick.exitCode == 0
    check gApplyCalls == 1

    check fileExists(tickStatusPath(f.cfg))
    let rec = f.statusJson()
    check rec["schemaId"].getStr() == TickStatusSchemaId
    check rec["schemaVersion"].getInt() == TickStatusSchemaVersion
    check rec["outcome"].getStr() == "aoApplied"
    check rec["exitCode"].getInt() == 0
    check rec["target"].getStr() == Target
    check rec["sequence"].getInt() == 7
    check rec["deploymentId"].getStr() == "dep-7"
    check rec["message"].getStr().len > 0
    check rec["error"].getStr() == ""

    # "converged 2 minutes ago" vs "last succeeded 13 hours ago" is the whole
    # operational question, so the timestamp must be real, UTC and parseable.
    let stamp = rec["timestamp"].getStr()
    check stamp.len == 20                       # yyyy-MM-ddTHH:mm:ssZ
    check stamp.endsWith("Z")
    check stamp[10] == 'T'
    check rec["timestampUnix"].getBiggestInt() >= before
    check rec["timestampUnix"].getBiggestInt() <= getTime().toUnix() + 1

    # Atomic write leaves no litter for a probe to trip over.
    check not fileExists(tickStatusPath(f.cfg) & ".tmp")

  test "a FAILING tick records the failure INCLUDING the error text":
    let f = newFixture("apply-failed")
    defer:
      try: removeDir(f.root) except CatchableError: discard

    # This is the incident's exact shape: the profile could not be compiled,
    # the apply hook caught it and returned failure, and the state dir stayed
    # byte-identical because nothing advances except on success.
    gApplyBehaviour = abFail
    f.publish(9'u64, "dep-9")
    let tick = runAgentTickRecorded(f.cfg, f.deps)
    check tick.raised == false
    check tick.outcome.kind == aoApplyFailed
    check tick.exitCode == 1                   # retryable class, unchanged
    check readLastAppliedSequence(f.cfg) == 0'u64   # state dir says nothing…

    let rec = f.statusJson()                        # …but the record does
    check rec["outcome"].getStr() == "aoApplyFailed"
    check rec["exitCode"].getInt() == 1
    check rec["errorCode"].getStr() == "apply_failed"
    check rec["sequence"].getInt() == 9
    check rec["deploymentId"].getStr() == "dep-9"
    check NimMissingError in rec["message"].getStr()

  test "a RAISING tick records the exception text":
    let f = newFixture("raised")
    defer:
      try: removeDir(f.root) except CatchableError: discard

    # The path that used to `return 1` having written nothing anywhere.
    gApplyBehaviour = abRaise
    f.publish(11'u64, "dep-11")
    let tick = runAgentTickRecorded(f.cfg, f.deps)
    check tick.raised
    check tick.exitCode == 1                   # unchanged: raised tick is 1
    check NimMissingError in tick.error

    # The record is the ONLY durable trace of this tick; its absence is the
    # regression, so assert it before reading it.
    check fileExists(tickStatusPath(f.cfg))
    let rec = f.statusJson()
    check rec["outcome"].getStr() == TickRaisedOutcome
    check rec["exitCode"].getInt() == 1
    check rec["errorCode"].getStr() == "tick_raised"
    check NimMissingError in rec["error"].getStr()
    check rec["target"].getStr() == Target

  test "the non-zero outcome kinds that never reach an apply are recorded":
    let f = newFixture("no-apply")
    defer:
      try: removeDir(f.root) except CatchableError: discard

    # aoRejected — a manifest signed by a key outside the allowed-signers set.
    let evil = peerAuth.generateKeypair()
    var bad = DeployManifest(
      target: Target, sequence: 3'u64, deploymentId: "evil-3",
      profileText: "", buildActions: @[trivialAction("evil")])
    signManifest(evil, bad)
    writeManifestBytes(f.manifestPath, encodeManifest(bad))
    let rejected = runAgentTickRecorded(f.cfg, f.deps)
    check rejected.outcome.kind == aoRejected
    check rejected.exitCode == 2
    var rec = f.statusJson()
    check rec["outcome"].getStr() == "aoRejected"
    check rec["exitCode"].getInt() == 2
    check rec["errorCode"].getStr() == "verification_failed"
    check gApplyCalls == 0

    # aoSourceError — a fetch that hard-fails (not a 404 soft miss). This is
    # one of the shapes that, in the incident, would have left LITERALLY
    # nothing behind: it never reaches the compiler, so not even the build
    # engine's per-action log would have caught the error text.
    var httpCfg = f.cfg
    httpCfg.sources = @["http://127.0.0.1:1/manifest.rdm"]
    var httpDeps = f.deps
    httpDeps.httpGet = proc(url: string; timeoutMs: int):
        tuple[ok: bool; missing: bool; body: seq[byte]; error: string] {.gcsafe.} =
      (ok: false, missing: false, body: @[], error: "connection refused")
    let sourceErr = runAgentTickRecorded(httpCfg, httpDeps)
    check sourceErr.outcome.kind == aoSourceError
    check sourceErr.exitCode == 1
    rec = f.statusJson()
    check rec["outcome"].getStr() == "aoSourceError"
    check rec["exitCode"].getInt() == 1
    check rec["errorCode"].getStr() == "source_read_failed"
    check "connection refused" in rec["message"].getStr()

    # aoWaiting — no manifest at all. Even "nothing to do" is recorded, so a
    # probe can tell a waiting agent from an agent that stopped ticking.
    removeFile(f.manifestPath)
    let waiting = runAgentTickRecorded(f.cfg, f.deps)
    check waiting.outcome.kind == aoWaiting
    check waiting.exitCode == 0
    rec = f.statusJson()
    check rec["outcome"].getStr() == "aoWaiting"
    check rec["exitCode"].getInt() == 0

  test "a failed record write leaves the previous record intact":
    let f = newFixture("atomic")
    defer:
      try: removeDir(f.root) except CatchableError: discard

    # 1. A good tick lands a record.
    f.publish(4'u64, "dep-4")
    check runAgentTickRecorded(f.cfg, f.deps).exitCode == 0
    let previous = readFile(tickStatusPath(f.cfg))
    check parseJson(previous)["deploymentId"].getStr() == "dep-4"

    # 2. Sabotage the staging path so the NEXT write cannot happen: a
    #    directory where the temp file must go. The record must survive.
    let tmpPath = tickStatusPath(f.cfg) & ".tmp"
    createDir(tmpPath)

    gApplyBehaviour = abFail
    f.publish(5'u64, "dep-5")
    let sabotaged = runAgentTickRecorded(f.cfg, f.deps)
    # Best-effort: the write failure changed NOTHING about the tick itself.
    check sabotaged.raised == false
    check sabotaged.outcome.kind == aoApplyFailed
    check sabotaged.exitCode == 1
    check NimMissingError in sabotaged.outcome.message
    # And the previous record is byte-identical — not truncated, not empty.
    check fileExists(tickStatusPath(f.cfg))
    check readFile(tickStatusPath(f.cfg)) == previous
    check parseJson(previous)["deploymentId"].getStr() == "dep-4"

    # 3. Un-sabotage: the very next tick replaces the record in place.
    removeDir(tmpPath)
    let recovered = runAgentTickRecorded(f.cfg, f.deps)
    check recovered.exitCode == 1
    let rec = f.statusJson()
    check rec["outcome"].getStr() == "aoApplyFailed"
    check rec["deploymentId"].getStr() == "dep-5"
    check not fileExists(tmpPath)

  test "the 0/1/2 exit-code mapping is unchanged for every outcome kind":
    # The mapping is deliberate and documented; the status record reports the
    # same number the process returns, so this pins BOTH at once.
    check deployAgentExitCode(aoApplied) == 0
    check deployAgentExitCode(aoConverged) == 0
    check deployAgentExitCode(aoWaiting) == 0
    check deployAgentExitCode(aoApplyFailed) == 1
    check deployAgentExitCode(aoSourceError) == 1
    check deployAgentExitCode(aoRejected) == 2
    check deployAgentExitCode(aoAmbiguous) == 2
    # NOT 1: retrying on the timer will not fix a wrong recipient key.
    check deployAgentExitCode(aoSecretsFailed) == 2

    # Every kind is accounted for — a new one must not silently inherit 0.
    var seen = 0
    for kind in AgentOutcomeKind:
      check deployAgentExitCode(kind) in [0, 1, 2]
      inc seen
    check seen == 8

  test "a converged tick refreshes the record even with nothing to do":
    let f = newFixture("converged")
    defer:
      try: removeDir(f.root) except CatchableError: discard

    # The masking case from the incident: a warm cache means an unchanged
    # desired state never invokes the compiler, so every tick "succeeds".
    # The record must still advance in TIME, or an operator cannot tell a
    # live loop from a dead one.
    f.publish(2'u64, "dep-2")
    check runAgentTickRecorded(f.cfg, f.deps).outcome.kind == aoApplied
    let firstStamp = f.statusJson()["timestampUnix"].getBiggestInt()

    let again = runAgentTickRecorded(f.cfg, f.deps)
    check again.outcome.kind == aoConverged
    check again.exitCode == 0
    let rec = f.statusJson()
    check rec["outcome"].getStr() == "aoConverged"
    check rec["sequence"].getInt() == 2
    check rec["timestampUnix"].getBiggestInt() >= firstStamp
    check gApplyCalls == 1                     # the second tick did not apply
