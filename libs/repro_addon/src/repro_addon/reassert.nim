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
## 3. re-materialises secrets (milestone A7; nothing to do before it);
## 4. **reports** ``ok``, ``drift`` (with the objects) or ``degraded`` (the
##    store, the ledger or a recovery is broken). It never re-applies on
##    drift: that would undo an out-of-band change before anyone saw it.
##
## The report goes to stdout (the journal) and to
## ``<state dir>/addon/reassert-report``. In ``--boot`` mode nothing here
## raises and the exit status is 0, whatever happened.

import std/[os, strutils, times]

import repro_core/file_lock
import repro_core/host_apply_lock

import repro_infra
import repro_local_store/store

import ./addon_apply
import ./collision
import ./generation0
import ./host_exec
import ./ledger
import ./mutations
import ./pending_plan
import ./static_tree
import ./switch

type
  ReassertReport* = object
    status*: string          ## ok | drift | degraded
    recovery*: seq[string]   ## what was done about an interrupted switch
    findings*: seq[string]
    notes*: seq[string]

  RecoveryOutcome* = object
    resolved*: bool
    lines*: seq[string]

proc reassertReportPath*(stateDir: string): string =
  stateDir / "addon" / "reassert-report"

proc bootTimeUnix(): int64 =
  ## The kernel's boot time (``btime`` in ``/proc/stat``), 0 if unknown.
  try:
    for line in readFile("/proc/stat").splitLines():
      if line.startsWith("btime "):
        return parseBiggestInt(line[6 .. ^1].strip())
  except CatchableError:
    discard
  0

proc takeLockForRecovery(stateDir: string; atBoot: bool):
    tuple[ok: bool; why: string] =
  ## The apply lock, so recovery never races a live switch. A lock taken
  ## before this boot belongs to a switch the reset killed, whatever its
  ## PID now names (PIDs are reused across boots): at boot it is taken
  ## over. A lock held by a live switch of this boot is respected.
  if applyLockOwner(stateDir) == getCurrentProcessId():
    return (true, "")
  var policy = defaultApplyLockPolicy()
  let rec = readApplyLockRecord(stateDir)
  if atBoot and rec.present and rec.acquiredAt > 0:
    let bt = bootTimeUnix()
    if bt > 0 and rec.acquiredAt < bt:
      policy.forceUnlock = true
  let acq = tryAcquireApplyLock(stateDir, policy)
  if acq.acquired: (true, "")
  else: (false, "a switch is in progress (" &
         describeApplyLockHolder(stateDir, acq) & "); not touching it")

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
  discard pruneGenerationRoots(current, previous)
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
  var hostLock: HostApplyLock
  try:
    hostLock = acquireHostApplyLock("add-on switch recovery")
  except ELockTimeout as e:
    return RecoveryOutcome(resolved: false,
      lines: @["a switch is in progress; not touching it: " & e.msg])
  defer: hostLock.release()
  let lock = takeLockForRecovery(stateDir, atBoot)
  if not lock.ok:
    return RecoveryOutcome(resolved: false, lines: @[lock.why])
  defer: releaseApplyLock(stateDir)
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
      driver: driver))
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
    if not unitIsActive(e.unit):
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
  try:
    createDir(stateDir / "addon")
    writeFileAtomic(reassertReportPath(stateDir),
      "time\t" & $now().utc & "\n" & renderReassert(result), 0o600)
  except CatchableError:
    discard
