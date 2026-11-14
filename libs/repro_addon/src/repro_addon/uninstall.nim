## ``repro system addon uninstall [--keep-store]``.
##
## Reverses everything the ledger records, in the order the add-on's
## specification fixes:
##
## 1. stop the add-on's units (for ``repro-store.mount`` that unmounts the
##    store); their install links are the ledger's, removed in step 2;
## 2. remove the units and drop-ins (and any install link ``disable``
##    left), restoring an adopted or replaced unit from the bytes the
##    ledger preserved, and every revert hold the ledger records
##    (``lcRevertHold``, §13 decision 133);
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

import std/[algorithm, json, os, posix, sequtils, sets, strutils, times]

import repro_core/host_apply_lock

import repro_elevation/posix_system_driver

import ./addon_apply
import ./collision
import ./attestation
import ./etc_write
import ./evidence
import ./evidence_ship
import ./fingerprint
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
    completionRecord*: string
      ## §13 decision 81: the signed completion record, once the removal
      ## succeeded.
    keptEvidence*: seq[string]
      ## Store evidence left with a kept store (``--keep-store``): objects a
      ## crashed recovery left aside, named, not removed. Only ever set
      ## under ``--keep-store`` (round 10; ``classifyLeftAside``).
    keepStore*: bool
      ## ``--keep-store`` was given. ``finishDiscard`` counts an object as
      ## kept with the store only then, whatever ``keptEvidence`` says
      ## (round 10).
    leftAside*: seq[string]
      ## Store evidence still on disk after a removal that should have
      ## taken it (no ``--keep-store``): a failed or refused removal of
      ## ``/repro``. Neither discarded nor kept (round 10).
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
  ##
  ## No sink configuration: a host without a sink writes no outbox entries
  ## (``EvidenceSite.confPath``), so an empty outbox means there is nothing
  ## to wait for. A non-empty one means the configuration was there when
  ## the records were queued and is gone now -- an earlier uninstall that
  ## did not finish removed it with the ``/etc`` objects -- and the records
  ## were never acknowledged (A11 code review round 11; §13 decision 62:
  ## nothing is discarded unshipped without its signed record).
  if not fileExists(site.confPath):
    let queued = outboxEntries(site.outbox).len
    when mutated("ship-ok-without-sink-configuration"):
      return (true, "")                   # FALSIFIER: queued records ignored
    if queued == 0: return (true, "")
    return (false, $queued & " record(s) still queued, and the sink " &
      "configuration " & site.confPath & " is gone (an earlier uninstall " &
      "that did not finish removed it), so they cannot be shipped")
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
  DiscardRecordSchema* = "repro-addon-store-evidence-discard-intent/3"
    ## §13 decision 81: the INTENT record, signed and made durable before
    ## anything is removed. It says the operator authorised discarding these
    ## objects unshipped; it does not say they were discarded. /2 (one
    ## record, read as "discarded") and /1 are no longer written.
  DiscardCompletionSchema* = "repro-addon-store-evidence-discard-completed/1"
    ## §13 decision 81: the COMPLETION record, signed and made durable only
    ## after the removal succeeded; it names the intent record by name and
    ## sha256.
  DiscardRecordSigExt* = ".sig"
  IntentRecordNote = "intent: the operator authorised discarding these " &
    "objects unshipped; this record alone does not say they were discarded"
  CompletionRecordNote = "completed: the objects of the intent record " &
    "were discarded unshipped"
  DiscardIntentSuffix* = "-discard-intent.json"
  DiscardCompletionSuffix* = "-discard-completed.json"

type
  DiscardStatus* = enum
    ## What ``verifyDiscardRecord`` found (decision 81).
    dsInvalid       ## not a valid, enrolled-key-signed intent record
    dsAuthorised    ## a valid intent record, and no valid completion
    dsCompleted     ## a valid intent record and a valid completion of
                    ## it: every object removed
    dsCompletedKept ## completed, but some objects were kept with the
                    ## store (``--keep-store``): those were not discarded

proc completionPathOf*(intentPath: string): string =
  ## ``uninstall-<stamp>-discard-intent.json`` ->
  ## ``uninstall-<stamp>-discard-completed.json``.
  if intentPath.endsWith(DiscardIntentSuffix):
    intentPath[0 ..< intentPath.len - DiscardIntentSuffix.len] & DiscardCompletionSuffix
  else:
    intentPath & ".completed"

