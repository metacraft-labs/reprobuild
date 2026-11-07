## ``repro system addon uninstall [--keep-store]``.
##
## Reverses everything the ledger records, in the order the add-on's
## specification fixes:
##
## 1. stop the add-on's units (for ``repro-store.mount`` that unmounts the
##    store); their install links are the ledger's, removed in step 2;
## 2. remove the units and drop-ins (and any install link ``disable``
##    left), restoring an adopted or replaced unit from the bytes the
##    ledger preserved;
## 3. remove each diversion: the file a generation put at the diverted path
##    first, then ``dpkg-divert --local --rename --remove``, which moves the
##    package's file back;
## 4. restore adopted, replaced and reconciled ``/etc`` files from the bytes
##    the ledger preserved and remove the files and links the add-on
##    created (a link into the static tree is removed as a link; the tree
##    goes with the store), then the directories it created, then
##    ``systemctl daemon-reload``; put every kernel parameter a sysctl
##    fragment set back to the value the ledger recorded before it;
## 5. remove the add-on's state and keys, ``/etc/repro`` (with the static
##    tree link), and the store (unless ``--keep-store``).
##
## Accounts a sysusers fragment created are listed and kept (``account``
## ledger entries): a reused UID would hand the files the old account
## owns to a new owner. A ``systemd.unitState`` requirement owned nothing,
## so its entries change nothing here.
##
## An object whose digest no longer matches the ledger is NOT removed: it
## is reported as drift and left for a human, and the uninstall exits
## non-zero. Accounts the add-on created would be listed and kept (a reused
## UID would hand the files the old account owns to a new owner); generation
## 0 creates none.
##
## The contract is tested as byte identity of the base fingerprint
## (``e2e_addon_bootstrap_uninstall_byte_identity``), with a negative
## control built with ``-d:reproAddonMutation=uninstall-skips-diversion-removal``.

import std/[algorithm, json, os, posix, sets, strutils, times]

import repro_core/host_apply_lock

import repro_elevation/posix_system_driver

import ./addon_apply
import ./collision
import ./attestation
import ./etc_write
import ./evidence
import ./evidence_ship
import ./generation0
import ./handback
import ./host_exec
import ./addon_secrets
import ./ledger
import ./nft_tables
import ./mutations
import ./static_tree
import ./store_custody
import ./store_root
import ./switch


type
  UninstallOptions* = object
    stateDir*: string
    keepStore*: bool
    discardUnacknowledgedStoreEvidence*: bool
      ## §13 decision 62: discard the store evidence even when the sink has
      ## not acknowledged its records, after a signed local record of each
      ## object discarded unshipped is written and printed.
    discardStoreEvidence*: bool
      ## Remove the store evidence directory's entries with the state; an
      ## uninstall that would remove any refuses without it, naming them
      ## first (A11 review finding 14).

  UninstallResult* = object
    removed*: seq[string]
    drift*: seq[string]          ## objects left in place, with the reason
    keptAccounts*: seq[string]
    overrideRecord*: string
      ## §13 decision 62: the signed local record written when store
      ## evidence was discarded unshipped ("" when none was).
    overrideRecordText*: string
    keptEvidence*: seq[string]
      ## Store evidence left with a kept store (``--keep-store``): objects a
      ## crashed recovery left aside, named, not removed.
    undone*: HashSet[string]
      ## ``<class> <path>`` of every ledger entry this run undid; what the
      ## kept ledger of an incomplete run drops.
      ## Accounts the add-on created and leaves in place (spec: sysusers
      ## accounts are never deleted): the ``account`` ledger entries.
    errors*: seq[string]

proc ok*(r: UninstallResult): bool = r.drift.len == 0 and r.errors.len == 0

proc entryKey(e: LedgerEntry): string = $e.class & " " & e.path

