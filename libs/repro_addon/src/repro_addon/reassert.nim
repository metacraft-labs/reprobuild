## Boot-time re-assertion (ReproOS Add-On Mode §7.7) and the recovery of
## an interrupted switch.
##
## ``repro-addon-reassert.service`` runs ``repro system addon reassert
## --boot`` once per boot, wanted by ``repro-addon.target`` only, so
## nothing it does can hold up the base's boot. It:
##
## 1. **finishes or reverts an interrupted switch** from the pending
##    marker (``recoverPendingSwitch``):
##    - the switch had committed (``current`` names the marker's attempt):
##      only step 9's bookkeeping was lost; the generation's store root is
##      promoted from the pending root and the marker goes;
##    - it had not: the switch is REPLAYED from its write-ahead plan
##      (``pending_plan``), with the decisions it made before its first
##      write, to completion -- including the confirm step. A replay that
##      cannot complete is reverted by the switch itself to the generation
##      ``current`` names. Either way the host ends in exactly one of the
##      two generations. The marker's step is reported, never trusted: the
##      replay does not start from it, it re-does every step idempotently;
## 2. **checks** that ``/etc/repro/static`` points at ``current``'s tree,
##    that ``current``'s store objects are there, and that every ledger
##    object matches its digest;
## 3. re-materialises the current generation's secrets into
##    ``/run/repro/secrets`` from that generation's own sealed envelope,
##    under the switch's locks taken without waiting (it defers to an apply
##    that holds them), finishing a commit or a rotation a crash cut short
##    (``secrets_ops.reassertSecrets``, milestone A7); a secret it cannot
##    materialise makes the report ``degraded``, a running unit with
##    credentials older than its secrets ``drift``;
## 4. **reports** ``ok``, ``drift`` (with the objects) or ``degraded`` (the
##    store, the ledger or a recovery is broken). It never re-applies on
##    drift: that would undo an out-of-band change before anyone saw it.
##
## The report goes to stdout (the journal) and to
## ``<state dir>/addon/reassert-report``. In ``--boot`` mode nothing here
## raises and the exit status is 0, whatever happened.

import std/[os, posix, strutils, times]

import repro_core/file_lock
import repro_core/host_apply_lock

import repro_infra
import repro_infra/addon_diagnostics
import repro_local_store/store
import repro_peer_cache/auth as peerAuth
from repro_deploy_agent/secrets import ensureRecipientKeyFile

import ./addon_apply
import ./collision
import ./generation0
import ./host_exec
import ./etc_write
import ./evidence
import ./ledger
import ./mutations
import ./pending_plan
import ./preflight
import ./root_snapshot
import ./static_tree
import ./store_root
import ./seams
import ./addon_secrets
import ./secrets_ops
import ./switch
import ./transitions
import ./network_guard
import ./network_link
import ./network_switch

type
  ReassertReport* = object
    status*: string          ## ok | drift | degraded
    recovery*: seq[string]   ## what was done about an interrupted switch
    findings*: seq[string]
    notes*: seq[string]

  RecoveryOutcome* = object
    resolved*: bool
    deferred*: bool
      ## A switch holds the host apply lock right now. That switch is the
      ## one that started this recovery (it restarts the reassert unit at
      ## step 7) or will finish its own marker, so there is nothing to
      ## recover yet and nothing to wait for.
    lines*: seq[string]
    swept*: seq[string]
      ## What the orphan sweep of the root snapshots deleted, and an
      ## ``EAddOnSnapshotLeft`` line for each it could not (spec §7.2).
      ## Apart from ``lines``: a sweep is not a recovered switch.

proc reassertReportPath*(stateDir: string): string =
  stateDir / "addon" / "reassert-report"

proc takeLockForRecovery(stateDir: string; atBoot: bool):
    tuple[ok: bool; why: string; took: bool] =
  ## The apply lock, so recovery never races a live switch. A lock taken
  ## in a previous boot (its recorded boot id is not this boot's) belongs
  ## to a switch the reset or power cut killed, whatever process its PID
  ## now names, and is taken over. A lock of this boot is respected unless
  ## its owner is dead; a lock that records no boot id (written by an
  ## older release) is judged by its owner's liveness alone.
  if applyLockOwner(stateDir) == getCurrentProcessId():
    # This process holds it already: an apply recovering first (see
    # `installPendingSwitchGuard`). It is that apply's to release.
    return (true, "", false)
  var policy = defaultApplyLockPolicy()
  let rec = readApplyLockRecord(stateDir)
  let boot = currentBootId()
  if atBoot and rec.present and rec.bootId.len > 0 and boot.len > 0 and
      rec.bootId != boot:
    policy.forceUnlock = true
  let acq = tryAcquireApplyLock(stateDir, policy)
  if acq.acquired: (true, "", true)
  else: (false, "a switch is in progress (" &
         describeApplyLockHolder(stateDir, acq) & "); not touching it", false)

proc removeTempLeftovers*(stateDir: string): seq[string] =
  ## A writer the crash interrupted between creating its temporary file
  ## and renaming it leaves ``.<leaf>.repro-tmp-<pid>`` (the no-follow
  ## writer's naming) or ``current.tmp-<pid>`` behind. Recovery removes
  ## exactly those names, without following anything, in the directories
  ## the interrupted switch wrote to (its plan's targets), ``/etc/repro``
  ## and the state directory.
  var dirs = @["/etc/repro", stateDir, stateDir / "addon"]
  if hasPendingPlan(stateDir):
    try:
      for sp in readPendingPlan(stateDir).plans:
        if sp.targetPath.len > 0 and parentDir(sp.targetPath) notin dirs:
          dirs.add(parentDir(sp.targetPath))
    except CatchableError:
      discard
  for d in dirs:
    if not dirExists(d) or symlinkExists(d): continue
    for kind, path in walkDir(d):
      if kind notin {pcFile, pcLinkToFile, pcLinkToDir}: continue
      let name = extractFilename(path)
      let ours = (name.startsWith(".") and ".repro-tmp-" in name and
                  name.rsplit('-', 1)[^1].allCharsInSet(Digits)) or
                 (d == stateDir and name.startsWith("current.tmp-"))
      if ours:
        try:
          if removeLeafNoFollow(path): result.add(path)
        except CatchableError:
          discard

