## The network guard's acts inside a switch and a recovery (ReproOS Add-On
## Mode §4.5 steps 2-4, §7.2 step 9, §7.7; §13 decisions 87, 102-106,
## 116-126). ``network_guard`` holds the mechanisms; this module is what
## the switch (``addon_apply``) and recovery (``reassert``) do with them,
## in the order spec §4.5 step 4 and its table fix:
##
## - ``writeNetworkObjects``: steps 4-5's network writes, each preceded by
##   a read of the guard under the guard lock, held across the write
##   (decision 103); a ``fired`` guard stops them. Once the last is written
##   and the guard read after it, the marker records the moment: the SSH
##   evidence and a confirm count only from there (spec §4.5 step 3);
## - ``watchGuard``: after step 8 the owner watches the invariants until
##   it disarms (only the owner writes ``disarmed``) or the timer fires;
##   at the deadline the timer is the only actor, unless none of the
##   attempt's timers is loaded (decision 118);
## - ``beginGuardRevert``: every failure path before disarm writes
##   ``reverting`` with its reason, having first armed a fresh guard timer
##   when none of the attempt's is loaded (decisions 104, 121, 123, 125,
##   126) -- after verifying and repairing the out-of-store copy that timer
##   runs (decision 128). A failed arm is reported (``EAddOnGuardTimer``)
##   and the revert goes on;
## - ``finishGuardRevert``: once the revert has completed, the marker gone
##   and the snapshot deleted, the attempt's timers are stopped LAST
##   (decision 106), and the guard's records go.

import std/[os, strutils, tables]

import repro_infra/addon_diagnostics
import repro_infra/apply_lock
import repro_infra/profile

import ./fingerprint
import ./guard_lock
import ./ledger
import ./mutations
import ./network_guard
import ./network_link
import ./seams
import ./static_tree

type
  GuardOutcome* = object
    disarmed*: bool
    reason*: string        ## why it reverts, or what disarmed it
    notes*: seq[string]

proc guardDiagnostic*(reason: string): string =
  ## ``EAddOnNetworkGuard: <reason>``, the prefix added once.
  if reason.startsWith($adNetworkGuard & ": "): reason
  else: diagnosticMessage(adNetworkGuard, reason)

proc beginGuardRevert*(stateDir: string; m: PendingMarker;
                       reason: string): tuple[reason: string;
                                              notes: seq[string]] =
  ## Before a revert of the guarded attempt ``m`` starts: arm a fresh
  ## guard timer (with ``reason``, successor semantics) when none of the
  ## attempt's is loaded, then, under the guard lock, write ``reverting``
  ## with ``reason`` if the guard is still ``armed`` -- or leave a
  ## ``fired`` / ``reverting`` one as it is -- naming the fresh timer.
  ## Returns the reason the revert records (the marker's own, once read
  ## under the lock) and what was done.
  if m.guardAttempt.len == 0: return (reason, @[])
  var fresh = ""
  if loadedGuardTimers(m.guardAttempt).len == 0:
    let (a, note) = armVerifiedGuardTimer(stateDir, m.guardAttempt,
                                          m.guardPrevious, reason,
                                          SuccessorIntervalSec)
    if note.len > 0: result.notes.add(note)
    if a.problem.len > 0:
      result.notes.add(a.problem & "; the revert goes on (§13 decisions " &
        "125, 126)")
    else:
      fresh = a.unit
      result.notes.add("armed a fresh guard timer " & fresh &
        " before the revert (none of the attempt's was loaded)")
  let t = transitionGuard(stateDir, m.guardAttempt, "reverting", reason, fresh)
  result.reason =
    if t.found and t.marker.guardReason.len > 0: t.marker.guardReason
    else: reason
  if t.found and t.before == "disarmed":
    # Only the owner writes `disarmed`, and it never reverts after it.
    result.notes.add("the guard was already disarmed")

proc finishGuardRevert*(stateDir, attempt: string): seq[string] =
  ## The revert of ``attempt`` has completed (``rolled-back`` recorded,
  ## the snapshot deleted, the marker gone): stop every timer of the
  ## attempt and its service, the actor's own excepted, and drop the
  ## guard's records (decision 106).
  if attempt.len == 0: return
  let stopped = stopAttemptTimers(attempt)
  if stopped.len > 0:
    result.add("stopped the guard units " & stopped.join(" "))
  clearGuardRecord(stateDir)
  clearConfirm(stateDir)