type
  DiscardRecordWriter* = proc (path, text: string) {.closure.}
    ## Writes one file of the discard record durably and exclusively. The
    ## default is ``exclusiveRecordWriter``; a test passes one that fails
    ## at a chosen step.
  DiscardSyncer* = proc (removed: seq[string]) {.closure.}
    ## Makes the removal of ``removed`` durable before the completion
    ## record is written (§13 decision 112). The default is
    ## ``syncRemovedObjects``; a test passes one that records the call or
    ## fails.
  RecordExistsError* = object of OSError
    ## A discard record's name is taken: it is never written over.

var
  ODirectory {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
  ONoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint

proc syncDirFd(dir: string) =
  let fd = posix.open(dir.cstring, O_RDONLY or ODirectory or O_CLOEXEC)
  if fd < 0:
    raise newException(OSError, "cannot open " & dir & " to sync it: " &
      $strerror(errno))
  defer: discard posix.close(fd)
  if fsync(fd) != 0:
    raise newException(OSError, "fsync of " & dir & " failed: " & $strerror(errno))

proc writeFileExclusiveDurable*(path, text: string; mode = 0o600) =
  ## Writes ``path`` only if no file of that name exists (round 9): the
  ## bytes go to a temporary file in the same directory, which is fsynced
  ## and then linked to ``path`` -- ``link(2)`` refuses an existing name,
  ## where a rename would replace it -- and the directory is fsynced.
  ## Raises ``RecordExistsError`` when the name is taken.
  let dir = parentDir(path)
  let tmp = dir / ("." & extractFilename(path) & ".tmp-" &
                   $getCurrentProcessId() & "-" & $epochTime().int64)
  let fd = posix.open(tmp.cstring, O_WRONLY or O_CREAT or O_EXCL or
                      ONoFollow or O_CLOEXEC, Mode(mode))
  if fd < 0:
    raise newException(OSError, "cannot create " & tmp & ": " & $strerror(errno))
  var ok = false
  try:
    var off = 0
    while off < text.len:
      let n = posix.write(fd, unsafeAddr text[off], text.len - off)
      if n <= 0:
        raise newException(OSError, "writing " & tmp & " failed: " & $strerror(errno))
      off += n
    if fsync(fd) != 0:
      raise newException(OSError, "fsync of " & tmp & " failed: " & $strerror(errno))
    ok = true
  finally:
    discard posix.close(fd)
    if not ok: discard posix.unlink(tmp.cstring)
  when mutated("intent-overwrites-existing"):
    # FALSIFIER: replace an existing record, as a rename does.
    try: moveFile(tmp, path)
    except OSError:
      discard posix.unlink(tmp.cstring)
      raise
  else:
    if link(tmp.cstring, path.cstring) != 0:
      let e = errno
      discard posix.unlink(tmp.cstring)
      if e == EEXIST:
        raise newException(RecordExistsError, path & " exists; a discard " &
          "record is never written over")
      raise newException(OSError, "link to " & path & " failed: " & $strerror(e))
    discard posix.unlink(tmp.cstring)
  syncDirFd(dir)

proc exclusiveRecordWriter*(path, text: string) =
  writeFileExclusiveDurable(path, text, 0o600)

proc atomicRecordWriter*(path, text: string) =
  ## The default writer (kept under its round-8 name for the tests'
  ## wrappers): exclusive and durable.
  exclusiveRecordWriter(path, text)

proc syncfs(fd: cint): cint {.importc, header: "<unistd.h>".}

proc nearestExisting(p: string): string =
  result = parentDir(p)
  while result.len > 1 and not dirExists(result):
    result = parentDir(result)
  if result.len == 0: result = "/"

proc syncRemovedObjects*(removed: seq[string]) =
  ## §13 decision 112: before the completion record is written, the removal
  ## it reports is made durable. For each removed object, the nearest
  ## directory that still exists above it is fsynced (the unlinks are
  ## entries of it, or of a directory removed from it), and the filesystem
  ## that holds it is synced with ``syncfs(2)`` (on btrfs an fsync of the
  ## log directory does not commit unlinks in another subvolume). Raises on
  ## any failure: then no completion is written.
  var done: seq[string]
  for o in removed:
    let d = nearestExisting(o)
    if d in done: continue
    done.add(d)
    syncDirFd(d)
    let fd = posix.open(d.cstring, O_RDONLY or ODirectory or O_CLOEXEC)
    if fd < 0:
      raise newException(OSError, "cannot open " & d & ": " & $strerror(errno))
    let rc = syncfs(fd)
    let e = errno
    discard posix.close(fd)
    if rc != 0:
      raise newException(OSError, "syncfs of the filesystem holding " & d &
        " failed: " & $strerror(e))

proc writeOverrideRecord(custody: CustodySite; dir: string;
                         objects: seq[string]; why: string;
                         writer: DiscardRecordWriter):
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
             "record": IntentRecordNote,
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
  # A unique name (round 9): the second-resolution stamp, and a sequence
  # number when a record, its signature or its completion already holds
  # it. The writer still refuses a name taken in between.
  let stamp = "uninstall-" & t.utc.format("yyyyMMdd'T'HHmmss'Z'")
  var n = 0
  while true:
    result.path = dir / (stamp & (if n == 0: "" else: "-" & $n) & DiscardIntentSuffix)
    when mutated("intent-overwrites-existing"):
      break
    if not (symlinkExists(result.path) or fileExists(result.path) or
            dirExists(result.path) or
            symlinkExists(result.path & DiscardRecordSigExt) or
            fileExists(result.path & DiscardRecordSigExt) or
            dirExists(result.path & DiscardRecordSigExt) or
            fileExists(completionPathOf(result.path))):
      break
    inc n
  # The signature goes first and the record last, so a record exists only
  # with its signature beside it. Each write is durable and exclusive (the
  # bytes fsynced in a temporary file, linked to the name with link(2),
  # which refuses an existing name, and the directory fsynced:
  # writeFileExclusiveDurable). A failed
  # write stops the uninstall before anything is removed. An intent record
  # that reached its name before its directory sync failed stays with its
  # signature: it states an authorisation, which is true, and never a
  # discard (decision 81); only a record that never reached its name has
  # its signature removed.
  try:
    writer(result.path & DiscardRecordSigExt, signature & "\n")
  except CatchableError:
    when not mutated("override-sig-write-error-swallowed"):
      raise
  try:
    writer(result.path, result.text)
  except RecordExistsError:
    # Taken between the choice of name and the write: never written over.
    try: removeFile(result.path & DiscardRecordSigExt) except OSError: discard
    raise
  except CatchableError as e:
    let inPlace = fileExists(result.path) and
      (try: readFile(result.path) == result.text except IOError: false)
    if inPlace and not mutated("override-rollback-removes-sig"):
      raise newException(OSError, "the intent record " & result.path &
        " and its signature are in place, but making them durable failed (" &
        e.msg & "); both are kept and state an authorisation only")
    try: removeFile(result.path & DiscardRecordSigExt) except OSError: discard
    raise newException(OSError, "the intent record " & result.path &
      " could not be written (" & e.msg & ")")

proc writeDiscardCompletion*(custody: CustodySite; signer: TextSigner;
                             intentPath, intentText: string;
                             removed, kept: seq[string];
                             writer: DiscardRecordWriter = atomicRecordWriter):
    tuple[path, text: string] =
  ## §13 decision 81: the signed completion record, written only after the
  ## removal succeeded. It names the intent record and its sha256, the
  ## objects removed and any kept with the store (``--keep-store``). It is
  ## signed with the key read before the removal (``signer``); the caller
  ## writes it before the key file is removed, and keeps the key when this
  ## fails. The signature goes first, the record last; both durable.
  var s = signer
  when mutated("discard-completion-key-read-late"):
    s = loadTextSigner(custody.evidence.attestationKey)
  var j = %*{"schema": DiscardCompletionSchema,
             "record": CompletionRecordNote,
             "time": getTime().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
             "host": custody.evidence.host,
             "intent": extractFilename(intentPath),
             "intentSha256": sha256Hex(intentText),
             "removed": removed, "keptWithTheStore": kept,
             "attestationKey": s.publicKeyHex}
  result.text = pretty(j) & "\n"
  result.path = completionPathOf(intentPath)
  writer(result.path & DiscardRecordSigExt, signWith(s, result.text) & "\n")
  writer(result.path, result.text)

proc readSignedRecord(path, schema, expectedKeyHex: string):
    tuple[ok: bool; why, text: string; doc: JsonNode] =
  ## A record at ``path`` of ``schema``, signed over exactly its bytes by
  ## ``expectedKeyHex`` (``<path>.sig``).
  let text = try: readFile(path)
             except IOError as e: return (false, "cannot read " & path & ": " & e.msg, "", nil)
  let sig = try: readFile(path & DiscardRecordSigExt).strip()
            except IOError as e:
              return (false, "cannot read the signature " & path &
                DiscardRecordSigExt & ": " & e.msg, "", nil)
  var doc: JsonNode
  try: doc = parseJson(text)
  except CatchableError as e: return (false, path & " is not a record: " & e.msg, "", nil)
  if doc{"schema"}.getStr() != schema:
    return (false, path & " is not a " & schema & " record", "", nil)
  let keyHex = doc{"attestationKey"}.getStr()
  if keyHex.len == 0:
    return (false, path & " names no attestation key: it is unsigned", "", nil)
  if expectedKeyHex.toLowerAscii() != keyHex.toLowerAscii():
    return (false, path & " names the key " & keyHex & ", not the expected " &
      expectedKeyHex, "", nil)
  let v = verifyText(text, sig, keyHex)
  if not v.ok: return (false, path & ": " & v.why, "", nil)
  (true, "", text, doc)

proc verifyDiscardRecord*(path: string; expectedKeyHex: string):
    tuple[status: DiscardStatus; why, keyHex: string;
          objects, removed, kept: seq[string]] =
  ## §13 decisions 64, 73 and 81. ``path`` names the intent record (or its
  ## completion, which leads to the intent). Both must be signed, over
  ## exactly their bytes, by ``expectedKeyHex`` -- the host's enrolled
  ## attestation key, which the caller must give.
  ##
  ## - ``dsCompleted``: the intent record verifies, and a completion record
  ##   verifies and names that intent by its sha256. ``removed`` and
  ##   ``kept`` are the completion's own lists: the objects discarded and
  ##   those kept with the store (``--keep-store``). Together they must
  ##   cover exactly the intent's ``objects``, each in one list only;
  ##   a completion that does not is ``dsInvalid``. ``objects`` is the
  ##   intent's list, the authorisation, and never the verdict;
  ## - ``dsAuthorised``: the intent verifies and there is no valid
  ##   completion (the uninstall failed, drifted or crashed after the
  ##   intent): the discard was authorised and is NOT claimed;
  ## - ``dsInvalid``: anything else.
  when not mutated("verify-accepts-missing-key"):
    if expectedKeyHex.len == 0:
      return (dsInvalid, "no expected key: give the host's enrolled " &
        "attestation key with --key", "", @[], @[], @[])
  var intentPath = path
  if path.endsWith(DiscardCompletionSuffix):
    intentPath = path[0 ..< path.len - DiscardCompletionSuffix.len] & DiscardIntentSuffix
  var key = expectedKeyHex
  if key.len == 0:      # only under verify-accepts-missing-key
    try: key = parseJson(readFile(intentPath)){"attestationKey"}.getStr()
    except CatchableError: discard
  let intent = readSignedRecord(intentPath, DiscardRecordSchema, key)
  if not intent.ok:
    return (dsInvalid, intent.why, "", @[], @[], @[])
  result.keyHex = intent.doc{"attestationKey"}.getStr()
  for o in intent.doc{"objects"}.getElems(): result.objects.add(o.getStr())
  when mutated("discard-verify-ignores-completion"):
    return (dsCompleted, "", result.keyHex, result.objects, result.objects, @[])
  let cpath = completionPathOf(intentPath)
  if not fileExists(cpath):
    when mutated("discard-verify-completion-sig-alone"):
      if fileExists(cpath & DiscardRecordSigExt):
        return (dsCompleted, "", result.keyHex, result.objects, result.objects, @[])
    result.status = dsAuthorised
    result.why = "no completion record (" & extractFilename(cpath) & "): " &
      "the discard was authorised and is not known to have completed"
    return
  when mutated("discard-verify-skips-completion-signature"):
    # The completion is what turns "authorised" into "completed": parsing it
    # without checking its signature lets anyone who can write the log
    # directory claim a discard.
    let done = try: (ok: true, why: "", text: readFile(cpath),
                     doc: parseJson(readFile(cpath)))
               except CatchableError as e:
                 (false, cpath & " is not a record: " & e.msg, "", JsonNode(nil))
  else:
    let done = readSignedRecord(cpath, DiscardCompletionSchema, key)
  if not done.ok:
    result.status = dsInvalid
    result.why = "the completion record does not verify: " & done.why
    return
  if done.doc{"intentSha256"}.getStr() != sha256Hex(intent.text) and
      not mutated("discard-verify-skips-intent-digest"):
    result.status = dsInvalid
    result.why = cpath & " completes another intent record (its intentSha256 " &
      "is not this intent's)"
    return
  # Round 9: what was removed and what was kept with the store
  # (``--keep-store``) come from the completion (decision 81: "the objects
  # removed and those kept"). Together they must be exactly the intent's
  # objects, none in both lists, or it is not a completion of this intent;
  # only the removed ones are reported as discarded.
  for o in done.doc{"removed"}.getElems(): result.removed.add(o.getStr())
  for o in done.doc{"keptWithTheStore"}.getElems(): result.kept.add(o.getStr())
  when not mutated("discard-verify-reports-intent-objects"):
    var covered = result.removed & result.kept
    covered.sort()
    var want = result.objects
    want.sort()
    if covered != want or result.removed.anyIt(it in result.kept):
      result.status = dsInvalid
      result.why = cpath & " does not account for exactly the objects of " &
        "its intent record (removed + kept differ from the intent's objects)"
      return
  else:
    # FALSIFIER: the intent's objects reported as discarded.
    result.removed = result.objects
    result.kept = @[]
  result.status = if result.kept.len == 0: dsCompleted else: dsCompletedKept

proc unfinishedDiscardIntent*(custody: CustodySite;
                              dir = UninstallOverrideDir):
    tuple[path, text: string; objects: seq[string]] =
  ## §13 decisions 62, 81 and 113: the newest intent record in ``dir``
  ## that the host's own attestation key signed and that has no completion
  ## record, or an empty path. An earlier uninstall wrote it and did not
  ## finish (its completion could not be written, or its removal could not
  ## be made durable) and kept the state and the key so that a later run
  ## could. A record signed by another key, or one that does not verify, is
  ## not the host's authorisation and is left alone.
  let keyPath = custody.evidence.attestationKey
  if not dirExists(dir) or not fileExists(keyPath): return
  var hostKey = ""
  try: hostKey = attestationPublicKeyHex(keyPath)
  except CatchableError: return
  var names: seq[string]
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(DiscardIntentSuffix):
      names.add(path)
  names.sort(order = SortOrder.Descending)
  for path in names:
    if fileExists(completionPathOf(path)): continue
    let rec = readSignedRecord(path, DiscardRecordSchema, hostKey)
    if not rec.ok: continue
    result.path = path
    result.text = rec.text
    for o in rec.doc{"objects"}.getElems(): result.objects.add(o.getStr())
    return

proc storeEvidenceGate*(custody: CustodySite; opts: UninstallOptions;
                        ship: proc (): tuple[ok: bool; why: string];
                        overrideDir = UninstallOverrideDir;
                        recordWriter: DiscardRecordWriter = atomicRecordWriter):
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
  if result.pending.len == 0:
    # Nothing is left to discard, but an earlier run may have removed the
    # evidence and failed to write its completion, keeping the state and
    # the key for this run (decision 113; decision 62: never stuck). This
    # run then signs that intent's completion; it writes no new intent.
    let unfinished = unfinishedDiscardIntent(custody, overrideDir)
    if unfinished.path.len > 0:
      # A partial completion (its signature alone, from a crash) would make
      # the exclusive writer refuse the name, so it goes first.
      let stale = completionPathOf(unfinished.path) & DiscardRecordSigExt
      if fileExists(stale): discard tryRemoveFile(stale)
      result.pending = unfinished.objects
      result.overrideRecord = unfinished.path
      result.overrideRecordText = unfinished.text
    return
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
                                  shipped.why, recordWriter)
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