proc finishCommittedSwitch(stateDir: string; m: PendingMarker): seq[string] =
  ## The switch committed (``current`` names its attempt) and died in
  ## step 9: promote its store root, apply retention, clear the marker.
  let current = readCurrentGenerationId(stateDir)
  var prefixIds: seq[PrefixIdBytes]
  let lp = generationLedgerPath(stateDir, current)
  if fileExists(lp):
    for e in readLedger(lp).entries:
      if e.class == lcStorePrefix and e.sha256.len > 0:
        prefixIds.add(parsePrefixIdHex(e.sha256))
  promotePendingRoot(current, prefixIds)
  var previous = ""
  try:
    previous = readGenerationEnvelope(pointerPath(stateDir, current)).previousGenerationId
  except CatchableError:
    discard
  # The same derivation as every other retention run: a generation a
  # running managed unit may still run from is held (spec §5.2). The
  # invocation table was not updated by the interrupted commit, so it can
  # only name an older generation for a unit -- which keeps more, never
  # less.
  let ledger = if fileExists(lp): readLedger(lp)
               else: readLedger(ledgerCopyPath(stateDir))
  # The committed generation owns its attempt's root snapshot, recorded
  # before the marker goes (spec §7.2).
  if m.rootSnapshot.len > 0:
    recordGenerationSnapshot(stateDir, current, m.rootSnapshot)
  let dropped = pruneGenerationRoots(current, previous,
    held = heldGenerations(stateDir, ledger, current))
  var notes = deleteGenerationSnapshots(stateDir, dropped, hostSnapshotSite())
  if m.purpose == "revert" and not (m.guardAttempt.len > 0 and
      hasRolledBackRecord(stateDir, m.revertOf)):
    # (A guarded revert records it at its own step 9, before its marker
    # goes; only one that died before doing so is recorded here.)
    recordRolledBack(stateDir, m.revertOf, m.fromGeneration, current,
      m.revertReason & " (the revert was finished at boot)", false)
    # This recovery completed the revert: the reverted attempt's root
    # snapshot goes (spec §13 decisions 105, 119).
    if m.revertSnapshot.len > 0:
      notes.add(deleteSnapshotByKey(stateDir, m.revertSnapshot,
        "the recovery's revert", hostSnapshotSite()).left)
  clearPendingMarker(stateDir)
  clearPendingPlan(stateDir)
  # A switch the rollback floor kept in place is resolved by its commit.
  if fileExists(floorHoldPath(stateDir)): removeFile(floorHoldPath(stateDir))
  @["the switch to " & current & " had committed (marker at step " &
    $m.step & "); finished its step 9"] & notes

proc commitStagedGeneration(stateDir, attempt: string): string =
  ## Commit ``attempt`` from the envelope its apply staged before the
  ## after-hook (``ApplyPhaseHooks.stageEnvelope``): the envelope durably
  ## in place, then `current` moved by a rename. "" on success, else why
  ## not. Neither replays nor re-confirms anything (§13 decision 117).
  let staged = stagedEnvelopePath(stateDir, attempt)
  if not fileExists(staged):
    return "no staged envelope at " & staged
  try:
    let env = readGenerationEnvelope(staged)
    if env.generationId != attempt:
      return staged & " stages generation " & env.generationId & ", not " &
        attempt
    writeGenerationEnvelope(pointerPath(stateDir, attempt), env)
    writeCurrentGenerationId(stateDir, attempt)
  except CatchableError as e:
    return "the commit failed: " & e.msg
  ""

