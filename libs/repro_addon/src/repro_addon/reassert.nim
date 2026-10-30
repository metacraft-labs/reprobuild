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
##    ``/run/repro/secrets`` from the retained sealed envelope
##    (``secrets_ops.reassertSecrets``, milestone A7); a secret it cannot
##    materialise makes the report ``degraded``;
## 4. **reports** ``ok``, ``drift`` (with the objects) or ``degraded`` (the
##    store, the ledger or a recovery is broken). It never re-applies on
##    drift: that would undo an out-of-band change before anyone saw it.
##
## The report goes to stdout (the journal) and to
## ``<state dir>/addon/reassert-report``. In ``--boot`` mode nothing here
## raises and the exit status is 0, whatever happened.

import std/[os, strutils, times]

import repro_core/host_apply_lock

import repro_infra
import repro_local_store/store

import ./addon_apply
import ./collision
import ./generation0
import ./host_exec
import ./etc_write
import ./ledger
import ./mutations
import ./pending_plan
import ./static_tree
import ./seams
import ./addon_secrets
import ./secrets_ops
import ./switch
import ./transitions

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

proc reassertReportPath*(stateDir: string): string =
  stateDir / "addon" / "reassert-report"

proc takeLockForRecovery(stateDir: string; atBoot: bool):
    tuple[ok: bool; why: string] =
  ## The apply lock, so recovery never races a live switch. A lock taken
  ## in a previous boot (its recorded boot id is not this boot's) belongs
  ## to a switch the reset or power cut killed, whatever process its PID
  ## now names, and is taken over. A lock of this boot is respected unless
  ## its owner is dead; a lock that records no boot id (written by an
  ## older release) is judged by its owner's liveness alone.
  if applyLockOwner(stateDir) == getCurrentProcessId():
    return (true, "")
  var policy = defaultApplyLockPolicy()
  let rec = readApplyLockRecord(stateDir)
  let boot = currentBootId()
  if atBoot and rec.present and rec.bootId.len > 0 and boot.len > 0 and
      rec.bootId != boot:
    policy.forceUnlock = true
  let acq = tryAcquireApplyLock(stateDir, policy)
  if acq.acquired: (true, "")
  else: (false, "a switch is in progress (" &
         describeApplyLockHolder(stateDir, acq) & "); not touching it")

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
      if e.class == lcStorePrefix:
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
  discard pruneGenerationRoots(current, previous,
    held = heldGenerations(stateDir, ledger, current))
  if m.purpose == "revert":
    recordRolledBack(stateDir, m.revertOf, m.fromGeneration, current,
      m.revertReason & " (the revert was finished at boot)", false)
  clearPendingMarker(stateDir)
  clearPendingPlan(stateDir)
  @["the switch to " & current & " had committed (marker at step " &
    $m.step & "); finished its step 9"]

proc recoverPendingSwitch*(stateDir: string; atBoot: bool;
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
  # Zero wait: repro-addon-reassert.service is a oneshot the switch itself
  # (re)starts while holding the host apply lock, so waiting here would stall
  # that switch for the whole deadline. A held lock means a switch is live.
  var (hostLock, holder) = tryAcquireHostApplyLock("add-on switch recovery")
  if holder.len > 0:
    return RecoveryOutcome(resolved: true, deferred: true,
      lines: @["a switch holds the host apply lock; recovery is its own " &
               "(" & holder & ")"])
  defer: hostLock.release()
  let lock = takeLockForRecovery(stateDir, atBoot)
  if not lock.ok:
    return RecoveryOutcome(resolved: false, lines: @[lock.why])
  defer: releaseApplyLock(stateDir)
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
  if m.attempt.len > 0 and current == m.attempt:
    try:
      result.lines.add(finishCommittedSwitch(stateDir, m))
      result.resolved = true
    except CatchableError as e:
      result.lines.add("finishing the committed switch failed: " & e.msg)
    return
  try:
    let r = runAddonApply(AddonApplyOptions(stateDir: stateDir,
      hostIdentity: readHostname(), replay: true, purpose: "replay",
      driver: driver, nonBlockingStarts: atBoot,
      revertOf: m.revertOf, revertReason: m.revertReason,
      replayOf: m.purpose))
    if m.purpose == "revert":
      # The interrupted switch was itself the revert of a failed one: the
      # failed attempt is recorded rolled-back now that the revert is done.
      recordRolledBack(stateDir, m.revertOf, m.fromGeneration, r.generationId,
        m.revertReason & " (the revert was finished at boot)", false)
    result.lines.add("replayed the switch to completion: generation " &
      r.generationId & " is current")
    result.resolved = true
  except AddonRolledBack as e:
    result.lines.add("the replay did not complete and was reverted: " & e.msg)
    result.resolved = true
  except CatchableError as e:
    result.lines.add("the switch could be neither finished nor reverted; " &
      "the marker stays for an operator (`repro system addon recover`): " &
      e.msg)

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
  for e in l.entries:
    if e.class == lcStorePrefix and not dirExists(e.path):
      r.findings.add("degraded: store object " & e.path & " is missing")
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

proc renderReassert*(r: ReassertReport): string =
  result = "repro-addon reassert: " & r.status & "\n"
  for x in r.recovery: result.add("  recovery: " & x & "\n")
  for f in r.findings: result.add("  " & f & "\n")
  for n in r.notes: result.add("  note: " & n & "\n")

proc runAddonReassert*(stateDir = DefaultStateDir; atBoot = false;
                       driver: CollisionDriver = nil): ReassertReport =
  ## Recover, check, report. Never raises: every failure is a finding.
  result.status = "ok"
  try:
    let rec = recoverPendingSwitch(stateDir, atBoot, driver)
    result.recovery = rec.lines
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
  # --- Step 3 (milestone A7): secrets. BEGIN A7 hook -------------------
  let sec = reassertSecrets(stateDir, defaultSecretsLayout())
  if sec.ok:
    result.notes.add(sec.line)
  else:
    result.findings.add(sec.line)
    result.status = "degraded"
  # --- END A7 hook -----------------------------------------------------
  try:
    createDir(stateDir / "addon")
    writeFileAtomic(reassertReportPath(stateDir),
      "time\t" & $now().utc & "\n" & renderReassert(result), 0o600)
  except CatchableError:
    discard