proc classifyLeftAside*(r: var UninstallResult; pending: seq[string];
                        asideDir: string; keepStore: bool) =
  ## Sorts the store evidence left aside in ``/repro`` after the removal
  ## step. An aside that is gone was removed. One still on disk is "kept
  ## with the store" only when the operator asked for that (``--keep-store``,
  ## §13 decision 81). When the removal failed instead (``/repro: ...``
  ## raised, or the store was still mounted), it is neither gone nor kept:
  ## it stays out of both lists, so ``finishDiscard`` sees an object still in
  ## place and writes no completion; the intent stands as "authorised, not
  ## completed" and the removal error is reported (decision 113).
  for e in pending:
    if not e.startsWith(asideDir): continue
    if dirExists(e):
      when mutated("discard-failed-removal-counted-as-kept"):
        r.keptEvidence.add(e)               # FALSIFIER: dirExists alone
      else:
        if keepStore: r.keptEvidence.add(e)
        else:
          # Round 10: named, not silently left out of both lists.
          r.leftAside.add(e)
          r.errors.add(e & ": store evidence left aside is still there " &
            "after the store's removal; it was neither discarded nor kept " &
            "(no --keep-store)")
    else:
      r.removed.add(e & " (store evidence left aside)")

proc finishDiscard*(r: var UninstallResult; custody: CustodySite;
                   signer: TextSigner; pending: seq[string];
                   writer: DiscardRecordWriter = atomicRecordWriter;
                   syncer: DiscardSyncer = syncRemovedObjects) =
  ## §13 decisions 81, 112 and 113: after an uninstall that wrote an intent
  ## record, the completion record is written once every pending object is
  ## gone or kept with the store (``--keep-store``), and the removal is
  ## made durable (``syncer``). A failure elsewhere in the uninstall (a
  ## unit, ``/run/repro``) is reported on its own and does not hold the
  ## completion back (decision 113). An object still in place, or a failed
  ## sync, leaves the intent alone: ``verify-discard-record`` reports
  ## "authorised, not completed".
  if r.overrideRecord.len == 0: return
  when mutated("discard-completion-held-by-cleanup-error"):
    if r.drift.len > 0 or r.errors.len > 0: return   # FALSIFIER: round 8
  var removed, kept: seq[string]
  for o in pending:
    # Kept with the store only under --keep-store (round 10): a kept list
    # without it does not excuse an object still on disk.
    if o in r.keptEvidence and (r.keepStore or mutated("finish-trusts-kept-list")):
      kept.add(o)
    elif fileExists(o) or dirExists(o) or symlinkExists(o):
      when not mutated("discard-completed-objects-present"):
        return
    else: removed.add(o)
  when not mutated("discard-completion-skips-sync"):
    try:
      syncer(removed)
    except CatchableError as e:
      r.errors.add("the store evidence was removed, but making its " &
        "removal durable failed (" & e.msg & "); no completion record is " &
        "written, and the intent record " & r.overrideRecord &
        " stands as authorised, not completed")
      return
  try:
    let c = writeDiscardCompletion(custody, signer, r.overrideRecord,
                                   r.overrideRecordText, removed, kept, writer)
    r.completionRecord = c.path
  except CatchableError as e:
    let cpath = completionPathOf(r.overrideRecord)
    if fileExists(cpath):
      # It reached its name, so it is true and stays; only its durability
      # is unconfirmed (a crash now may still lose it, which leaves the
      # intent as "authorised, not completed": never an overclaim).
      r.completionRecord = cpath
      when not mutated("discard-completion-sync-error-swallowed"):
        r.errors.add("the store evidence was discarded and its completion " &
          "record " & cpath & " written, but making it durable failed (" &
          e.msg & ")")
    else:
      try: removeFile(cpath & DiscardRecordSigExt) except OSError: discard
      r.errors.add("the store evidence was discarded, but its completion " &
        "record could not be written (" & e.msg & "); the intent record " &
        r.overrideRecord & " stands as authorised, not completed")