proc recoverGuardedMarker(stateDir: string; m: PendingMarker; atBoot: bool;
                          driver: CollisionDriver;
                          confirmCap: int): RecoveryOutcome =
  ## A network switch's marker (spec §4.5 step 4 and its table; §13
  ## decisions 87, 102, 117, 121, 123, 125, 126), decided before anything
  ## else. The caller holds the host apply lock, so the owner is dead (or
  ## this is its own recovery).
  ##
  ## - ``disarmed``: its checks passed; it is committed (from the staged
  ##   envelope when `current` does not name it yet) without a replay or a
  ##   re-confirmation, and any timer of the attempt is stopped. A commit
  ##   that fails leaves the marker ``disarmed``, reported.
  ## - ``armed`` in this boot with a timer of the attempt pending: the
  ##   timer is the actor; recovery reports it and changes nothing.
  ## - every other un-disarmed state is reverted, never replayed: ``armed``
  ##   with no timer ("armed, its timer gone") or from an earlier boot
  ##   ("armed across a reboot"), ``fired`` and ``reverting`` (their
  ##   reason, with "; revert interrupted by a reboot" after a reboot). A
  ##   fresh guard timer is armed first when none of the attempt's is
  ##   loaded -- always after a reboot -- and the network objects are put
  ##   back from the guard's record before the revert. The attempt's
  ##   timers are stopped last.
  let g = readGuardedMarker(stateDir)
  let mm = if g.present: g.marker else: m
  let attempt = mm.guardAttempt
  let boot = currentBootId()
  let armedBoot = if mm.guardBoot.len > 0: mm.guardBoot else: mm.ownerBoot
  let sameBoot = armedBoot.len > 0 and armedBoot == boot
  let current = readCurrentGenerationId(stateDir)
  if mm.guard == "disarmed":
    if mm.attempt.len == 0:
      return RecoveryOutcome(resolved: false, lines: @["the network guard " &
        "is disarmed but the marker names no attempt to commit; the marker " &
        "stays"])
    if current != mm.attempt:
      let why = commitStagedGeneration(stateDir, mm.attempt)
      if why.len > 0:
        return RecoveryOutcome(resolved: false, lines: @["the network " &
          "generation " & mm.attempt & " was disarmed; committing it failed (" &
          why & "); the marker stays `disarmed`, nothing is reverted, and " &
          "the next recovery retries the commit (§13 decision 117)"])
    result.lines.add(finishCommittedSwitch(stateDir, mm))
    result.lines.add("committed the disarmed network generation " &
      mm.attempt & " without replaying or re-confirming it (§13 decision 117)")
    for n in finishGuardRevert(stateDir, attempt): result.lines.add(n)
    result.resolved = true
    return
  if mm.guard == "armed" and sameBoot and loadedGuardTimers(attempt).len > 0:
    return RecoveryOutcome(resolved: true, deferred: true, lines: @["the " &
      "network guard of attempt " & attempt & " is armed and its timer is " &
      "pending: the timer is the actor; recovery changes nothing"])
  var reason =
    case mm.guard
    of "armed": (if sameBoot: TimerGoneReason else: ArmedAcrossRebootReason)
    else:
      (if mm.guardReason.len > 0: mm.guardReason else: mm.guard) &
        (if sameBoot: "" else: InterruptedByRebootSuffix)
  let b = beginGuardRevert(stateDir, mm, reason)
  result.lines.add(b.notes)
  if mm.guard == "armed": reason = b.reason
  try:
    for p in restoreNetworkObjects(readGuardRecord(stateDir)):
      result.lines.add("network restore: " & p)
  except CatchableError as e:
    result.lines.add("network restore: the guard record is unreadable: " &
      e.msg)
  if mm.purpose == "revert":
    # The revert of the attempt was itself interrupted: it is finished by
    # replaying it (a revert is never reverted).
    let cap = if atBoot: BootConfirmCapSec else: 0
    try:
      # The replayed revert records `rolled-back` itself, with this
      # reason, before its marker goes (spec §4.5 step 4).
      let r = runAddonApply(AddonApplyOptions(stateDir: stateDir,
        hostIdentity: readHostname(), replay: true, purpose: "replay",
        driver: driver, nonBlockingStarts: atBoot,
        revertOf: mm.revertOf, revertReason: guardDiagnostic(reason) &
          " (the revert was finished by recovery)",
        replayOf: mm.purpose, confirmCapSec: cap))
      if mm.revertSnapshot.len > 0:
        result.lines.add(deleteSnapshotByKey(stateDir, mm.revertSnapshot,
          "the recovery's revert", hostSnapshotSite()).left)
      result.lines.add("finished the network guard's revert: generation " &
        r.generationId & " is current (" & reason & ")")
    except CatchableError as e:
      result.lines.add("the network guard's revert could not be finished " &
        "(" & e.msg & "); the marker keeps its state and the attempt's " &
        "timer, or the next recovery, finishes it")
      return
  else:
    try:
      let rv = revertAfterFailedReplay(stateDir, mm, "", driver,
        nonBlockingStarts = atBoot, confirmCapSec = confirmCap,
        guardReason = reason)
      if not rv.reverted:
        result.lines.add("the network switch could not be reverted: " &
          rv.why & "; the marker stays for an operator")
        return
      result.lines.add("reverted the network switch (" & reason & ") to " &
        mm.fromGeneration & ", re-applied as generation " & rv.generationId)
      result.lines.add(rv.snapshotLeft)
    except CatchableError as e:
      result.lines.add("the network guard's revert could not be completed " &
        "(" & e.msg & "); the marker keeps its state and the attempt's " &
        "timer, or the next recovery, finishes it")
      return
  for n in finishGuardRevert(stateDir, attempt): result.lines.add(n)
  result.resolved = true