proc removeOwned(e: LedgerEntry; r: var UninstallResult;
                 driver: CollisionDriver = nil) =
  ## Undo one file or link the ledger owns, if it is unchanged: put back
  ## the bytes the ledger preserved for an adopted, replaced or reconciled
  ## object (spec §6.4 step 2), else remove it. An entry whose object is
  ## undone here, or was already gone, is recorded in ``r.undone`` so the
  ## kept ledger of an incomplete run no longer lists it. A path a package
  ## came to own since is handed back to it, never removed
  ## (``handback.nim``): a link of the add-on's becomes a regular file with
  ## the same bytes, and the entry counts as undone.
  if driver == nil and e.class in HandBackClasses:
    r.drift.add(e.path & ": left in place: the package database could not " &
      "be read, so whether a package owns it now is unknown")
    return
  var pkg = ""
  try: pkg = newPackageOwner(e, driver)
  except CatchableError as ex:
    r.errors.add(e.path & ": cannot read package ownership: " & ex.msg)
    return
  if pkg.len > 0:
    try:
      if symlinkExists(e.path) and not fileExists(e.path):
        r.drift.add(e.path & ": owned by package " & pkg & " but the " &
          "add-on's link there no longer resolves; left in place")
        return
      materialiseHandBack(e, handBackBytes(e))
      r.removed.add(e.path & " (handed back to package " & pkg & ")")
      r.undone.incl(entryKey(e))
    except CatchableError as ex:
      r.errors.add(e.path & ": " & ex.msg)
    return
  let d = observeDrift(e)
  if d.len > 0:
    if d.startsWith("missing"):
      r.undone.incl(entryKey(e))   # already gone: nothing to undo
      return
    r.drift.add(e.path & ": " & d)
    return
  try:
    if restorePreserved(e):
      r.removed.add(e.path & " (restored)")
    else:
      # Unlinked relative to its parent's descriptor: never through a link
      # planted on the path since it was observed (threat model G29).
      discard removeLeafNoFollow(e.path)
      r.removed.add(e.path)
    r.undone.incl(entryKey(e))
  except CatchableError as ex:
    r.errors.add(e.path & ": " & ex.msg)

proc systemctlOrRecord(args: openArray[string]; r: var UninstallResult) =
  try:
    let res = runSystemctl(args)
    if res.exitCode != 0:
      r.errors.add("systemctl " & args.join(" ") & ": " & res.output.strip())
  except HostToolMissing as ex:
    r.errors.add(ex.msg)

proc remainingLedger*(l: Ledger; r: UninstallResult): Ledger =
  ## ``l`` without the entries this run undid. Entries are dropped only
  ## for objects this run removed (or found already gone): the package's
  ## copy of a file that a removed diversion put back at the same path is
  ## not the add-on's, so re-observing paths would be wrong here.
  result.generation = l.generation
  for e in l.entries:
    let gone = entryKey(e) in r.undone or
               (e.class == lcDir and not dirExists(e.path))
    if not gone: result.entries.add(e)

proc priorModeOwner(value: string): tuple[mode: int; uid, gid: int] =
  ## The mode and owner a fingerprint value records (``d 0755 0:0``,
  ## ``dir 0755 0:0``, ``f 0400 0:0 sha256:…``).
  let f = value.splitWhitespace()
  if f.len < 3:
    raise newException(ValueError, "no mode and owner in '" & value & "'")
  let (uid, gid) = parseOwner(f[2])
  (parseOctInt(f[1]), uid, gid)

type
  CapturedInputs* = object
    ## The pre-bootstrap inputs an uninstall must put back (spec §6.4):
    ## the directories, and every kept file with the bytes it holds NOW --
    ## captured before anything is removed, because the agent's records
    ## (``lcKept``) are rewritten at every tick and must survive byte for
    ## byte, floor included.
    roots*: seq[LedgerEntry]
    files*: seq[tuple[e: LedgerEntry; bytes: string]]
    drift*: seq[string]   ## a content-pinned input whose bytes changed

proc capturePreBootstrapInputs*(l: Ledger): CapturedInputs =
  ## Read every pre-bootstrap input off the host. An agent record is taken
  ## as it is (its content is unpinned, so it cannot drift); a
  ## content-pinned file is taken only when it still has its ledger
  ## digest, else reported in ``drift`` for the drift gate.
  for e in l.entries:
    if not e.isPreBootstrapInput: continue
    case e.class
    of lcRoot, lcDir: result.roots.add(e)
    of lcKept:
      if fileExists(e.path) and not symlinkExists(e.path):
        result.files.add((e, readFile(e.path)))
    of lcEtcFile, lcKey:
      let d = observeDrift(e)
      if d.len > 0:
        if not d.startsWith("missing"):
          result.drift.add(e.path & ": " & d)
        continue
      result.files.add((e, if e.preserved.len > 0 and fileExists(e.preserved):
                              readFile(e.preserved) else: readFile(e.path)))
    else: discard