type StoreRemover* = proc () {.closure.}

proc removeStore*(r: var UninstallResult; keepStore: bool;
                  remover: StoreRemover = removeReproRoot;
                  mounted: bool = dirExists(StoreRoot) and
                                  isMountPoint(StoreRoot)): bool =
  ## Removes ``/repro`` unless ``--keep-store``. True when the removal was
  ## attempted or required and did not happen (still mounted, or ``remover``
  ## raised): the uninstall is then incomplete and must keep the state.
  if mounted:
    r.errors.add(StoreRoot & " is still mounted; the store is kept")
    return true
  if keepStore: return false
  try:
    remover()
    r.removed.add(ReproRoot)
  except OSError as ex:
    r.errors.add(ReproRoot & ": " & ex.msg)
    return true

proc keepStateWhenIncomplete*(r: var UninstallResult; l: Ledger;
                              stateDir: string): bool =
  ## §10.2 step 5: an uninstall that left drift or failed a step keeps the
  ## state directory (ledger copy, attestation key, evidence configuration)
  ## so a second uninstall can finish. Writes the ledger of what the add-on
  ## still owns NOW (objects this run undid are dropped, so the next run
  ## never reports one as drift) and returns true; false when complete.
  if r.drift.len == 0 and r.errors.len == 0: return false
  writeLedger(ledgerCopyPath(stateDir), remainingLedger(l, r))
  r.errors.add("the add-on's state and ledger at " & stateDir &
    " are kept: the uninstall is incomplete (see the drift and errors " &
    "above); fix or accept them and run uninstall again")
  true