proc recoverMarker(stateDir: string; atBoot: bool;
                   driver: CollisionDriver = nil): RecoveryOutcome =
  ## Finish or revert an interrupted switch (see the module header).
  if not hasPendingMarker(stateDir):
    return RecoveryOutcome(resolved: true)
  when mutated("reassert-skips-recovery"):
    # The negative control: an interrupted switch is left as it is found.
    return RecoveryOutcome(resolved: true,
      lines: @["(mutation reassert-skips-recovery: not recovered)"])
  var m: PendingMarker
  try:
    m = readPendingMarker(stateDir)
  except CatchableError as e:
    return RecoveryOutcome(resolved: false,
      lines: @["the pending marker is unreadable: " & e.msg])
  # The switch that owns this marker (re)starts repro-addon-reassert.service
  # while it holds the host apply lock, so waiting on it would stall that
  # switch for the whole deadline: when the holder IS the marker's owner,
  # live in this boot, recovery is that switch's own and this run defers.
  # Any other holder -- a deploy-agent tick, an operator apply -- does not
  # own the marker: it is waited for like any apply, and if it still holds
  # the lock at the deadline the run is degraded, never deferred, so an
  # interrupted switch is not silently left to the next boot.
  var (hostLock, holder, holderPids) =
    tryAcquireHostApplyLock("add-on switch recovery")
  if holder.len > 0 and m.guardAttempt.len > 0 and not atBoot:
    # `repro system addon recover` (or an apply's pending check) while the
    # owner of a network switch is alive waits for the host apply lock as
    # any apply does, bounded, and then acts on whatever the marker says,
    # or finds it gone (spec §4.5 step 4's table). The re-assert unit
    # defers to it instead (below).
    try:
      hostLock = acquireHostApplyLock("add-on switch recovery")
    except ELockTimeout as e:
      return RecoveryOutcome(resolved: false,
        lines: @["the network switch's owner holds the host apply lock: " &
                 e.msg & "; nothing was changed"])
    if not hasPendingMarker(stateDir):
      hostLock.release()
      return RecoveryOutcome(resolved: true, lines: @["waited for the " &
        "switch that held the host apply lock; its marker is gone, so " &
        "there is nothing to recover"])
    try: m = readPendingMarker(stateDir)
    except CatchableError as e:
      hostLock.release()
      return RecoveryOutcome(resolved: false,
        lines: @["the pending marker is unreadable: " & e.msg])
  elif holder.len > 0:
    if markerOwnerLive(m) and m.ownerPid in holderPids:
      return RecoveryOutcome(resolved: true, deferred: true,
        lines: @["the switch that owns the pending marker (pid " &
                 $m.ownerPid & ") holds the host apply lock; recovery is " &
                 "its own"])
    try:
      hostLock = acquireHostApplyLock("add-on switch recovery")
    except ELockTimeout as e:
      return RecoveryOutcome(resolved: false,
        lines: @["an interrupted switch is pending and another apply, not " &
                 "the switch that owns it, holds the host apply lock: " &
                 e.msg])
  defer: hostLock.release()
  let lock = takeLockForRecovery(stateDir, atBoot)
  if not lock.ok:
    return RecoveryOutcome(resolved: false, lines: @[lock.why])
  defer:
    if lock.took: releaseApplyLock(stateDir)
  seamPauseRecovery(stateDir)
  let swept = removeTempLeftovers(stateDir)
  if swept.len > 0:
    result.lines.add("removed temporary files a crashed write left: " &
      swept.join(", "))
  let header = "interrupted switch from " &
    (if m.fromGeneration.len > 0: m.fromGeneration else: "(no generation)") &
    " (" & (if m.purpose.len > 0: m.purpose else: "apply") & ", status " &
    m.status & ", last step completed " & $m.step & ")"
  result.lines.add(header)
  let current = readCurrentGenerationId(stateDir)
  # A network switch's guard is decided before anything below (spec §7.2
  # *Recovery*, §4.5 step 4): it is committed only once disarmed, and
  # otherwise reverted, never replayed.
  var guardedHere = m.guardAttempt.len > 0
  when mutated("recovery-replays-armed"):
    # FALSIFYING MUTATION (e2e_omarchy_addon_network_guard_reverts_lost_address,
    # control (a) after a reboot): an `armed` network marker falls through
    # to the replay below, re-applying the generation that cut the host off.
    if m.guard == "armed": guardedHere = false
  if guardedHere:
    let r = recoverGuardedMarker(stateDir, m, atBoot, driver,
                                 if atBoot: BootConfirmCapSec else: 0)
    result.lines.add(r.lines)
    result.resolved = r.resolved
    result.deferred = r.deferred
    return
  if m.attempt.len > 0 and current == m.attempt:
    try:
      result.lines.add(finishCommittedSwitch(stateDir, m))
      result.resolved = true
    except CatchableError as e:
      result.lines.add("finishing the committed switch failed: " & e.msg)
    return
  # At boot the replay's confirm and, if it fails, its revert's run inside
  # the re-assert unit's start timeout: each is capped (§7.7).
  let cap = if atBoot: BootConfirmCapSec else: 0
  try:
    let r = runAddonApply(AddonApplyOptions(stateDir: stateDir,
      hostIdentity: readHostname(), replay: true, purpose: "replay",
      driver: driver, nonBlockingStarts: atBoot,
      revertOf: m.revertOf, revertReason: m.revertReason,
      replayOf: m.purpose, confirmCapSec: cap))
    if m.purpose == "revert":
      # The interrupted switch was itself the revert of a failed one: the
      # failed attempt is recorded rolled-back now that the revert is done,
      # and its root snapshot goes (spec §13 decisions 105, 119).
      recordRolledBack(stateDir, m.revertOf, m.fromGeneration, r.generationId,
        m.revertReason & " (the revert was finished at boot)", false)
      if m.revertSnapshot.len > 0:
        result.lines.add(deleteSnapshotByKey(stateDir, m.revertSnapshot,
          "the recovery's revert", hostSnapshotSite()).left)
    result.lines.add("replayed the switch to completion: generation " &
      r.generationId & " is current")
    # What the replay kept rather than undo (an object changed since the
    # plan; a taken-over backup file whose restore no rule allows, spec
    # §4.3.1) is reported, as the apply itself reports its drift.
    for d in r.drift:
      result.lines.add("left in place as drift: " & d)
    result.resolved = true
  except AddonRolledBack as e:
    result.lines.add("the replay did not complete and was reverted: " & e.msg)
    result.resolved = true
  except CatchableError as e:
    # The replay failed without reverting itself. Revert from here
    # whenever a revert is possible (spec §7.2); keep the marker only when
    # it is not, or when the revert fails too.
    let failed = e.msg
    try:
      let rv = revertAfterFailedReplay(stateDir, m, failed, driver,
        nonBlockingStarts = atBoot, confirmCapSec = cap)
      if rv.reverted:
        result.lines.add("the replay failed (" & failed & "); reverted to " &
          m.fromGeneration & " (re-applied as generation " &
          rv.generationId & ", from " & rv.source & ")")
        result.lines.add(rv.snapshotLeft)
        result.resolved = true
      else:
        result.lines.add("the switch could be neither finished nor " &
          "reverted; the marker stays for an operator (`repro system " &
          "addon recover`): " & failed & "; no revert: " & rv.why)
    except CatchableError as e2:
      result.lines.add("the switch could be neither finished nor " &
        "reverted; the marker stays for an operator (`repro system addon " &
        "recover`): " & failed & "; the revert failed too: " & e2.msg)

proc recoverPendingSwitch*(stateDir: string; atBoot: bool;
                           driver: CollisionDriver = nil;
                           site = hostSnapshotSite()): RecoveryOutcome =
  ## Finish or revert an interrupted switch (``recoverMarker``), then run
  ## the orphan sweep of the add-on's root snapshots (spec §7.2, §7.7 step
  ## 1; §13 decision 116): in every recovery, whether or not a marker was
  ## found, under the host apply lock and after the marker was decided.
  ## A recovery that deferred to the live switch leaves the sweep to that
  ## switch; one that finds another apply holding the lock leaves it to
  ## that apply's own pending check. A recovery that did not resolve the
  ## marker sweeps nothing: the marker stays for an operator, and the
  ## snapshots of the switch it records are its way back. ``site`` is
  ## where snapper is (a fixture tree in a unit test).
  result = recoverMarker(stateDir, atBoot, driver)
  if result.deferred: return
  when mutated("reassert-skips-recovery"):
    return
  when mutated("recovery-skips-snapshot-sweep"):
    return
  if not result.resolved:
    result.swept = @[diagnosticMessage(adSnapshotLeft, "the orphan sweep " &
      "did not run: the pending marker in " & stateDir & " stays")]
    return
  var (hostLock, holder, _) = tryAcquireHostApplyLock("add-on snapshot sweep")
  if holder.len > 0: return
  defer: hostLock.release()
  result.swept = sweepFor(stateDir, markerStateDirs(stateDir), site)