proc restorePreBootstrapInputs*(captured: CapturedInputs; keepStore: bool;
                                r: var UninstallResult) =
  ## Put the pre-bootstrap inputs back as the preflight found them: the
  ## directories first (parents before children, with their prior mode and
  ## owner), then the kept files from the captured bytes, with the mode
  ## and owner the ledger recorded for them (bootstrap never changes a
  ## kept file's). Below a kept store nothing is re-created: it is still
  ## there.
  for e in captured.roots:
    if keepStore and (e.path == ReproRoot or e.path.startsWith(ReproRoot & "/")):
      continue
    try:
      let (mode, uid, gid) = priorModeOwner(e.replaced)
      if not dirExists(e.path):
        createDir(e.path)
      if posix.chmod(e.path.cstring, Mode(mode)) != 0:
        raiseOSError(osLastError(), "chmod " & e.path)
      if posix.chown(e.path.cstring, Uid(uid), Gid(gid)) != 0:
        raiseOSError(osLastError(), "chown " & e.path)
      r.removed.add(e.path & " (put back as found)")
    except CatchableError as ex:
      r.errors.add(e.path & ": " & ex.msg)
  for (e, bytes) in captured.files:
    try:
      let (uid, gid) = parseOwner(e.owner)
      createDir(parentDir(e.path))
      writeFileNoFollow(e.path, bytes, parseOctInt(e.mode), uid, gid)
      r.removed.add(e.path & " (put back as found)")
    except CatchableError as ex:
      r.errors.add(e.path & ": " & ex.msg)

proc shipAndConfirm*(site: ShipSite; host: string):
    tuple[ok: bool; why: string] =
  ## Ship ``site``'s outbox once and report whether the sink acknowledged
  ## every record in it: ``ok`` only when the outbox is empty after the
  ## run. A sink that refuses, does not answer, or answers without a
  ## receipt leaves the records queued, and ``why`` says how many and why.
  if not fileExists(site.confPath): return (true, "")
  try:
    let conf = loadEvidenceConf(site.confPath)
    let r = runEvidenceShip(site, conf, host)
    if r.pending == 0 and r.error.len == 0: (true, "")
    else: (false, $r.pending & " record(s) still queued" &
           (if r.error.len > 0: ": " & r.error else: ""))
  except CatchableError as e:
    (false, e.msg)

proc shipEvidenceNow*(stateDir: string): tuple[ok: bool; why: string] =
  ## Ship the outbox now and report whether the sink acknowledged every
  ## record in it (an entry leaves the outbox only once acknowledged). A
  ## host without a sink keeps local records only: there is nothing to
  ## wait for.
  shipAndConfirm(defaultShipSite(), readHostName())

const UninstallOverrideDir* = "/var/log/repro-addon"
  ## Where §13 decision 62's override record is written: outside
  ## ``/var/lib/repro`` and ``/etc/repro``, which uninstall removes.

const
  DiscardRecordSchema* = "repro-addon-store-evidence-discarded-unshipped/2"
    ## /2: the record file holds the record alone, and the signature is
    ## over exactly its bytes, beside it in ``<record>.sig`` (§13 decision
    ## 64). /1 signed a compact re-serialisation the file did not hold.
  DiscardRecordSigExt* = ".sig"