proc keepStateAfterStore*(r: var UninstallResult; l: Ledger;
                          stateDir: string; storeFailed: bool): bool =
  ## After the store's removal (and ``classifyLeftAside``): a failed removal,
  ## or a store-evidence aside still in place, keeps the state like drift
  ## does. True when the uninstall must stop here.
  when not mutated("uninstall-discards-state-after-failed-store-removal"):
    if storeFailed or r.leftAside.len > 0:
      discard keepStateWhenIncomplete(r, l, stateDir)
      return true
  false

proc removeDirTree(d: string) = removeDir(d)

proc removeHostRoot*(r: var UninstallResult; root: string;
                     evidence: seq[string] = @[];
                     remover: proc (d: string) = removeDirTree) =
  ## Removes one of the host roots. ``evidence`` (store evidence held under
  ## it) is listed as removed only once the root is gone: a removal that
  ## failed part-way must not report entries still on disk.
  if not dirExists(root): return
  try:
    remover(root)
    r.removed.add(root)
    for e in evidence: r.removed.add(e & " (store evidence)")
  except OSError as ex:
    r.errors.add(root & ": " & ex.msg)

proc removeStateEvidence*(r: var UninstallResult; entries: seq[string];
                          remover: proc (d: string) = removeDirTree): bool =
  ## Removes each store-evidence entry under the state (A11 code review
  ## round 11), before the keys and the state, and reports it removed only
  ## once it is gone. True when any entry is still there: the uninstall is
  ## then incomplete and must keep the state, with the attestation key that
  ## signs the discard's completion (§13 decision 81, §6.4 step 5).
  for e in entries:
    try:
      remover(e)
    except OSError as ex:
      when not mutated("evidence-reported-removed-unchecked"):
        r.errors.add(e & ": " & ex.msg)
        result = true
        continue
    when mutated("evidence-reported-removed-unchecked"):
      r.removed.add(e & " (store evidence)")   # FALSIFIER: unchecked
    else:
      if dirExists(e) or fileExists(e) or symlinkExists(e):
        r.errors.add(e & ": store evidence still on disk after its removal")
        result = true
      else:
        r.removed.add(e & " (store evidence)")