proc startCommittedUnits*(stateDir: string; noBlock: bool): seq[string] =
  ## After a recovery: every unit the current generation started is
  ## started if it is not active (a boot may have tried it from the
  ## interrupted state and given up). ``--no-block`` at boot, where the
  ## boot transaction owns the order.
  let lp = ledgerCopyPath(stateDir)
  if not fileExists(lp): return
  for e in readLedger(lp).entries:
    # Targets follow their units, and this unit is the one running.
    if e.class != lcUnit or not e.started or e.unit.len == 0 or
        e.unit.endsWith(".target") or e.unit == ReassertUnit:
      continue
    # Never a second instance beside one that is still alive (an
    # exclusive unit whose stop could not be confirmed, §7.3).
    if not unitIsActive(e.unit) and unitAliveness(e.unit) == uaEmpty:
      let args = if noBlock: @["start", "--no-block", "--", e.unit]
                 else: @["start", "--", e.unit]
      let r = runSystemctl(args)
      result.add("started " & e.unit & (if r.exitCode == 0: "" else:
        " (failed: " & r.output.strip() & ")"))

proc checkCurrent*(stateDir: string; r: var ReassertReport) =
  ## Step 2 of the module header, adding to ``r``.
  if not dirExists(StoreRoot):
    r.findings.add("degraded: the store " & StoreRoot & " is missing")
    r.status = "degraded"
  let current = readCurrentGenerationId(stateDir)
  if current.len == 0:
    r.findings.add("degraded: no current generation")
    r.status = "degraded"
    return
  let lp = ledgerCopyPath(stateDir)
  if not fileExists(lp):
    r.findings.add("degraded: no add-on ledger at " & lp)
    r.status = "degraded"
    return
  var l: Ledger
  try:
    l = readLedger(lp)
  except CatchableError as e:
    r.findings.add("degraded: the ledger is unreadable: " & e.msg)
    r.status = "degraded"
    return
  if l.generation != current:
    r.findings.add("degraded: the ledger copy describes " & l.generation &
      ", not the current generation " & current)
    r.status = "degraded"
  let quarantined = readStoreQuarantine()
  for e in l.entries:
    if e.class == lcStorePrefix and not dirExists(e.path):
      r.findings.add("degraded: store object " & e.path & " is missing")
      r.status = "degraded"
    elif e.class == lcStorePrefix and e.path in quarantined:
      # Spec §13 decision 46: verification found its bytes altered.
      r.findings.add("degraded: store object " & e.path & " is quarantined " &
        "(its bytes differed from its realisation digest)")
      r.status = "degraded"
    if e.class == lcStaticLink:
      let target = readStaticTarget()
      if target != e.linkTarget:
        r.findings.add("drift: " & StaticLinkPath & " points at " &
          (if target.len > 0: target else: "nothing") & ", current's tree is " &
          e.linkTarget)
        if r.status == "ok": r.status = "drift"
  for e in l.entries:
    if e.class in {lcStorePrefix, lcStaticLink}: continue
    let d = try: observeDrift(e) except CatchableError as ex: ex.msg
    if d.len == 0: continue
    if d.startsWith("dangling"):
      r.findings.add("degraded: " & $e.class & " " & e.path & ": " & d)
      r.status = "degraded"
    else:
      r.findings.add("drift: " & $e.class & " " & e.path & ": " & d)
      if r.status == "ok": r.status = "drift"
    if e.class == lcUnit and e.collision == "replace":
      r.notes.add(e.unit & ": the add-on's /etc unit shadows the package's")

type
  SwitchRecovery* = proc (stateDir: string): RecoveryOutcome {.closure,
                                                              gcsafe.}
    ## How the apply guard recovers a switch: `recoverPendingSwitch` in
    ## production; a test seam records the call instead of driving
    ## systemctl and /etc on the test machine.

proc guardStateDirs*(applyStateDir: string;
                     pointer = AddonStateDirPointer;
                     pointerOwner = 0): seq[string] =
  ## Where an interrupted add-on switch's marker can be: the state
  ## directory of the apply asking, the add-on's own state directory as
  ## bootstrap recorded it (an add-on bootstrapped with `--state-dir X` is
  ## found even by an apply that was not given X, such as a deploy-agent
  ## tick), the resolved system state directory, and the default.
  ## Deduplicated, in that order (``root_snapshot.markerStateDirs``).
  markerStateDirs(applyStateDir, pointer, pointerOwner)

proc ownerlessSwitchMayBeLive*(stateDir: string; pid: int): string =
  ## For a marker that records no owner (a build before 931aae1ed2 wrote
  ## it): why its switch may still be running, or "" when it cannot be.
  ## Those builds held the state directory's apply lock for the whole
  ## switch -- taken before the marker was written, released after it was
  ## cleared -- and recorded their PID in it. So a live old switch always
  ## leaves a lock record whose PID is running. No record, our own, or a
  ## dead holder means no old switch is running. This uses no wall clock
  ## (a host without an RTC can run with a wrong one until NTP syncs), and a
  ## reused PID can only err towards refusing.
  let rec = readApplyLockRecord(stateDir)
  if rec.present and rec.pid > 0 and rec.pid != pid and
      processAlive(rec.pid):
    return "its state directory's apply lock is held by pid " & $rec.pid &
      ", which is running: it may be the older build's switch"
  ""