proc writeOverrideRecord(custody: CustodySite; dir: string;
                         objects: seq[string]; why: string):
    tuple[path, text: string] =
  ## §13 decisions 62, 63 and 64: the signed local record of the store
  ## evidence an uninstall discards before the sink acknowledged its
  ## records -- every object, every record still queued, why, and the
  ## public half of the key that signs it. The file holds exactly the bytes
  ## signed; the signature (hex) is ``<record>.sig``. The caller has checked
  ## that the attestation key exists (decision 63). Raises when the record
  ## or its signature cannot be written: then nothing is discarded.
  let t = getTime()
  let keyPath = custody.evidence.attestationKey
  let keyless = not fileExists(keyPath)   # only under override-keyless-unsigned
  var j = %*{"schema": DiscardRecordSchema,
             "time": t.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
             "host": custody.evidence.host, "why": why,
             "objects": objects,
             "queuedRecords": outboxEntries(custody.evidence.outbox),
             "attestationKey": (if keyless: "" else: attestationPublicKeyHex(keyPath))}
  if keyless: j["unsigned"] = %"the host has no attestation key"
  result.text = pretty(j) & "\n"
  var signature = ""
  if not keyless:
    when mutated("override-signs-other-bytes"):
      signature = signText("not the record", keyPath).signature
    elif mutated("override-empty-signature"):
      signature = ""
    else:
      signature = signText(result.text, keyPath).signature
  createDir(dir)
  setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
  result.path = dir / ("uninstall-" & t.utc.format("yyyyMMdd'T'HHmmss'Z'") &
                       "-discarded-unshipped.json")
  writeFileAtomic(result.path, result.text, 0o600)
  writeFileAtomic(result.path & DiscardRecordSigExt, signature & "\n", 0o600)

proc verifyDiscardRecord*(path: string; expectedKeyHex = ""):
    tuple[ok: bool; why, keyHex: string; objects: seq[string]] =
  ## §13 decision 64: whether the record at ``path`` is signed, over
  ## exactly the bytes the file holds, by the key it names -- and, when
  ## ``expectedKeyHex`` is given (the host's enrolled attestation key, from
  ## the sink's hosts file), by that key. Reads ``<path>.sig``.
  let text = try: readFile(path)
             except IOError as e: return (false, "cannot read " & path & ": " & e.msg, "", @[])
  let sig = try: readFile(path & DiscardRecordSigExt).strip()
            except IOError as e:
              return (false, "cannot read the signature " & path &
                DiscardRecordSigExt & ": " & e.msg, "", @[])
  var doc: JsonNode
  try: doc = parseJson(text)
  except CatchableError as e: return (false, path & " is not a record: " & e.msg, "", @[])
  if doc{"schema"}.getStr() != DiscardRecordSchema:
    return (false, path & " is not a " & DiscardRecordSchema & " record", "", @[])
  result.keyHex = doc{"attestationKey"}.getStr()
  for o in doc{"objects"}.getElems(): result.objects.add(o.getStr())
  if result.keyHex.len == 0:
    result.why = "the record names no attestation key: it is unsigned"
    return
  if expectedKeyHex.len > 0 and
      expectedKeyHex.toLowerAscii() != result.keyHex.toLowerAscii():
    result.why = "the record names the key " & result.keyHex &
      ", not the expected " & expectedKeyHex
    return
  let v = verifyText(text, sig, result.keyHex)
  result.ok = v.ok
  result.why = v.why