type NetworkWrites* = object
  written*: seq[NetworkObject]   ## connections now on the host as planned
  removed*: seq[string]          ## keyfiles taken off
  kept*: seq[LedgerEntry]        ## removals that failed: still owned
  problems*: seq[string]
  firedReason*: string           ## the guard read `fired`: why

proc firedReasonOnDisk(stateDir, attempt: string): string =
  ## The marker's reason when the guard of ``attempt`` is ``fired``, else
  ## "". The caller holds the guard lock.
  try:
    let m = parsePendingMarker(readFile(pendingMarkerPath(stateDir)))
    if m.guardAttempt == attempt and m.guard == "fired":
      return (if m.guardReason.len > 0: m.guardReason else: "fired")
  except CatchableError:
    discard
  ""

proc onHostAsPlanned(o: NetworkObject): bool =
  if not fileExists(o.path) or symlinkExists(o.path): return false
  try: readFile(o.path) == o.content
  except CatchableError: false

proc writeNetworkObjects*(stateDir: string; m: PendingMarker;
                          desired: seq[NetworkObject];
                          previous: Ledger;
                          seamPrefix = ""): NetworkWrites =
  ## Steps 4-5's network writes: the connections the generation drops
  ## first, then each one it adds or changes; one on the host already as
  ## planned is left alone. In a guarded switch (``m.guardAttempt``, the
  ## forward switch of a network generation) each write is preceded by a
  ## read of the guard under the guard lock, held across the write; a
  ## ``fired`` guard stops the writes and the switch goes to the revert
  ## (decision 103). The read is repeated after the last write.
  let guarded = m.guardAttempt.len > 0 and m.guard == "armed" and
                m.purpose notin ["revert", "replay"]
  let change = networkChanges(previous, desired)
  var prevByPath = initTable[string, LedgerEntry]()
  for e in networkEntries(previous): prevByPath[e.path] = e
  type Act = object
    remove: bool
    path: string
    obj: NetworkObject
  var acts: seq[Act]
  for path in change.removed: acts.add(Act(remove: true, path: path))
  for o in desired:
    let planned = o.path in change.added or o.path in change.changed
    if not planned and onHostAsPlanned(o):
      result.written.add(o)
    else:
      acts.add(Act(obj: o, path: o.path))
  for i, a in acts:
    if i > 0: seamPause(stateDir, seamPrefix & "network-between-objects")
    var held: GuardLock
    if guarded:
      held = acquireGuardLock()
      let fired = firedReasonOnDisk(stateDir, m.guardAttempt)
      if fired.len > 0:
        held.release()
        result.firedReason = fired
        break
    try:
      if a.remove:
        let e = prevByPath[a.path]
        let p = removeNetworkObject(a.path, e.value, e.unit)
        if p.len > 0:
          result.problems.add("network: " & p)
          result.kept.add(e)
        else:
          result.removed.add(a.path)
      else:
        let p = applyNetworkObject(a.obj)
        if p.len > 0: result.problems.add("network: " & p)
        else: result.written.add(a.obj)
    finally:
      if guarded: held.release()
  # Again after the last step.
  if result.firedReason.len == 0 and guarded:
    var held = acquireGuardLock()
    result.firedReason = firedReasonOnDisk(stateDir, m.guardAttempt)
    held.release()
  # The switch has written its last network object: from now on a new SSH
  # session or a confirm is evidence that the host is reachable on the
  # network as it now is (spec §4.5 step 3, amended 2026-11-22). Recorded
  # under the guard lock, only on a guard still `armed`.
  if result.firedReason.len == 0 and guarded:
    discard recordNetworkWritesDone(stateDir, m.guardAttempt, nowRealtimeUs(),
                                    nowMonoUs())

proc networkLedgerEntries*(written: seq[NetworkObject];
                           preserve: proc (content: string): string):
    seq[LedgerEntry] =
  ## The ledger's ``network`` entries for the connections on the host,
  ## their bytes preserved under the state directory so the guard can put
  ## them back without the store (spec §4.5 step 1).
  for o in written:
    result.add(LedgerEntry(class: lcNetwork, path: o.path, unit: o.name,
      value: o.uuid, kindHint: o.kind, sha256: sha256Hex(o.content),
      mode: "0600", owner: "0:0", resource: o.address,
      preserved: preserve(o.content)))