proc completeDiscardBeforeKeys*(r: var UninstallResult; l: Ledger;
                                stateDir: string; custody: CustodySite;
                                signer: TextSigner; pending: seq[string];
                                writer: DiscardRecordWriter = atomicRecordWriter;
                                syncer: DiscardSyncer = syncRemovedObjects): bool =
  ## §13 decisions 81 and 113: the completion record is written where
  ## decision 113 places it, as soon as the store evidence is gone and
  ## synced, and BEFORE the attestation key and the state are removed. A
  ## completion that cannot be written (or a removal that cannot be made
  ## durable) is then not lost for good: the state, the ledger copy and the
  ## key are kept, as for a failed evidence removal, and a second uninstall
  ## finds the intent and signs the completion itself (decision 62: the
  ## operator is never stuck). True when the uninstall must stop here and
  ## keep the state; false when there is no discard, or its completion is
  ## written (a failure to make that record durable only is reported: the
  ## record is in place and stays).
  if r.overrideRecord.len == 0: return false
  finishDiscard(r, custody, signer, pending, writer, syncer)
  # FALSIFIER: go on to the keys regardless of the completion.
  if r.completionRecord.len > 0 or
     mutated("discard-completion-failure-discards-key"): return false
  if r.errors.len == 0:
    # finishDiscard returns quietly for an object still in place; the
    # kept state must still be explained.
    r.errors.add("the discard's completion record was not written; the " &
      "intent record " & r.overrideRecord & " stands as authorised, not " &
      "completed")
  discard keepStateWhenIncomplete(r, l, stateDir)
  true

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
  let evidenceAtStart = evidenceKept.filterIt(
    fileExists(it) or dirExists(it) or symlinkExists(it))
  result.overrideRecord = gate.overrideRecord
  result.overrideRecordText = gate.overrideRecordText
  result.keepStore = opts.keepStore
  # §13 decisions 81, 112 and 113: the completion record follows the
  # removal of the evidence, made durable, on every way out; an uninstall
  # that stops before it leaves the intent record alone ("authorised, not
  # completed"), and a later cleanup failure does not hold it back.
  # The key is read now, before anything is removed, so that a key that
  # cannot be read stops the uninstall with nothing removed. The completion
  # is written before the key is removed (``completeDiscardBeforeKeys``);
  # a run that stops earlier signs it from the deferred call below.
  var signer: TextSigner
  if result.overrideRecord.len > 0:
    try: signer = loadTextSigner(custody.evidence.attestationKey)
    except CatchableError as e:
      result.errors.add("the attestation key " &
        custody.evidence.attestationKey & " could not be read to sign the " &
        "completion of the discard (" & e.msg & "); the intent record " &
        result.overrideRecord & " stands")
      result.errors.add("nothing was removed")
      return
  var discardFinished = false   # the completion step already ran
  defer:
    if not discardFinished:
      finishDiscard(result, custody, signer, evidenceKept)
    signer.wipe()
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
  # A revert's persistent holds (§13 decision 133) go with the drop-ins:
  # left behind, one would keep an operator's own unit of that name, or a
  # package unit the add-on had replaced and handed back, from ever
  # starting. Each is removed only while it still holds the bytes the
  # ledger recorded (the revert's hold text); its ``<unit>.d`` directory is
  # an ``lcDir`` entry, removed in step 4 once empty.
  for rh in byClass[lcRevertHold]:
    removeOwned(rh, result, driver)

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
    if keepStateWhenIncomplete(result, l, stateDir): return
  # The store goes BEFORE the keys and the state: a removal that fails
  # (``/repro`` part-way, or still mounted) makes the uninstall incomplete
  # just as drift does, and the state, with the ledger copy and the
  # attestation key a second uninstall needs, must still be there then.
  let storeFailed = removeStore(result, opts.keepStore)
  # Only what this run found on disk can be removed by it; the objects of
  # an earlier run's intent were gone before this one started.
  classifyLeftAside(result, evidenceAtStart, asideRoot(custodySite(stateDir)),
                    opts.keepStore)
  if keepStateAfterStore(result, l, stateDir, storeFailed): return
  # The store evidence under the state goes next, still before the keys
  # (round 11): an entry that cannot be removed (an immutable file) makes
  # the uninstall incomplete like a failed store removal, and the state
  # with the attestation key must still be there for the second run.
  if removeStateEvidence(result, evidenceEntries(custodySite(stateDir))):
    discard keepStateWhenIncomplete(result, l, stateDir)
    return
  # Everything the discard removes is gone: the completion is written now,
  # while the key and the state are still there (decision 113), and kept
  # for a re-run when it cannot be (decision 62).
  discardFinished = true
  if completeDiscardBeforeKeys(result, l, stateDir, custody, signer,
                               evidenceKept):
    return
  for k in byClass[lcKey]:
    if not k.isPreBootstrapInput:
      removeOwned(k, result)
  # A key the host created for itself after generation 0 (``lcLateKey``):
  # the add-on's, whatever its bytes; absent when the first boot never ran.
  for k in byClass[lcLateKey]:
    if fileExists(k.path) and not symlinkExists(k.path):
      try:
        removeFile(k.path)
        result.removed.add(k.path)
      except OSError as ex:
        result.errors.add(k.path & ": " & ex.msg)
  # The secrets ramfs (A7) is unmounted, its plaintext gone, before the
  # roots are removed.
  try:
    releaseRunDir(defaultSecretsLayout())
  except CatchableError as ex:
    result.errors.add(defaultSecretsLayout().runDir & ": " & ex.msg)
  # The store evidence directory (§13 decision 47) goes with the state
  # (`/var/lib/repro`), whatever --keep-store says (that keeps `/repro`).
  # Its entries were named, and the uninstall refused, before anything was
  # removed unless the operator passed --discard-store-evidence (above);
  # they were removed, each checked gone, above. One that appeared since
  # is reported with the root, once the root is gone.
  let stateEvidence = evidenceEntries(custodySite(stateDir))
  for root in ["/etc/repro", "/var/lib/repro", "/run/repro"]:
    removeHostRoot(result, root,
                   if root == "/var/lib/repro": stateEvidence else: @[])
  restorePreBootstrapInputs(captured, opts.keepStore, result)