proc storeEvidenceGate*(custody: CustodySite; opts: UninstallOptions;
                        ship: proc (): tuple[ok: bool; why: string];
                        overrideDir = UninstallOverrideDir):
    tuple[pending, errors: seq[string]; overrideRecord,
          overrideRecordText: string] =
  ## What uninstall may discard of the store evidence (§10.2 Uninstall,
  ## §13 decisions 56 and 62). ``errors`` non-empty: refuse, remove
  ## nothing.
  ##
  ## - Every pending object (entries, objects left aside) is named, and
  ##   without ``--discard-store-evidence`` the uninstall refuses.
  ## - Decision 56, record and ship first: before anything is discarded,
  ##   each object left aside and each entry filed but not recorded gets
  ##   its DET-AO-5 record, and the outbox is shipped. Until the sink has
  ##   acknowledged every record, ``--discard-store-evidence`` is refused.
  ## - Decision 62, the explicit recorded override:
  ##   ``--discard-unacknowledged-store-evidence`` discards anyway, after a
  ##   signed local record of everything discarded unshipped is written
  ##   (and returned, for the caller to print). Nothing is lost silently,
  ##   and the operator is never stuck.
  result.pending = pendingStoreEvidence(custody)
  if result.pending.len == 0: return
  let discarding = opts.discardStoreEvidence or
                   opts.discardUnacknowledgedStoreEvidence
  when not mutated("uninstall-discards-unrecorded"):
    discard recordUnreportedStoreEvidence(custody)
  let shipped = ship()
  if not discarding and not mutated("uninstall-discards-evidence-silently"):
    for e in result.pending:
      result.errors.add("store evidence " & e & " would be removed; copy it " &
        "out, then run uninstall with --discard-store-evidence")
    result.errors.add("nothing was removed")
    return
  if shipped.ok: return
  if opts.discardUnacknowledgedStoreEvidence:
    when mutated("override-unrecorded"):
      return
    # Decision 63: no key, no signed record, no discard.
    if not fileExists(custody.evidence.attestationKey) and
        not mutated("override-keyless-unsigned"):
      result.errors.add("the host's attestation key " &
        custody.evidence.attestationKey & " is missing, so the record of " &
        "the store evidence discarded unshipped cannot be signed; restore " &
        "the key (or ship the records) and run uninstall again")
      result.errors.add("nothing was removed")
      return
    try:
      let r = writeOverrideRecord(custody, overrideDir, result.pending,
                                  shipped.why)
      result.overrideRecord = r.path
      result.overrideRecordText = r.text
    except CatchableError as e:
      when not mutated("override-write-error-swallowed"):
        result.errors.add("the record of the store evidence discarded " &
          "unshipped could not be written (" & e.msg & ")")
        result.errors.add("nothing was removed")
    return
  when not mutated("uninstall-skips-ack-refusal"):
    result.errors.add("the Evidence sink has not acknowledged the " &
      "records of the store evidence uninstall would discard (" &
      shipped.why & "); run uninstall again once it has, or discard them " &
      "unshipped with --discard-unacknowledged-store-evidence, which " &
      "writes and prints a signed record of each")
    result.errors.add("nothing was removed")