proc checkPendingSwitches*(applyStateDir: string; recover: SwitchRecovery;
                           pid = getCurrentProcessId();
                           bootId = currentBootId();
                           pointer = AddonStateDirPointer;
                           pointerOwner = 0;
                           site = hostSnapshotSite()):
    tuple[ok: bool; why: string; notes: seq[string]] =
  ## The apply-side check (§7.7), run with the host apply lock held. For
  ## each pending marker: one written by this process, in this boot, is
  ## the caller's own switch and is left to it. A marker an older build
  ## wrote (no owner recorded) is recovered unless that build's switch may
  ## still be running (``ownerlessSwitchMayBeLive``), in which case the
  ## apply refuses. Every other marker belongs to a switch that is gone,
  ## whatever process now has its PID: it is recovered first, and the
  ## apply refuses when recovery does not resolve it.
  for dir in guardStateDirs(applyStateDir, pointer, pointerOwner):
    if not hasPendingMarker(dir): continue
    var m = PendingMarker()
    var readable = true
    try:
      m = readPendingMarker(dir)
    except CatchableError:
      readable = false
    if readable:
      if markerOwnedByCaller(m, pid, bootId):
        continue
      if m.ownerPid == 0:
        let live = ownerlessSwitchMayBeLive(dir, pid)
        if live.len > 0:
          return (false, "the pending marker in " & dir & " records no " &
            "owner (an older build wrote it) and " & live, result.notes)
    let rec = recover(dir)
    result.notes.add(rec.swept)
    if not (rec.resolved and not rec.deferred):
      return (false, dir & ": " & rec.lines.join("; "), result.notes)
  # Every apply's pending check runs the orphan sweep once the markers are
  # decided (spec §7.2, §13 decision 116); the caller holds the host apply
  # lock. What it deleted and what it could not are the caller's to print.
  when not mutated("recovery-skips-snapshot-sweep"):
    result.notes.add(sweepFor(applyStateDir, markerStateDirs(applyStateDir,
      pointer, pointerOwner), site))
  result.ok = true