proc watchGuard*(stateDir: string; m: PendingMarker;
                 guard: NetworkGuardSettings;
                 defaultRoutesBefore: seq[string]): GuardOutcome =
  ## The owner's watch after step 8 (spec §4.5 steps 2-4). Every second:
  ## a ``fired`` guard ends it in the revert; an invariant failing on two
  ## reads in a row ends it in the revert, with the failures as the
  ## reason; with every invariant holding and a new SSH session (or a
  ## confirm), the guard is disarmed under the guard lock -- unless the
  ## timer wrote ``fired`` first -- and the attempt's timers are stopped.
  ## At ``networkGuard.timeout`` the timer is the only actor (decision
  ## 102): the watch waits for its outcome, unless none of the attempt's
  ## timers is loaded, in which case it reverts itself (decision 118).
  let attempt = m.guardAttempt
  let timeoutUs = int64(max(m.guardTimeout, 1)) * 1_000_000
  let deadline = m.guardStartMono + timeoutUs
  var failing: seq[string]
  var failedReads = 0
  while true:
    let g = readGuardedMarker(stateDir)
    # When the switch finished its network writes (``writeNetworkObjects``
    # recorded it on the marker): the evidence counts only from there. 0
    # -- never recorded -- and nothing counts.
    var writtenRealtime, writtenMono: int64
    if g.present and g.marker.guardAttempt == attempt:
      if g.marker.guard in ["fired", "reverting"]:
        return GuardOutcome(reason: g.marker.guardReason)
      if g.marker.guard == "disarmed":
        return GuardOutcome(disarmed: true, reason: "already disarmed")
      writtenRealtime = g.marker.guardWrittenRealtime
      writtenMono = g.marker.guardWrittenMono
    when mutated("guard-disarms-on-success"):
      # FALSIFYING MUTATION (e2e_omarchy_addon_network_guard_disarm_conditions):
      # the switch reported success, so the guard disarms at once.
      discard transitionGuard(stateDir, attempt, "disarmed", "")
      discard stopAttemptTimers(attempt)
      return GuardOutcome(disarmed: true, reason: "the switch succeeded")
    let host = observeHostNetwork()
    let now = invariantFailures(guard, defaultRoutesBefore, host)
    if now.len > 0:
      inc failedReads
      failing = now
      if failedReads >= 2:
        return GuardOutcome(reason: "invariant failed: " & now.join("; "))
    else:
      failedReads = 0
      # A session from an address the host holds itself is the host
      # logging in to itself: no evidence (spec §4.5 step 3; T55).
      let own = hostAddressTexts(host)
      var evidence = newSshSessionSince(writtenRealtime, own)
      if evidence.len == 0:
        evidence = confirmedBy(stateDir, attempt, writtenMono, own)
      if evidence.len > 0:
        seamPause(stateDir, "guard-before-disarm")
        let t = transitionGuard(stateDir, attempt, "disarmed", "")
        if t.found and t.after == "disarmed":
          seamPause(stateDir, "guard-after-disarm")
          var notes = @["disarmed by " & evidence]
          let stopped = stopAttemptTimers(attempt)
          if stopped.len > 0:
            notes.add("stopped the guard units " & stopped.join(" "))
          return GuardOutcome(disarmed: true, reason: evidence, notes: notes)
        return GuardOutcome(reason: (if t.found: t.marker.guardReason
                                     else: "the marker is gone"))
    if nowMonoUs() >= deadline and loadedGuardTimers(attempt).len == 0:
      # Decision 118: the deadline passed and no timer of the attempt is
      # loaded; the owner reverts itself, after arming a fresh timer
      # (decision 121, in ``beginGuardRevert``).
      return GuardOutcome(reason: TimerGoneReason)
    # The watch can last up to networkGuard.timeout (3600 s at most): the
    # apply lock it holds keeps its heartbeat, so it is never reclaimed as
    # stale from a live owner.
    refreshApplyLock(stateDir)
    sleep(1000)