proc runAddonUninstall*(opts: UninstallOptions): UninstallResult =
  let stateDir = if opts.stateDir.len > 0: opts.stateDir else: DefaultStateDir
  # The host-wide apply lock for the whole uninstall: it removes the store,
  # units and /etc objects an apply (a deploy-agent tick) would otherwise be
  # writing at the same moment (``repro_core/host_apply_lock``).
  var hostLock = acquireHostApplyLock("repro system addon uninstall")
  defer: hostLock.release()
  # The altered store objects kept as evidence go with /var/lib/repro. They
  # are named, and nothing is removed, until the operator says to discard
  # them (having copied them out).
  let custody = custodySite(stateDir)
  let gate = storeEvidenceGate(custody, opts,
    proc (): tuple[ok: bool; why: string] = shipEvidenceNow(stateDir))
  let evidenceKept = gate.pending
  result.overrideRecord = gate.overrideRecord
  result.overrideRecordText = gate.overrideRecordText
  if gate.errors.len > 0:
    result.errors.add(gate.errors)
    return
  let l = readLedger(ledgerCopyPath(stateDir))
  # Pre-bootstrap inputs the add-on took over go back exactly as found
  # (spec §6.1, §6.4). Their bytes are captured FIRST -- before any unit
  # is stopped, any file removed or any drift judged -- because the
  # agent's records are live: the sequence floor must come back byte for
  # byte, or a manifest this host already accepted would replay on its
  # kept key. A changed content-pinned input is drift like any other.
  let captured = capturePreBootstrapInputs(l)
  for d in captured.drift: result.drift.add(d)

  # The collision observer, to tell a path a package came to own since
  # (handed back, never removed). Unreadable: no hand-back is possible, so
  # nothing is removed on a guess -- every file is left as drift.
  var driver: CollisionDriver = nil
  try: driver = detectCollisionDriver()
  except CatchableError as ex:
    result.errors.add("the package database cannot be read (" & ex.msg &
      "); the add-on's files are left in place")
  var byClass: array[LedgerClass, seq[LedgerEntry]]
  for e in l.entries:
    byClass[e.class].add(e)
  # Later entries were created later: undo them first.
  for c in LedgerClass:
    byClass[c].reverse()

  # 1. Stop and disable every unit the add-on created. `disable --now`
  #    removes the [Install] links; stopping repro-store.mount unmounts the
  #    store's read-only bind. A replaced or adopted unit (its base state is
  #    in the ledger) is handed back instead: its file is restored or removed
  #    in step 2, and after the daemon reload of step 4 the base's enablement
  #    and activity are re-asserted (spec §4.2, C36).
  var handBack: seq[LedgerEntry]
  for u in byClass[lcUnit]:
    if u.collision in ["replace", "adopt", "reconcile", "closure-relocate"]:
      handBack.add(u)
    elif fileExists(u.path):
      # Stopped, then disabled by removing exactly its ledgered install
      # links in step 2 -- never `systemctl disable`, which would also
      # remove links the base made for units the add-on does not own.
      systemctlOrRecord(["stop", "--", u.unit], result)

  # 1b. The deploy agent's fetch unit keeps its staging in a dynamic user's
  #     StateDirectory= (/var/lib/private/repro-agent-fetch, linked from
  #     /var/lib/repro-agent-fetch), which the add-on made exist and no
  #     ledger entry names: systemd removes it while the unit is still
  #     loaded and stopped (A11 audit F5).
  for u in byClass[lcUnit]:
    if u.unit == AgentFetchUnit and fileExists(u.path):
      when not mutated("uninstall-keeps-fetch-state"):
        discard runSystemctl(["clean", "--what=state", "--", u.unit])
        for leftover in AgentFetchStatePaths:
          try:
            if symlinkExists(leftover): removeFile(leftover)
            elif dirExists(leftover): removeDir(leftover)
          except OSError as ex:
            result.errors.add(leftover & ": " & ex.msg)
        result.removed.add("the fetch unit's state directory")

  # 2. Units and drop-ins, and any install link `disable` did not remove.
  for li in byClass[lcInstallLink]:
    removeOwned(li, result)
  for u in byClass[lcUnit]:
    removeOwned(u, result, driver)
  for di in byClass[lcDropIn]:
    removeOwned(di, result, driver)

  # 3. Diversions: the profile's file at the path, then the diversion.
  var handled = initHashSet[string]()
  when not mutated("uninstall-skips-diversion-removal"):
    for dv in byClass[lcDiversion]:
      for f in byClass[lcEtcFile]:
        if f.path == dv.path:
          removeOwned(f, result, driver)
          handled.incl(f.path)
      if fileExists(dv.path) or symlinkExists(dv.path):
        result.drift.add(dv.path & ": the file on the diverted path is not " &
          "the one the ledger recorded (it drifted, or is not the add-on's); " &
          "the diversion is left in place until the path is free")
        continue
      # The same removal the apply's destroy runs.
      try:
        removeLocalDpkgDiversion(dv.path)
        result.removed.add("diversion " & dv.path)
        result.undone.incl(entryKey(dv))
      except CatchableError as ex:
        result.errors.add("dpkg-divert --remove " & dv.path & ": " & ex.msg)

  # 4. /etc files (those a diversion step did not already take), then the
  #    directories the add-on created, deepest first; the kernel values
  #    sysctl fragments set go back to what the ledger recorded before.
  for f in byClass[lcEtcFile]:
    if f.path in handled:
      continue
    removeOwned(f, result, driver)
  for sl in byClass[lcStaticLink]:
    if symlinkExists(sl.path):
      try:
        removeStaticLink()
        result.removed.add(sl.path)
        result.undone.incl(entryKey(sl))
      except CatchableError as ex:
        result.errors.add(sl.path & ": " & ex.msg)
    else:
      result.undone.incl(entryKey(sl))
  removeEmptyDirs(byClass[lcDir])
  systemctlOrRecord(["daemon-reload"], result)
  # A unit of the add-on's that ended failed stays listed, failed, after its
  # file is gone; the base never had that record. Best effort: a unit that
  # is not failed (or no longer loaded) has nothing to reset.
  for u in byClass[lcUnit]:
    if u.collision notin ["replace", "adopt", "reconcile", "closure-relocate"]:
      discard runSystemctl(["reset-failed", "--", u.unit])
  for u in handBack:
    if entryKey(u) notin result.undone:
      continue                   # left as drift above: not ours to touch
    try:
      restoreUnitState(u, detectCollisionDriver())
    except CatchableError as ex:
      result.errors.add(u.unit & ": " & ex.msg)
  for sc in byClass[lcSysctl]:
    if readLiveSysctl(sc.path) != sc.value:
      result.undone.incl(entryKey(sc))   # not ours any more: left as is
      continue
    try:
      restoreSysctlValue(sc.path, sc.replaced)
      result.removed.add("sysctl " & sc.path & " = " & sc.replaced)
      result.undone.incl(entryKey(sc))
    except CatchableError as ex:
      result.errors.add("sysctl " & sc.path & ": " & ex.msg)
  # The add-on's nftables table: its unit's stop (step 1) deleted it; one
  # still there is deleted now -- that table alone (``nft_tables``).
  for t in byClass[lcNftTable]:
    let why = deleteEgressTable()
    if why.len > 0:
      result.errors.add("nftables table " & t.path & ": " & why)
    else:
      result.removed.add("nftables table " & t.path)
      result.undone.incl(entryKey(t))
  for a in byClass[lcAccount]:
    result.keptAccounts.add(a.path)
    result.undone.incl(entryKey(a))
  for u in byClass[lcUnitState]:
    result.undone.incl(entryKey(u))

  # 5. State, keys, /etc/repro and the store. A mount still on the store
  #    (a stop that failed above) must not be deleted through. And an
  #    uninstall that left anything behind -- drift it would not remove, a
  #    step that failed -- keeps the state directory and with it the ledger
  #    copy, so the leftover stays identified and a second uninstall (after
  #    the operator restored or accepted the object) can finish the job.
  #    Only a complete reversal removes the state.
  when not mutated("uninstall-discards-state-on-drift"):
    if result.drift.len > 0 or result.errors.len > 0:
      # The ledger must describe what the add-on still owns NOW: the
      # objects this run did remove are taken out of it, so the next
      # uninstall acts only on what is left and never reports an object
      # it already undid (a diversion already removed, a file already
      # deleted) as drift.
      writeLedger(ledgerCopyPath(stateDir), remainingLedger(l, result))
      result.errors.add("the add-on's state and ledger at " & stateDir &
        " are kept: the uninstall is incomplete (see the drift and errors " &
        "above); fix or accept them and run uninstall again")
      return
  for k in byClass[lcKey]:
    if not k.isPreBootstrapInput:
      removeOwned(k, result)
  if dirExists(StoreRoot) and isMountPoint(StoreRoot):
    result.errors.add(StoreRoot & " is still mounted; the store is kept")
  elif not opts.keepStore:
    try:
      removeReproRoot()
      result.removed.add(ReproRoot)
    except OSError as ex:
      result.errors.add(ReproRoot & ": " & ex.msg)
  # The secrets ramfs (A7) is unmounted, its plaintext gone, before the
  # roots are removed.
  try:
    releaseRunDir(defaultSecretsLayout())
  except CatchableError as ex:
    result.errors.add(defaultSecretsLayout().runDir & ": " & ex.msg)
  # The store evidence directory (§13 decision 47) goes with the state
  # (`/var/lib/repro`), whatever --keep-store says (that keeps `/repro`).
  # Its entries were named, and the uninstall refused, before anything was
  # removed unless the operator passed --discard-store-evidence (above).
  for e in evidenceEntries(custodySite(stateDir)):
    result.removed.add(e & " (store evidence)")
  # Objects a crashed recovery left aside in the store were named above
  # (the refusal); they went with the store, or stay with it.
  for e in evidenceKept:
    if e.startsWith(asideRoot(custodySite(stateDir))):
      if dirExists(e):
        result.keptEvidence.add(e)
      else:
        result.removed.add(e & " (store evidence left aside)")
  for root in ["/etc/repro", "/var/lib/repro", "/run/repro"]:
    if dirExists(root):
      try:
        removeDir(root)
        result.removed.add(root)
      except OSError as ex:
        result.errors.add(root & ": " & ex.msg)
  restorePreBootstrapInputs(captured, opts.keepStore, result)