proc installPendingSwitchGuard*(recover: SwitchRecovery = nil;
                                pointer = AddonStateDirPointer;
                                pointerOwner = 0) =
  ## Make every `runInfraApply` on this host run `checkPendingSwitches`
  ## before it mutates anything (ReproOS Add-On Mode §7.7).
  var r = recover
  if r == nil:
    r = proc (dir: string): RecoveryOutcome {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        recoverPendingSwitch(dir, atBoot = false)
  pendingSwitchGuard = proc (applyStateDir: string):
      tuple[ok: bool; why: string; notes: seq[string]] {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      checkPendingSwitches(applyStateDir, r, pointer = pointer,
        pointerOwner = pointerOwner)

installPendingSwitchGuard()

proc renderReassert*(r: ReassertReport): string =
  result = "repro-addon reassert: " & r.status & "\n"
  for x in r.recovery: result.add("  recovery: " & x & "\n")
  for f in r.findings: result.add("  " & f & "\n")
  for n in r.notes: result.add("  note: " & n & "\n")

const QuarantinedFinding = " is quarantined "
  ## How ``checkCurrent`` words a store object in use that verification
  ## quarantined.

proc storeFindings*(findings: openArray[string]):
    seq[tuple[trigger: string; found: seq[string]]] =
  ## The re-assert's store findings grouped under the DET-AO-5 trigger that
  ## names what happened (spec §10.4): a quarantined object -- present, its
  ## bytes other than at realisation -- is ``store-digest-mismatch``; an
  ## absent object or store is ``store-object-missing``. Empty groups are
  ## left out.
  var missing, altered: seq[string]
  for f in findings:
    if not ("store object" in f or ("the store " & StoreRoot) in f): continue
    when mutated("reassert-store-trigger-missing"):
      missing.add(f)    # FALSIFYING BUILD: session 1's single trigger
    else:
      if QuarantinedFinding in f: altered.add(f) else: missing.add(f)
  if missing.len > 0: result.add(("store-object-missing", missing))
  if altered.len > 0: result.add(("store-digest-mismatch", altered))

proc recordReassertEvidence*(r: ReassertReport; stateDir: string;
                             atBoot: bool; site = defaultSite(DefaultStateDir);
                             bootIdPath = "/proc/sys/kernel/random/boot_id") =
  ## The re-assert's evidence record (DET-AO-4): one per run, a detection
  ## when the result is ``drift`` or ``degraded``, with the boot id so the
  ## off-host check can require one per boot (DET-AO-8). A missing store
  ## object is also a store-integrity detection (DET-AO-5). Never raises.
  var site = site
  site.stateDir = stateDir
  let boot = try: readFile(bootIdPath).strip()
             except IOError, OSError: ""
  let fields = @[("status", r.status), ("bootId", boot),
                 ("purpose", if atBoot: "boot" else: "operator"),
                 ("count", $r.findings.len),
                 ("message", (r.recovery & r.findings).join("; "))]
  try:
    discard recordEvidence(EvidenceEvent(detector: edReassert,
      category: (if r.status in ["drift", "degraded"]: ecDetection
                 else: ecAudit),
      trigger: r.status, kind: "reassert-" & r.status, fields: fields,
      attest: true), site)
    for (trigger, found) in storeFindings(r.findings):
      discard recordEvidence(EvidenceEvent(detector: edStore,
        category: ecDetection, trigger: trigger,
        fields: @[("bootId", boot), ("message", found.join("; "))],
        attest: true), site)
  except CatchableError as e:
    stderr.write("repro-addon: cannot write the re-assert's evidence " &
      "record: " & e.msg & "\n")

var lateKeyNoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
proc cRename(src, dst: cstring): cint {.importc: "rename", header: "<stdio.h>".}

proc writePublicHalf(pubPath, pubHex: string) =
  ## ``pubPath`` holding exactly ``pubHex``, ``0444``: written beside it
  ## (``O_EXCL | O_NOFOLLOW``) and renamed over it, so a stale or foreign
  ## file -- or a symbolic link -- at ``pubPath`` is replaced, never
  ## written through.
  let tmp = pubPath & ".new-" & $getCurrentProcessId()
  discard posix.unlink(tmp.cstring)
  let fd = posix.open(tmp.cstring,
                      O_WRONLY or O_CREAT or O_EXCL or lateKeyNoFollow, Mode(0o444))
  if fd < 0: raiseOSError(osLastError(), tmp)
  let line = pubHex & "\n"
  if posix.write(fd, unsafeAddr line[0], line.len) != line.len:
    discard posix.close(fd)
    discard posix.unlink(tmp.cstring)
    raiseOSError(osLastError(), tmp)
  discard fsync(fd)
  discard posix.close(fd)
  if cRename(tmp.cstring, pubPath.cstring) != 0:
    let err = osLastError()
    discard posix.unlink(tmp.cstring)
    raiseOSError(err, pubPath)

proc ensureLateKeyPair*(keyPath, pubPath: string):
    tuple[pubHex: string; created, pubRewritten: bool] =
  ## The deferred recipient key at ``keyPath`` -- created when missing,
  ## ``0400``, never replacing one (``ensureRecipientKeyFile``) -- and its
  ## public half at ``pubPath``, always DERIVED from the key: a
  ## ``recipient.pub`` that is missing, or that is not the key's (a key
  ## removed while its ``.pub`` stayed, a hand edit), is rewritten, so the
  ## half an operator registers is never one no key on the host matches.
  result.created = not fileExists(keyPath)
  let key = ensureRecipientKeyFile(keyPath)
  result.pubHex = peerAuth.publicKeyHex(key.publicKey)
  var current = ""
  if fileExists(pubPath) and not symlinkExists(pubPath):
    try: current = readFile(pubPath).strip()
    except IOError: current = ""
  if current != result.pubHex:
    result.pubRewritten = fileExists(pubPath) or symlinkExists(pubPath)
    writePublicHalf(pubPath, result.pubHex)

proc createLateRecipientKey*(stateDir: string): seq[string] =
  ## A host bootstrapped with ``--defer-recipient-key`` (an image's assembly
  ## boot, spec §6.5.2) creates its own secrets recipient key here, at its
  ## first real boot, so no image ever carries one: generated on the host,
  ## ``0400`` from the start and never replacing a key, its public half
  ## beside it and always the key's own (``ensureLateKeyPair``). Not during
  ## the assembly boot itself (``ImageAssemblyDir`` present). Every later
  ## boot reports the public half again: an operator reads it from this
  ## unit's journal, which a distribution may keep in RAM only (Raspberry
  ## Pi OS). Returns the notes for the report; raises on a failure, which
  ## the caller reports.
  let ledgerPath = ledgerCopyPath(stateDir)
  if not fileExists(ledgerPath): return
  var deferred = false
  for e in readLedger(ledgerPath).entries:
    if e.class == lcLateKey and e.path == RecipientKeyPath: deferred = true
  if not deferred: return
  if dirExists(ImageAssemblyDir):
    return @["recipient key: deferred; this is an image's assembly boot, " &
             "which creates none"]
  let k = ensureLateKeyPair(RecipientKeyPath, RecipientPubPath)
  if k.pubRewritten:
    result.add("recipient key: " & RecipientPubPath & " was not the key's " &
      "public half; rewritten from the key")
  if not k.created:
    result.add("recipient key: this host's own; public half " & k.pubHex)
    return
  result.add("recipient key: created this host's own; public half " & k.pubHex)
  discard recordEvidence(EvidenceEvent(detector: edBootstrap,
    category: ecAudit, trigger: "recipient-key", kind: "recipient-key",
    fields: @[("recipientKey", k.pubHex), ("path", RecipientKeyPath)]),
    defaultSite(stateDir))

proc runAddonReassert*(stateDir = DefaultStateDir; atBoot = false;
                       driver: CollisionDriver = nil): ReassertReport =
  ## Recover, check, report. Never raises: every failure is a finding.
  result.status = "ok"
  try:
    let rec = recoverPendingSwitch(stateDir, atBoot, driver)
    result.recovery = rec.lines
    # The sweep's report (spec §7.2): what it deleted, and an
    # `EAddOnSnapshotLeft` line for each it could not. Neither is drift of
    # the host's configuration, so neither changes the status.
    result.notes.add(rec.swept)
    if rec.deferred:
      # Mid-switch: the live state is the switch's, not drift. Report and
      # leave the check to the run after the switch.
      result.status = "deferred"
      try:
        createDir(stateDir / "addon")
        writeFileAtomic(reassertReportPath(stateDir),
          "time\t" & $now().utc & "\n" & renderReassert(result), 0o600)
      except CatchableError:
        discard
      return
    if not rec.resolved:
      result.status = "degraded"
    elif rec.lines.len > 0:
      result.recovery.add(startCommittedUnits(stateDir, noBlock = atBoot))
  except CatchableError as e:
    result.recovery.add("recovery failed: " & e.msg)
    result.status = "degraded"
  try:
    checkCurrent(stateDir, result)
  except CatchableError as e:
    result.findings.add("degraded: " & e.msg)
    result.status = "degraded"
  # A deferred recipient key (spec §6.5.2): the host's own, created once.
  try:
    result.notes.add(createLateRecipientKey(stateDir))
  except CatchableError as e:
    result.findings.add("degraded: cannot create the deferred recipient " &
      "key: " & e.msg)
    result.status = "degraded"
  # --- Step 3 (milestone A7): secrets. BEGIN A7 hook -------------------
  let sec = reassertSecrets(stateDir, defaultSecretsLayout())
  result.notes.add(sec.notes)
  result.findings.add(sec.findings)
  if sec.status == "degraded":
    result.status = "degraded"
  elif sec.status == "drift" and result.status == "ok":
    result.status = "drift"
  # --- END A7 hook -----------------------------------------------------
  try:
    createDir(stateDir / "addon")
    writeFileAtomic(reassertReportPath(stateDir),
      "time\t" & $now().utc & "\n" & renderReassert(result), 0o600)
  except CatchableError:
    discard
  recordReassertEvidence(result, stateDir, atBoot)

# ---------------------------------------------------------------------------
# The guard's verbs: `revert-network` (the timer's) and `confirm`.
# ---------------------------------------------------------------------------

proc runRevertNetwork*(stateDir, previous, attempt, reason: string): int =
  ## ``repro system addon revert-network <previous> --attempt <id>
  ## [--reason <text>]``: what a guard timer runs, from the out-of-store
  ## copy ``/var/lib/repro/bin/repro`` (spec §4.5 step 4, "revert-network,
  ## when its timer fires"):
  ##
  ## 1. arm the successor (10 s, decision 109) before waiting for anything;
  ## 2. take the guard lock (blocking); with no marker of this attempt, or
  ##    a ``disarmed`` one, stop the successor and exit 0 changing nothing
  ##    else; otherwise name the successor as the current timer;
  ## 3. on ``armed``: write ``fired`` with its own reason ("guard timer
  ##    fired", or ``--reason`` for a fresh timer) and put the previous
  ##    generation's network objects back from the guard's record -- no
  ##    store needed;
  ## 4. try the host apply lock without waiting: with it (the owner is
  ##    dead), complete the revert as recovery does, which stops the
  ##    attempt's timers last; without it, or when the revert cannot
  ##    complete (the store unreadable), leave the successor armed.
  ##
  ## Never refuses: always exit 0, everything said on stdout (the journal).
  let own = ownGuardUnit()
  let tag = if own.len > 0: own else: "revert-network"
  proc say(s: string) = stdout.writeLine(tag & ": " & s)
  # 1.
  # Verified and repaired first, as before every arm (decision 128): the
  # successor runs the copy this process runs from, and a stale or
  # damaged copy is rewritten (atomically) from the store's add-on binary.
  let (succ, verified) = armVerifiedGuardTimer(stateDir, attempt, previous,
                                               reason, SuccessorIntervalSec)
  if verified.len > 0: say(verified)
  if succ.problem.len > 0:
    say(succ.problem & "; going on with no successor (§13 decisions 125, 126)")
  else:
    say("armed the successor " & succ.unit & " (" & $SuccessorIntervalSec & " s)")
  seamPause(stateDir, "revert-network-before-lock")
  # 2-3.
  var before = ""
  let firedReason = if reason.len > 0: reason else: GuardTimerReason
  let u = updateGuardedMarker(stateDir, attempt,
    proc (m: var PendingMarker): bool =
      before = m.guard
      if m.guard == "disarmed": return false
      if succ.unit.len > 0: m.guardTimer = succ.unit
      if m.guard == "armed":
        m.guard = "fired"
        m.guardReason = firedReason
      true)
  if not u.found or before == "disarmed":
    if succ.unit.len > 0: stopGuardUnit(succ.unit)
    say((if not u.found: "no pending marker names attempt " & attempt
         else: "the guard of attempt " & attempt & " is disarmed") &
        "; stopped the successor, changed nothing else")
    return 0
  if before == "armed":
    say("the guard of attempt " & attempt & " fired (" & firedReason & ")")
    try:
      let problems = restoreNetworkObjects(readGuardRecord(stateDir))
      if problems.len == 0:
        say("restored the previous generation's network objects")
      for p in problems: say("network restore: " & p)
    except CatchableError as e:
      say("network restore: the guard record is unreadable: " & e.msg)
  else:
    say("the guard of attempt " & attempt & " is " & before &
        "; its network restore is done or the reverting actor's")
  seamPause(stateDir, "revert-network-mid-revert")
  # 4.
  var (hostLock, holder, _) = tryAcquireHostApplyLock("network guard revert")
  if holder.len > 0:
    say("the host apply lock is held (" & holder & "); the successor stays " &
        "armed")
    return 0
  defer: hostLock.release()
  let r = recoverPendingSwitch(stateDir, atBoot = false)
  for l in r.lines: say(l)
  if not r.resolved:
    say("the revert did not complete; the successor stays armed")
  0

proc runConfirm*(stateDir, generation: string): int =
  ## ``repro system addon confirm <gen>`` (spec §4.5 step 3): from an SSH
  ## session created after the switch wrote its last network object
  ## (logind's creation time, threat model T55) and from an address the
  ## host does not hold itself, confirm the pending network generation;
  ## the watching apply disarms on it once every invariant holds.
  if not hasPendingMarker(stateDir):
    stderr.writeLine("confirm: no switch is pending")
    return 2
  let m = readPendingMarker(stateDir)
  if m.guardAttempt.len == 0 or m.guard != "armed":
    stderr.writeLine("confirm: the pending switch has no armed network " &
      "guard (" & (if m.guard.len > 0: m.guard else: "none") & ")")
    return 2
  if generation != m.attempt:
    stderr.writeLine("confirm: the pending network generation is " &
      (if m.attempt.len > 0: m.attempt else: "(not yet allocated)") &
      ", not " & generation)
    return 2
  let s = readLogindSession(sessionOfPid(getCurrentProcessId()))
  let host = observeHostNetwork()
  let why = if host.ok:
              confirmProblem(s, m.guardWrittenMono, hostAddressTexts(host))
            else:
              "the host's addresses cannot be read (" & host.why & ")"
  if why.len > 0:
    stderr.writeLine("confirm: refused: " & why & "; the switch is not " &
      "confirmed (spec §4.5 step 3)")
    return 1
  writeConfirm(stateDir, m.guardAttempt, s)
  stdout.writeLine("confirm: generation " & generation & " confirmed from " &
    "SSH session " & s.id & " (" & s.remoteHost & "); the apply disarms " &
    "the guard once every invariant holds")
  0
