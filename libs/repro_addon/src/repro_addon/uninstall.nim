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

import std/[algorithm, os, posix, sets, strutils]

import repro_elevation/posix_system_driver

import ./addon_apply
import ./collision
import ./etc_write
import ./generation0
import ./host_exec
import ./ledger
import ./mutations
import ./static_tree
import ./store_root
import ./switch


type
  UninstallOptions* = object
    stateDir*: string
    keepStore*: bool

  UninstallResult* = object
    removed*: seq[string]
    drift*: seq[string]          ## objects left in place, with the reason
    keptAccounts*: seq[string]
    undone*: HashSet[string]
      ## ``<class> <path>`` of every ledger entry this run undid; what the
      ## kept ledger of an incomplete run drops.
      ## Accounts the add-on created and leaves in place (spec: sysusers
      ## accounts are never deleted): the ``account`` ledger entries.
    errors*: seq[string]

proc ok*(r: UninstallResult): bool = r.drift.len == 0 and r.errors.len == 0

proc entryKey(e: LedgerEntry): string = $e.class & " " & e.path

proc removeOwned(e: LedgerEntry; r: var UninstallResult) =
  ## Undo one file or link the ledger owns, if it is unchanged: put back
  ## the bytes the ledger preserved for an adopted, replaced or reconciled
  ## object (spec §6.4 step 2), else remove it. An entry whose object is
  ## undone here, or was already gone, is recorded in ``r.undone`` so the
  ## kept ledger of an incomplete run no longer lists it.
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

proc runAddonUninstall*(opts: UninstallOptions): UninstallResult =
  let stateDir = if opts.stateDir.len > 0: opts.stateDir else: DefaultStateDir
  let l = readLedger(ledgerCopyPath(stateDir))
  # Pre-bootstrap inputs the add-on took over go back exactly as found
  # (spec §6.1, §6.4). Their bytes are captured FIRST -- before any unit
  # is stopped, any file removed or any drift judged -- because the
  # agent's records are live: the sequence floor must come back byte for
  # byte, or a manifest this host already accepted would replay on its
  # kept key. A changed content-pinned input is drift like any other.
  let captured = capturePreBootstrapInputs(l)
  for d in captured.drift: result.drift.add(d)

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
    if u.collision in ["replace", "adopt", "reconcile"]:
      handBack.add(u)
    elif fileExists(u.path):
      # Stopped, then disabled by removing exactly its ledgered install
      # links in step 2 -- never `systemctl disable`, which would also
      # remove links the base made for units the add-on does not own.
      systemctlOrRecord(["stop", "--", u.unit], result)

  # 2. Units and drop-ins, and any install link `disable` did not remove.
  for li in byClass[lcInstallLink]:
    removeOwned(li, result)
  for u in byClass[lcUnit]:
    removeOwned(u, result)
  for di in byClass[lcDropIn]:
    removeOwned(di, result)

  # 3. Diversions: the profile's file at the path, then the diversion.
  var handled = initHashSet[string]()
  when not mutated("uninstall-skips-diversion-removal"):
    for dv in byClass[lcDiversion]:
      for f in byClass[lcEtcFile]:
        if f.path == dv.path:
          removeOwned(f, result)
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
    removeOwned(f, result)
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
  for root in ["/etc/repro", "/var/lib/repro", "/run/repro"]:
    if dirExists(root):
      try:
        removeDir(root)
        result.removed.add(root)
      except OSError as ex:
        result.errors.add(root & ": " & ex.msg)
  restorePreBootstrapInputs(captured, opts.keepStore, result)
