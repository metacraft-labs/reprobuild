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
## 5. remove the store (unless ``--keep-store``), then each store-evidence
##    entry, then write the discard's completion (§13 decision 81), then
##    the secrets ramfs, ``/run/repro``, ``/etc/repro`` but the Evidence
##    sink's configuration and CA (decision 56), the keys, those two files
##    and ``/etc/repro``, and last the state, ``/var/lib/repro``, with its
##    ledger copy last of all (§13 decision 150). Any failure
##    on the way keeps the state, with its ledger copy and the attestation
##    key, for a second uninstall to finish (A11 code review rounds 11 and
##    12).
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
from ./preflight import AgentStateDir, AgentStateRecordsDir, RecipientKeyPath
import ./preflight as preflightPaths
import ./switch
import ./record_dir
from repro_infra/carried_state import nil
export RecordExistsError


type
  UninstallOptions* = object
    stateDir*: string
    keepStore*: bool
    discardUnacknowledgedStoreEvidence*: bool
      ## §13 decision 62: discard the store evidence even when the sink has
      ## not acknowledged its records, after a signed local record of each
      ## object discarded unshipped is written and printed.
    stateRoot*: string
      ## The state root that holds ``stateDir`` ("" = ``/var/lib/repro``).
    logDir*: string
      ## Where the state-removal token goes ("" = ``/var/log/repro-addon``,
      ## beside the discard records; §13 decision 165).
    custody*: CustodySite
      ## The store custody site ("" ``stateDir`` = the default for
      ## ``stateDir``): a test's own, with its own attestation key.
    ship*: proc (): tuple[ok: bool; why: string] {.closure.}
      ## How the gate ships the evidence outbox (nil = ``shipEvidenceNow``):
      ## a test's stand-in for a sink that does not acknowledge.
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
    resumedIntent*: bool
      ## §13 decision 148: ``overrideRecord`` is an earlier run's intent,
      ## carrying a valid discard marker, that this run completes; this run
      ## wrote no intent and authorised nothing.
    markerKept*: seq[string]
      ## The objects that earlier run's marker records as kept with the
      ## store; ``finishDiscard`` counts them as kept.
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
    notes*: seq[string]
      ## What uninstall left as it is and the operator should know about,
      ## without failing the run: a pre-bootstrap input absent from the
      ## host, or one whose prior owner is no account any more (§13
      ## decision 166).

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

var
  ODirectory {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
  ONoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint

type
  PreBootstrapInput* = object
    ## A pre-bootstrap input the add-on took over (spec §6.1): uninstall
    ## leaves it in place, never deleting or recreating it, and puts back
    ## only the mode and owner it had before the add-on (§13 decision 166).
    path*: string
    isDir*: bool
    mode*: int          ## the mode before the add-on
    uid*, gid*: int     ## the owner before the add-on

  InputStepHook* = proc (step, path: string)
    ## A test seam: called at the named steps of the state removal
    ## ("chowned", between an input's chown and its chmod; "ledger-copy-
    ## removed"), so a test can stop the run there as a crash would. Nil in
    ## production.

const PriorUncapturedBeforeFix* = ["/run/repro", preflightPaths.SecretsRunDir,
                                    AgentStateDir, AgentStateRecordsDir]
  ## The takeover roots a bootstrap before §13 decision 167 recorded after
  ## the takeover (``rootEntry(p, takeOverRootDir(p, mode),
  ## baseRootValue(p))``, arguments evaluated left to right): on a ledger
  ## without the ``PriorCapturedBeforeTakeover`` marker their recorded
  ## prior value is the add-on's own mode and owner. The other takeover
  ## roots went through ``establishRoot``, which always read it first.

proc preBootstrapInputs*(l: Ledger; expectedOwner = (0, 0)):
    tuple[inputs: seq[PreBootstrapInput]; drift, errors, notes: seq[string]] =
  ## Every pre-bootstrap input the ledger names, with the mode and owner it
  ## had before the add-on: a directory's from the value bootstrap read
  ## before its takeover (``replaced``; the takeover made it root's, with
  ## the add-on's mode), a file's as the ledger recorded it (bootstrap never
  ## changes a kept file's). A content-pinned input whose bytes changed is
  ## ``drift`` (an agent record's content is unpinned: it cannot drift).
  ## Nothing is read into memory to be written back: uninstall never
  ## rewrites an input.
  ##
  ## §13 decision 167: on a ledger an earlier bootstrap wrote (no
  ## ``PriorCapturedBeforeTakeover`` marker on the entry), the roots in
  ## ``PriorUncapturedBeforeFix`` carry the add-on's mode as their prior
  ## one; that recorded mode is what is put back, and a note says the prior
  ## mode was not captured. The pre-bootstrap inputs left in place (§13
  ## decision 166, amended in round 16): the preflight accepts only inputs
  ## owned by ``expectedOwner`` (root, 0:0),
  ## so a recorded prior owner that is anything else is a corrupt ledger:
  ## an error, which keeps the ledger, and nothing is put back from it.
  for e in l.entries:
    if not e.isPreBootstrapInput: continue
    try:
      var inp: PreBootstrapInput
      case e.class
      of lcRoot, lcDir:
        let (mode, uid, gid) = priorModeOwner(e.replaced)
        inp = PreBootstrapInput(path: e.path, isDir: true, mode: mode,
                                uid: uid, gid: gid)
        when not mutated("unmarked-prior-trusted"):
          if e.observation != PriorCapturedBeforeTakeover and
              e.path in PriorUncapturedBeforeFix:
            result.notes.add(e.path & ": its mode before the add-on was " &
              "not captured (this host was bootstrapped before that was " &
              "fixed); it keeps the add-on's mode " & toOct(mode, 4) &
              " as recorded")
      of lcKept, lcEtcFile, lcKey:
        if e.class != lcKept:
          let d = observeDrift(e)
          if d.len > 0 and not d.startsWith("missing"):
            result.drift.add(e.path & ": " & d)
        let (uid, gid) = parseOwner(e.owner)
        inp = PreBootstrapInput(path: e.path, isDir: false,
          mode: parseOctInt(e.mode), uid: uid, gid: gid)
      else: continue
      if (inp.uid, inp.gid) != expectedOwner:
        result.errors.add(e.path & ": the ledger records its owner before " &
          "the add-on as " & $inp.uid & ":" & $inp.gid & ", but the " &
          "preflight accepts only inputs owned by " & $expectedOwner[0] &
          ":" & $expectedOwner[1] & "; the ledger is corrupt, so nothing " &
          "is put back from it and it is kept")
        continue
      result.inputs.add(inp)
    except CatchableError as ex:
      result.errors.add(e.path & ": the ledger's record of this " &
        "pre-bootstrap input cannot be read (" & ex.msg & ")")

proc refuseCorruptInputs*(r: var UninstallResult;
                          pb: tuple[inputs: seq[PreBootstrapInput];
                                    drift, errors, notes: seq[string]];
                          ledgerPath: string): bool =
  ## True, with the errors and their remedy reported, when the ledger's
  ## record of a pre-bootstrap input is corrupt (``preBootstrapInputs``):
  ## the uninstall must then stop before step 1, with nothing removed.
  if pb.errors.len == 0: return false
  when mutated("corrupt-input-record-continues"):
    for e in pb.errors: r.errors.add(e)
    return false        # FALSIFIER: the run goes on with a corrupt ledger
  for e in pb.errors: r.errors.add(e)
  r.errors.add("nothing was removed: the ledger " & ledgerPath & " records " &
    "a pre-bootstrap input in a way the preflight cannot have; restore it " &
    "from the generation it came from (<state>/generations/<id>/" &
    "addon-ledger) or correct that entry, then run uninstall again")
  true

proc inputPaths*(inputs: seq[PreBootstrapInput]): seq[string] =
  for i in inputs: result.add(i.path)

proc removeAllBelowKeeping*(dir: string; keep: seq[string]) =
  ## Removes everything below ``dir`` except the paths in ``keep``: a kept
  ## directory, and a directory on the way to a kept path, is descended
  ## into and its other entries removed, but is itself left; a kept file is
  ## left. A symbolic link is removed as a link, never followed. Raises
  ## ``OSError`` at the first entry it cannot remove.
  for kind, p in walkDir(dir):
    let kept = p in keep
    let onTheWay = keep.anyIt(it.startsWith(p & "/"))
    if kind == pcDir and (kept or onTheWay):
      removeAllBelowKeeping(p, keep)
    elif kept:
      continue
    elif kind == pcDir:
      removeDir(p)
    else:
      removeFile(p)

proc removeAndRewrite(dir: string; keep: seq[string]) =
  ## Only the falsifiers below use it: round 15's removal, everything below
  ## ``dir`` removed and the kept paths written back from memory, so the
  ## bytes survive and the inodes do not.
  var saved: seq[tuple[p: string; isDir: bool; mode: int; bytes: string]]
  for k in keep:
    if k == dir or not k.startsWith(dir & "/"): continue
    var st: Stat
    if lstat(k.cstring, st) != 0: continue
    let isDir = S_ISDIR(st.st_mode)
    saved.add((k, isDir, int(st.st_mode) and 0o7777,
               if isDir: "" else: readFile(k)))
  for kind, p in walkDir(dir):
    if kind == pcDir: removeDir(p) else: removeFile(p)
  saved.sort(proc (a, b: auto): int = cmp(a.p.len, b.p.len))
  for x in saved:
    if x.isDir: createDir(x.p) else: writeFile(x.p, x.bytes)
    discard posix.chmod(x.p.cstring, Mode(x.mode))

proc keepingRemoval*(dir: string; keep: seq[string]; site: string) =
  ## ``removeAllBelowKeeping`` at one of uninstall's removal sites
  ## (``site``: "etc" for the ``/etc/repro`` sweep, "run" for
  ## ``/run/repro``, "store" for ``/repro``). Each site has a falsifier that
  ## reverts it to removing the pre-bootstrap inputs and writing them back,
  ## where they must be left in place (§13 decision 166).
  when mutated("etc-sweep-rewrites-inputs"):
    if site == "etc": removeAndRewrite(dir, keep); return
  when mutated("run-repro-rewrites-inputs"):
    if site == "run": removeAndRewrite(dir, keep); return
  when mutated("store-remover-rewrites-inputs"):
    if site == "store": removeAndRewrite(dir, keep); return
  removeAllBelowKeeping(dir, keep)

proc keptFloors*(inputs: seq[PreBootstrapInput];
                 keyPath = RecipientKeyPath;
                 recordsDir = AgentStateRecordsDir): seq[string] =
  ## §13 decision 168: when the deploy agent's recipient key is a kept
  ## input, every sequence floor (``*.seq``) in its records directory is
  ## kept too, the ones the add-on's agent wrote after bootstrap (a new
  ## target name) included: a floor that went while its key stays would let
  ## a manifest this host already accepted replay on that key. Only regular
  ## files; a link is not a floor.
  when mutated("new-floors-removed"):
    return @[]        # FALSIFIER: only the floors the preflight saw stay
  if not inputs.anyIt(it.path == keyPath and not it.isDir): return
  if not dirExists(recordsDir): return
  for kind, p in walkDir(recordsDir):
    if kind == pcFile and p.endsWith(".seq"):
      result.add(p)

proc putBackInputMetadata*(r: var UninstallResult;
                           inputs: seq[PreBootstrapInput];
                           hook: InputStepHook = nil): bool =
  ## §13 decision 166: each input, left in place, gets back the owner and
  ## mode it had before the add-on -- fchown, then fchmod (a chown may
  ## clear the set-id bits a chmod then sets), then fsync -- through a
  ## descriptor opened without following a link, so a link planted on its
  ## path is refused, not followed. Idempotent: an input already right is
  ## only fsynced, so a run stopped between the two (a crash) is finished
  ## by the next. An input absent from the host is a note (uninstall never
  ## recreates one; ``/run`` is emptied by a reboot). The prior owner is
  ## always root's: ``preBootstrapInputs`` refuses a ledger that records
  ## another (§13 decision 166, amended). True when no input failed.
  result = true
  for inp in inputs:
    var st: Stat
    if lstat(inp.path.cstring, st) != 0:
      if errno == ENOENT:
        r.notes.add(inp.path & ": a pre-bootstrap input that is not on " &
          "the host now; uninstall never recreates an input, so it stays " &
          "absent")
      else:
        r.errors.add(inp.path & ": " & $strerror(errno))
        result = false
      continue
    let want = if inp.isDir: S_ISDIR(st.st_mode) else: S_ISREG(st.st_mode)
    if not want:
      r.errors.add(inp.path & ": a pre-bootstrap input that is no longer " &
        (if inp.isDir: "a directory" else: "a regular file") &
        "; it is left as it is")
      result = false
      continue
    let flags = O_RDONLY or O_CLOEXEC or ONoFollow or
                (if inp.isDir: ODirectory else: 0)
    let fd = posix.open(inp.path.cstring, flags)
    if fd < 0:
      r.errors.add(inp.path & ": cannot open it to put back its mode and " &
        "owner: " & $strerror(errno))
      result = false
      continue
    defer: discard posix.close(fd)
    if fstat(fd, st) != 0:
      r.errors.add(inp.path & ": " & $strerror(errno))
      result = false
      continue
    if int(st.st_uid) != inp.uid or int(st.st_gid) != inp.gid:
      if fchown(fd, Uid(inp.uid), Gid(inp.gid)) != 0:
        r.errors.add(inp.path & ": chown " & $inp.uid & ":" & $inp.gid &
          " failed: " & $strerror(errno))
        result = false
        continue
    if hook != nil: hook("chowned", inp.path)
    if (int(st.st_mode) and 0o7777) != inp.mode:
      if fchmod(fd, Mode(inp.mode)) != 0:
        r.errors.add(inp.path & ": chmod " & toOct(inp.mode, 4) &
          " failed: " & $strerror(errno))
        result = false
        continue
    if fsync(fd) != 0:
      r.errors.add(inp.path & ": fsync after putting back its mode and " &
        "owner failed: " & $strerror(errno))
      result = false
      continue

const CannotBeShipped* = "cannot be shipped"
  ## The words ``shipAndConfirm`` ends its reason with when no later run can
  ## ship the records either: ``storeEvidenceGate`` then does not tell the
  ## operator to wait for an acknowledgement (§13 decision 56).

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
      "that did not finish removed it), so they " & CannotBeShipped)
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

const StateRoot* = "/var/lib/repro"
  ## The add-on's state, removed last, the ledger copy last within it but
  ## for the rmdir of the empty directories (§13 decisions 150 and 161).
const UninstallOverrideDir* = AddonLogDir
  ## Where §13 decision 62's override record is written: outside
  ## ``/var/lib/repro`` and ``/etc/repro``, which uninstall removes.

const
  DiscardRecordSchema* = "repro-addon-store-evidence-discard-intent/3"
    ## §13 decision 81: the INTENT record, signed and made durable before
    ## anything is removed. It says the operator authorised discarding these
    ## objects unshipped; it does not say they were discarded. /2 (one
    ## record, read as "discarded") and /1 are no longer written.
  DiscardMarkerSchema* = "repro-addon-store-evidence-discard-removed/1"
    ## §13 decision 148: the signed DISCARD MARKER. A run writes it under the
    ## add-on's state (``/var/lib/repro``), fsynced, once it has removed and
    ## synced every object of its own intent and before it writes the
    ## completion; it binds that intent by file name and sha256. Only an
    ## uncompleted intent that carries a valid marker may be completed by a
    ## later run.
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

proc syncDirFd(dir: string) =
  let fd = posix.open(dir.cstring, O_RDONLY or ODirectory or O_CLOEXEC)
  if fd < 0:
    raise newException(OSError, "cannot open " & dir & " to sync it: " &
      $strerror(errno))
  defer: discard posix.close(fd)
  if fsync(fd) != 0:
    raise newException(OSError, "fsync of " & dir & " failed: " & $strerror(errno))

proc writeFileExclusiveByPath(path, text: string; mode = 0o600) =
  ## Only the falsifier ``record-dir-link-followed`` uses it: the writer
  ## as it was before A11 round 18, by path.
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

proc writeFileExclusiveDurable*(path, text: string; mode = 0o600) =
  ## Writes ``path`` only if no file of that name exists (round 9),
  ## durably: the bytes go to a temporary file in the same directory, which
  ## is fsynced and then linked to ``path`` -- ``linkat(2)`` refuses an
  ## existing name, where a rename would replace it -- and the directory is
  ## fsynced. Every step goes through one checked descriptor of the
  ## directory (``record_dir``; A11 round 18): a symbolic link planted in
  ## the directory's place -- Ubuntu's ``/var/log`` is group-writable -- is
  ## refused, never followed. Raises ``RecordExistsError`` when the name is
  ## taken.
  when mutated("record-dir-link-followed"):
    writeFileExclusiveByPath(path, text, mode)  # FALSIFIER: round 17's path-based writer
  else:
    writeInCheckedDir(path, text, mode,
                      replace = mutated("intent-overwrites-existing"))

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

type RecordReader* = proc (path: string): string {.closure.}

proc recRead*(path: string): string =
  ## A discard record (or marker) read through its directory's checked
  ## descriptor (``record_dir``; A11 round 19): never through a link,
  ## never a FIFO or device, never more than ``MaxRecordBytes``.
  when mutated("record-read-by-path"):
    readFile(path)       # FALSIFIER: the path-based read of round 18
  else:
    readInCheckedDir(path)

proc recExists*(path: string): bool =
  ## Whether a name exists in a records directory, looked up through its
  ## checked descriptor; an untrusted directory counts as "present" so that
  ## the caller goes on to the read, which refuses it.
  when mutated("record-read-by-path"):
    fileExists(path) or dirExists(path) or symlinkExists(path)  # FALSIFIER
  else:
    try: existsInCheckedDir(path)
    except OSError: true

proc recList*(dir: string): seq[string] =
  ## The regular files of a records directory, enumerated through a
  ## duplicate of its checked descriptor; empty when it is absent or may
  ## not be trusted.
  when mutated("record-read-by-path"):
    if dirExists(dir):                       # FALSIFIER: walkDir by path
      for kind, p in walkDir(dir):
        if kind == pcFile: result.add(p)
  else:
    try:
      for (name, regular) in listInCheckedDir(dir):
        if regular: result.add(dir / name)
    except OSError: discard

proc writeOverrideRecord(custody: CustodySite; dir: string;
                         objects: seq[string]; why: string;
                         writer: DiscardRecordWriter):
    tuple[path, text: string] =
  ## §13 decisions 62, 63 and 64: the signed local record of the store
  ## evidence an uninstall discards before the sink acknowledged its
  ## records -- every object, every record still queued, why, and the
  ## public half of the attestation key that signs it. The file holds exactly the bytes
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
  when mutated("record-dir-link-followed"):
    createDir(dir)       # FALSIFIER: by path, a link in its place followed
    setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
  else:
    # Root's 0700, checked on a descriptor that does not follow a link
    # (A11 round 18): never a planted link's target.
    ensureCheckedDir(dir)
  # A unique name (round 9): the second-resolution stamp, and a sequence
  # number when a record, its signature or its completion already holds
  # it. The writer still refuses a name taken in between.
  let stamp = "uninstall-" & t.utc.format("yyyyMMdd'T'HHmmss'Z'")
  var n = 0
  while true:
    result.path = dir / (stamp & (if n == 0: "" else: "-" & $n) & DiscardIntentSuffix)
    when mutated("intent-overwrites-existing"):
      break
    if not (recExists(result.path) or
            recExists(result.path & DiscardRecordSigExt) or
            recExists(completionPathOf(result.path))):
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
    try: removeInCheckedDir(result.path & DiscardRecordSigExt) except OSError: discard
    raise
  except CatchableError as e:
    var inPlace = false
    try: inPlace = recRead(result.path) == result.text
    except CatchableError: discard
    if inPlace and not mutated("override-rollback-removes-sig"):
      raise newException(OSError, "the intent record " & result.path &
        " and its signature are in place, but making them durable failed (" &
        e.msg & "); both are kept and state an authorisation only")
    try: removeInCheckedDir(result.path & DiscardRecordSigExt) except OSError: discard
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

proc readSignedRecord(path, schema, expectedKeyHex: string;
                      reader: RecordReader = recRead):
    tuple[ok: bool; why, text: string; doc: JsonNode] =
  ## A record at ``path`` of ``schema``, signed over exactly its bytes by
  ## ``expectedKeyHex`` (``<path>.sig``). ``reader`` is the checked read
  ## (``recRead``) for the add-on's own records, and the bounded read by
  ## path for a record an operator names on the command line.
  let text = try: reader(path)
             except CatchableError as e: return (false, "cannot read " & path & ": " & e.msg, "", nil)
  let sig = try: reader(path & DiscardRecordSigExt).strip()
            except CatchableError as e:
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
  let intent = readSignedRecord(intentPath, DiscardRecordSchema, key,
                                readBoundedByPath)
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
    let done = readSignedRecord(cpath, DiscardCompletionSchema, key,
                                readBoundedByPath)
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

proc discardMarkerPath*(custody: CustodySite; intentPath: string): string =
  ## Where a run's discard marker for ``intentPath`` lives: under the
  ## add-on's state, never beside the intent in ``/var/log/repro-addon``
  ## (§13 decision 148: an immutable log directory must not block it).
  var name = extractFilename(intentPath)
  if name.endsWith(DiscardIntentSuffix):
    name = name[0 ..< name.len - DiscardIntentSuffix.len]
  custody.stateDir / "addon" / "discard-markers" / (name & "-discard-removed.json")

proc writeDiscardMarker*(custody: CustodySite; signer: TextSigner;
                         intentPath, intentText: string;
                         removed, kept: seq[string];
                         writer: DiscardRecordWriter = atomicRecordWriter) =
  ## §13 decision 148: the signed marker that this run removed and synced
  ## every object of its own intent. Signature first, record last, each
  ## written exclusively and fsynced with its directory. An existing marker
  ## for the same intent is left as it is.
  let path = discardMarkerPath(custody, intentPath)
  if fileExists(path): return
  let markers = parentDir(path)
  if not dirExists(markers):
    # §13 decision 162: a new discard-markers/ is an entry of its parent,
    # synced so that the marker's own directory fsync below is not undone
    # by losing the directory it is in.
    createDir(markers)
    syncDirFd(parentDir(markers))
  let j = %*{"schema": DiscardMarkerSchema,
             "record": "removed: every object of the intent record was " &
                       "removed (or kept with the store) and the removal " &
                       "made durable; its completion follows",
             "time": getTime().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
             "host": custody.evidence.host,
             "intent": extractFilename(intentPath),
             "intentSha256": sha256Hex(intentText),
             "removed": removed, "keptWithTheStore": kept,
             "attestationKey": signer.publicKeyHex}
  let text = pretty(j) & "\n"
  writer(path & DiscardRecordSigExt, signWith(signer, text) & "\n")
  writer(path, text)

proc validDiscardMarker*(custody: CustodySite; intentPath, intentText,
                         hostKeyHex: string; intentObjects: seq[string]):
    tuple[ok: bool; why: string; removed, kept: seq[string]] =
  ## §13 decision 148: the marker for ``intentPath`` verifies when it is
  ## signed by the host's attestation key over exactly its bytes, binds
  ## this intent (its file name and the sha256 of its bytes), accounts for
  ## exactly the intent's objects, and every object it names as removed is
  ## still gone.
  let path = discardMarkerPath(custody, intentPath)
  if not recExists(path):
    return (false, "no discard marker " & path, @[], @[])
  var doc: JsonNode
  when mutated("marker-signature-unchecked"):
    # FALSIFIER: an unsigned or forged marker is taken at its word.
    try: doc = parseJson(recRead(path))
    except CatchableError as e: return (false, e.msg, @[], @[])
    if doc{"schema"}.getStr() != DiscardMarkerSchema:
      return (false, path & " is not a discard marker", @[], @[])
  else:
    let rec = readSignedRecord(path, DiscardMarkerSchema, hostKeyHex)
    if not rec.ok: return (false, rec.why, @[], @[])
    doc = rec.doc
  for o in doc{"removed"}.getElems(): result.removed.add(o.getStr())
  for o in doc{"keptWithTheStore"}.getElems(): result.kept.add(o.getStr())
  when not mutated("marker-not-bound-to-intent"):
    if doc{"intent"}.getStr() != extractFilename(intentPath) or
        doc{"intentSha256"}.getStr() != sha256Hex(intentText):
      return (false, path & " does not bind " & intentPath, @[], @[])
    var named = result.removed & result.kept
    named.sort()
    var objs = intentObjects
    objs.sort()
    if named != objs:
      return (false, path & " does not account for exactly the objects " &
        "of " & intentPath, @[], @[])
  for o in result.removed:
    if fileExists(o) or dirExists(o) or symlinkExists(o):
      return (false, o & " is on disk again", @[], @[])
  result.ok = true

proc unfinishedDiscardIntent*(custody: CustodySite;
                              dir = UninstallOverrideDir):
    tuple[path, text: string; objects: seq[string]] =
  ## §13 decisions 62, 81, 113 and 148: the newest discard intent record in
  ## ``dir`` that the host's own attestation key signed, that has no
  ## completion record, and that carries a valid discard marker
  ## (``validDiscardMarker``), or an empty path. Its run removed and synced
  ## every object of it and then could not write the completion, and it
  ## kept the state and the key so that a later run could. Every other
  ## earlier intent -- one whose run stopped before its objects were gone,
  ## or whose removal could not be made durable -- stays "authorised, not
  ## completed" for good. A record signed by another key, or one that does
  ## not verify, is not the host's authorisation and is left alone.
  let keyPath = custody.evidence.attestationKey
  if not fileExists(keyPath): return
  var hostKey = ""
  try: hostKey = attestationPublicKeyHex(keyPath)
  except CatchableError: return
  var names: seq[string]
  for path in recList(dir):
    if path.endsWith(DiscardIntentSuffix):
      names.add(path)
  names.sort(order = SortOrder.Descending)
  for path in names:
    if recExists(completionPathOf(path)): continue
    let rec = readSignedRecord(path, DiscardRecordSchema, hostKey)
    if not rec.ok: continue
    var objects: seq[string]
    for o in rec.doc{"objects"}.getElems(): objects.add(o.getStr())
    when not mutated("resume-without-marker"):
      if not validDiscardMarker(custody, path, rec.text, hostKey, objects).ok:
        continue
    result.path = path
    result.text = rec.text
    result.objects = objects
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
      try: removeInCheckedDir(stale) except OSError: discard
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
    if CannotBeShipped in shipped.why:
      # No acknowledgement can arrive: never ask the operator to wait for
      # one (§13 decision 56).
      result.errors.add("the Evidence sink has not acknowledged the " &
        "records of the store evidence uninstall would discard (" &
        shipped.why & "), and no later run can ship them; discard them " &
        "unshipped with --discard-unacknowledged-store-evidence, which " &
        "writes and prints a signed record of each")
    else:
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
                   syncer: DiscardSyncer = syncRemovedObjects;
                   markerWriter: DiscardRecordWriter = atomicRecordWriter) =
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
    if o in r.markerKept:
      kept.add(o)               # decision 148: kept, as its marker records
    elif o in r.keptEvidence and (r.keepStore or mutated("finish-trusts-kept-list")):
      kept.add(o)
    elif fileExists(o) or dirExists(o) or symlinkExists(o):
      when not mutated("discard-completed-objects-present"):
        return
    else: removed.add(o)
  # §13 decision 148: the marker, written only once the removal is
  # durable, and before the completion; a later run may complete this
  # intent only when it carries it.
  template writeMarker() =
    try:
      writeDiscardMarker(custody, signer, r.overrideRecord,
                         r.overrideRecordText, removed, kept, markerWriter)
    except CatchableError as e:
      r.errors.add("the store evidence was removed, but its discard " &
        "marker could not be written (" & e.msg & "); no completion record " &
        "is written, and the intent record " & r.overrideRecord &
        " stands as authorised, not completed")
      return
  when mutated("marker-before-sync"):
    writeMarker()               # FALSIFIER: the marker before the sync
  when not mutated("discard-completion-skips-sync"):
    try:
      syncer(removed)
    except CatchableError as e:
      r.errors.add("the store evidence was removed, but making its " &
        "removal durable failed (" & e.msg & "); no completion record is " &
        "written, and the intent record " & r.overrideRecord &
        " stands as authorised, not completed")
      return
  when not mutated("marker-before-sync"):
    writeMarker()
  try:
    let c = writeDiscardCompletion(custody, signer, r.overrideRecord,
                                   r.overrideRecordText, removed, kept, writer)
    r.completionRecord = c.path
  except CatchableError as e:
    let cpath = completionPathOf(r.overrideRecord)
    if recExists(cpath):
      # It reached its name, so it is true and stays; only its durability
      # is unconfirmed (a crash now may still lose it, which leaves the
      # intent as "authorised, not completed": never an overclaim).
      r.completionRecord = cpath
      when not mutated("discard-completion-sync-error-swallowed"):
        r.errors.add("the store evidence was discarded and its completion " &
          "record " & cpath & " written, but making it durable failed (" &
          e.msg & ")")
    else:
      try: removeInCheckedDir(cpath & DiscardRecordSigExt) except OSError: discard
      r.errors.add("the store evidence was discarded, but its completion " &
        "record could not be written (" & e.msg & "); the intent record " &
        r.overrideRecord & " stands as authorised, not completed")

type StoreRemover* = proc () {.closure.}

proc removeStore*(r: var UninstallResult; keepStore: bool;
                  remover: StoreRemover = removeReproRoot;
                  mounted: bool = dirExists(StoreRoot) and
                                  isMountPoint(StoreRoot);
                  keptInputs: seq[string] = @[]): bool =
  ## Removes ``/repro`` unless ``--keep-store``. True when the removal was
  ## attempted or required and did not happen (still mounted, or ``remover``
  ## raised): the uninstall is then incomplete and must keep the state.
  if mounted:
    r.errors.add(StoreRoot & " is still mounted; the store is kept")
    return true
  if keepStore: return false
  try:
    remover()
    r.removed.add(if ReproRoot in keptInputs or StoreRoot in keptInputs:
                    ReproRoot & " (emptied of the add-on's store; the " &
                      "pre-bootstrap directories stay)"
                  else: ReproRoot)
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

proc removeRootKeepingInputs*(r: var UninstallResult; root: string;
                              keep: seq[string]; site = "") =
  ## Removes one of the host roots (``/etc/repro``, ``/run/repro``) unless
  ## it holds a pre-bootstrap input: then only what is not an input goes,
  ## and the root, itself an input, stays (§13 decision 166).
  if not dirExists(root): return
  if root notin keep and not keep.anyIt(it.startsWith(root & "/")):
    removeHostRoot(r, root)
    return
  try:
    keepingRemoval(root, keep, site)
    r.removed.add(root & " (emptied of the add-on's files; the " &
      "pre-bootstrap inputs in it stay)")
  except OSError as ex:
    r.errors.add(root & ": " & ex.msg)

proc removeAllBut(dir, keep: string) =
  ## Removes everything below ``dir`` except ``keep`` and the directories
  ## on its way. Raises ``OSError`` at the first entry it cannot remove.
  for kind, p in walkDir(dir):
    if p == keep: continue
    if keep.startsWith(p & "/") and kind == pcDir:
      removeAllBut(p, keep)
    elif kind == pcDir:
      removeDir(p)
    else:
      removeFile(p)

proc holdsOnlyEmptyDirs(dir: string): bool =
  ## True when nothing is below ``dir`` but directories, themselves empty
  ## of anything else (a symbolic link, even to a directory, is not one).
  ## Only the falsifier ``state-removal-token-not-required`` uses it: the
  ## re-run judges by the token's chain, never by the shape of the tree.
  for kind, p in walkDir(dir):
    if kind != pcDir or not holdsOnlyEmptyDirs(p): return false
  true

proc rmdirHint(err: cint): string =
  ## Why an rmdir(2) of a directory the uninstall emptied fails, for the
  ## operator. rmdir(2): EBUSY for a mount point; EPERM when the parent is
  ## immutable or append-only, or the directory itself is immutable;
  ## ENOTEMPTY (or EEXIST) when an entry is in it.
  if err == EBUSY: "it is a mount point; unmount it"
  elif err == EPERM: "it, or its parent directory, is immutable or " &
                     "append-only (lsattr -d on both); clear the attribute"
  elif err == EACCES: "its parent directory does not allow the removal; " &
                      "fix the parent's permissions"
  elif err == EROFS: "its file system is mounted read-only; remount it " &
                     "read-write"
  elif err == ENOTEMPTY or err == EEXIST:
    "something is in it: an entry created after the uninstall emptied it, " &
      "or one it could not list or remove; look inside and remove it"
  else: "clear the cause"

const
  StateRemovalTokenName* = "uninstall-state-removal-pending.json"
    ## §13 decision 165 (a): the state-removal token, beside the discard
    ## records, outside the state.
  StateRemovalTokenSchema* = "repro-addon-uninstall-state-removal/1"

proc stateRemovalTokenPath*(logDir = UninstallOverrideDir): string =
  logDir / StateRemovalTokenName

proc stateDirChain*(root, ledgerCopy: string; preBootstrap: seq[string]):
    seq[string] =
  ## The add-on's own directories that hold the ledger copy, deepest first:
  ## from the ledger copy's directory up to ``root``. It stops below the
  ## first pre-bootstrap root (§13 decision 165 (b)): that directory was
  ## the host's before the add-on, and it and everything above it stay.
  var d = parentDir(ledgerCopy)
  while d == root or d.startsWith(root & "/"):
    when not mutated("pre-bootstrap-root-rmdir"):
      if d in preBootstrap: break
    result.add(d)
    if d == root: break
    d = parentDir(d)

proc tokenDirRefusal*(dir: string): string =
  ## "" when ``dir`` may hold the token (``record_dir.openCheckedDir``'s
  ## checks), else why not. An absent directory is not refused.
  checkedDirRefusal(dir)

proc removeTokenDurably(path: string) =
  removeInCheckedDir(path)

proc clearStateRemovalToken*(logDir = UninstallOverrideDir) =
  ## Bootstrap's step (§13 decisions 165 and 178): a token an earlier
  ## uninstall left is removed, durably, through the checked descriptor,
  ## before a new install writes anything, so no later re-run acts on a
  ## removal of another install. Raises ``OSError`` when it cannot be (a
  ## directory of that name, or a log directory that may not be used).
  removeInCheckedDir(stateRemovalTokenPath(logDir))

proc stateDirIdentity*(d: string): string =
  ## A directory's identity for the token (A11 round 18): its inode number
  ## AND its birth time (``statx`` ``STATX_BTIME``), with its inode
  ## generation where the file system has one -- never ``st_dev``, which is
  ## not stable across a reboot on btrfs or device-mapper. The number alone
  ## does not identify a directory: ext4 gives a new one the number an
  ## unlinked one had. "" when ``d`` is not a directory; ``<ino>@-`` when
  ## nothing but the number is known.
  let id = carried_state.dirIdentity(d)
  if id.dev < 0: return ""
  result = $id.ino & "@" &
    (if id.haveBtime: $id.btimeSec & "." & $id.btimeNsec else: "-")
  if id.haveGen: result.add("g" & $id.gen)

type IdentityOf* = proc (path: string): string {.closure.}

proc sameStateDir(recorded, live: string): bool =
  ## Whether ``live`` is the directory ``recorded`` names: equal, and at
  ## least one discriminator beyond the inode number on both (a birth time
  ## or a generation). Without one nothing tells a new directory with a
  ## reused number apart, so the answer is no (fail closed).
  when mutated("token-binds-inode-only"):
    return recorded.split('@')[0] == live.split('@')[0]   # FALSIFIER
  if recorded != live: return false
  # A birth time is required (A11 round 19): a generation alone
  # (``<ino>@-g<N>``) is not taken as enough.
  let rest = live.split('@', 1)
  rest.len == 2 and rest[1].len > 0 and not rest[1].startsWith("-")

proc writeStateRemovalToken(path, root, ledgerCopy: string;
                            chain, preBootstrap: seq[string];
                            identityOf: IdentityOf) =
  ## Durably, all through the directory's checked descriptor
  ## (``record_dir.writeInCheckedDir``, replacing a stale token). The
  ## token must be on disk before the ledger copy goes, or a crash between
  ## the two leaves a state no re-run may finish. It binds this install:
  ## the identity of each directory of the chain (``stateDirIdentity``),
  ## which a re-run must find unchanged.
  var ids = newJObject()
  for d in chain: ids[d] = %identityOf(d)
  let text = pretty(%*{"schema": StateRemovalTokenSchema, "root": root,
    "ledgerCopy": ledgerCopy, "chain": chain, "chainIdentity": ids,
    "preBootstrapRoots": preBootstrap}) & "\n"
  writeInCheckedDir(path, text, 0o600, replace = true)

proc readStateRemovalToken(path, root: string; identityOf: IdentityOf):
    tuple[ok: bool; why: string; chain: seq[string]] =
  ## The chain a token names, checked: its schema, its root, every
  ## directory in it ``root`` or below it and none of them a pre-bootstrap
  ## root it names, and each one that still exists the very directory the
  ## uninstall that wrote the token recorded (``sameStateDir``), so an old
  ## token hidden and restored after a new install is refused. A token
  ## without ``chainIdentity`` (written by a build before A11 round 17)
  ## binds nothing and is refused the same way, with the same remedy.
  const Remedy = "; if those directories are empty and the add-on's, " &
    "remove them and the token yourself, then run uninstall again"
  var text: string
  try: text = readInCheckedDir(path)
  except OSError as e:
    return (false, "it may not be trusted: " & e.msg, @[])
  var j: JsonNode
  try: j = parseJson(text)
  except CatchableError as e: return (false, e.msg, @[])
  if j.kind != JObject or j{"schema"}.getStr != StateRemovalTokenSchema:
    return (false, "not a " & StateRemovalTokenSchema & " record", @[])
  if j{"root"}.getStr != root:
    return (false, "it names the state " & j{"root"}.getStr & ", not " & root, @[])
  var keep: seq[string]
  for k in j{"preBootstrapRoots"}.getElems: keep.add(k.getStr)
  let ids = j{"chainIdentity"}
  for c in j{"chain"}.getElems:
    let d = c.getStr
    if not (d == root or d.startsWith(root & "/")) or d.contains("/../") or
        d.endsWith("/..") or d in keep:
      return (false, "its chain names " & d & ", which is not one of the " &
        "add-on's own directories under " & root, @[])
    when not mutated("token-not-bound-to-install"):
      let now = identityOf(d)
      if now.len > 0:
        if ids == nil or ids.kind != JObject:
          return (false, "it records no identity for the directories it " &
            "names (written by an earlier build)" & Remedy, @[])
        if not sameStateDir(ids{d}.getStr, now):
          return (false, d & " is not the directory the uninstall that " &
            "wrote the token recorded (another install's token, or one this " &
            "file system cannot tell apart)" & Remedy, @[])
    result.chain.add(d)
  result.chain.sort(proc (a, b: string): int = cmp(b.len, a.len))
  result.ok = true

proc removeChain(chain: seq[string]):
    tuple[failed: string; err: cint; removed: seq[string]] =
  ## rmdir(2) each directory of the chain, deepest first; one already gone
  ## is skipped. The first failure names its directory and errno;
  ## ``removed`` lists the directories this call removed.
  for d in chain:
    if not dirExists(d) and not symlinkExists(d): continue
    if posix.rmdir(d.cstring) != 0:
      result.failed = d
      result.err = errno
      return
    result.removed.add(d)

proc reportEmptyDirsLeft(r: var UninstallResult; root, failed: string;
                         err: cint; chain: seq[string]) =
  ## The precise report of a failed rmdir after the ledger copy (§13
  ## decisions 161 and 165). It says what is known: the ledger copy is
  ## gone and the token stands; it claims the rest is empty only when the
  ## rmdir did not find something in the directory.
  let left = chain[chain.find(failed) .. ^1]
  let what = (if left.len == 1: "the directory " & left[0] & " remains"
              else: "the directories " & left.join(", ") & " remain")
  let notEmpty = err == ENOTEMPTY or err == EEXIST
  r.errors.add(failed & ": rmdir failed: " & $strerror(err) & " -- " &
    rmdirHint(err) & ". The ledger copy is gone; " & what &
    (if notEmpty: ", and " & failed & " is not empty"
     else: ", empty of the add-on's state") &
    ". Run uninstall again once the cause is cleared: the token " &
    "recording this step is kept in " & UninstallOverrideDir &
    ", and a re-run that finds it, with no ledger, removes only these " &
    "directories, and only once each is empty, and succeeds")

proc removeStateRoot*(r: var UninstallResult; root, ledgerCopy: string;
                      evidence: seq[string] = @[];
                      syncer: DiscardSyncer = syncRemovedObjects;
                      preBootstrap: seq[string] = @[];
                      tokenPath = stateRemovalTokenPath();
                      inputs: seq[PreBootstrapInput] = @[];
                      hook: InputStepHook = nil;
                      identityOf: IdentityOf = stateDirIdentity) =
  ## Removes the add-on's state, ``/var/lib/repro``, with its ledger copy
  ## last but for the rmdir of the add-on's own empty directories (§13
  ## decisions 150, 161 and 165): everything but the ledger copy and the
  ## directories on its way first, checked gone and synced; then the token
  ## (``writeStateRemovalToken``), outside the state, naming the directories
  ## left to remove; then the ledger copy; then those directories, each by
  ## rmdir(2), never one that was a pre-bootstrap root (``preBootstrap``);
  ## then the token. A removal that fails before the ledger copy leaves it,
  ## so a re-run can read it and finish; one that fails after it leaves
  ## the token, says so precisely, and a re-run finishes the chain
  ## (``finishEmptyStateRoot``). The root and its evidence entries are
  ## reported removed only once the chain is gone.
  ##
  ## The pre-bootstrap inputs (§13 decision 166; ``preBootstrap`` names
  ## every one, wherever it lives, and ``inputs`` their prior mode and
  ## owner) are never removed: the removal keeps them, and before the token
  ## and the ledger copy every input, here and in ``/etc/repro``,
  ## ``/repro`` and ``/run/repro``, gets its prior owner and mode back in
  ## place (``putBackInputMetadata``). A crash at any point leaves either
  ## the ledger copy, so a re-run resumes and finishes the metadata, or the
  ## inputs already right.
  if not dirExists(root): return
  when mutated("ledger-copy-removed-with-the-rest"):
    removeHostRoot(r, root, evidence)    # FALSIFIER: round 12's one removeDir
    return
  var chain: seq[string]
  try:
    if ledgerCopy.startsWith(root & "/") and fileExists(ledgerCopy):
      var saved: seq[tuple[i: PreBootstrapInput; bytes: string]]
      when mutated("inputs-removed-and-restored"):
        # FALSIFIER: round 15's removal: the inputs go with the rest and
        # are written back from memory after the ledger copy.
        for i in inputs:
          if i.path.startsWith(root & "/"):
            saved.add((i, if i.isDir: "" else: readFile(i.path)))
        removeAllBut(root, ledgerCopy)
      else:
        removeAllBelowKeeping(root, preBootstrap & @[ledgerCopy])
      syncer(@[root & "/.state-removed"])   # the unlinks above, made durable
      when not mutated("input-metadata-after-ledger-copy") and
          not mutated("input-mode-owner-not-restored"):
        if not putBackInputMetadata(r, inputs, hook):
          r.errors.add("the ledger copy " & ledgerCopy & " is kept: a " &
            "pre-bootstrap input's mode or owner could not be put back " &
            "(above); uninstall, run again once the cause is cleared, " &
            "finishes it")
          return
      chain = stateDirChain(root, ledgerCopy, preBootstrap)
      writeStateRemovalToken(tokenPath, root, ledgerCopy, chain, preBootstrap,
                             identityOf)
      removeFile(ledgerCopy)
      if hook != nil: hook("ledger-copy-removed", ledgerCopy)
      when mutated("inputs-removed-and-restored"):
        for (i, bytes) in saved.sortedByIt(it.i.path.len):
          if i.isDir: createDir(i.path)
          else: writeFile(i.path, bytes)
          discard posix.chmod(i.path.cstring, Mode(i.mode))
      when mutated("input-metadata-after-ledger-copy"):
        # FALSIFIER: the metadata after the ledger copy: a crash between
        # them leaves nothing a re-run reads to finish it.
        discard putBackInputMetadata(r, inputs, hook)
    elif root notin preBootstrap:
      removeDir(root)   # no ledger copy under it to keep (a state elsewhere)
    when mutated("empty-state-root-reported-vaguely"):
      if dirExists(root) and root notin preBootstrap:
        removeDir(root)  # FALSIFIER: the rmdir error as round 13 reported it
    else:
      let (failed, err, _) = removeChain(chain)
      if failed.len > 0:
        reportEmptyDirsLeft(r, root, failed, err, chain)
        return
    removeTokenDurably(tokenPath)
    r.removed.add(if root in chain or chain.len == 0 and root notin preBootstrap:
                    root
                  else: root & " (emptied of the add-on's state; the " &
                    "directory was there before the add-on and stays)")
    for e in evidence: r.removed.add(e & " (store evidence)")
  except OSError as ex:
    r.errors.add(root & ": " & ex.msg & (if fileExists(ledgerCopy):
      "; the ledger copy " & ledgerCopy & " is kept, so uninstall, run " &
      "again once the cause is cleared, finishes the removal" else: ""))

proc finishEmptyStateRoot*(r: var UninstallResult; root, ledgerCopy: string;
                           tokenPath = stateRemovalTokenPath();
                           identityOf: IdentityOf = stateDirIdentity): bool =
  ## §13 decisions 161 and 165: a re-run after an uninstall that removed
  ## the ledger copy and then could not rmdir one of the add-on's own
  ## directories. Only with the token that uninstall wrote (outside the
  ## state) and no ledger copy: it removes exactly the directories the token
  ## names, deepest first, each by rmdir(2) (so one that holds anything
  ## stays, reported), then the token, and succeeds. False, with nothing
  ## touched, without a token or with a ledger copy: the uninstall then
  ## proceeds, or refuses on the missing ledger, as before -- a host that
  ## never had the add-on, or whose pre-bootstrap directories an earlier
  ## uninstall put back, is never touched.
  if fileExists(ledgerCopy): return false
  when mutated("state-removal-token-not-required"):
    # FALSIFIER: any tree of empty directories is removed, token or not.
    if not recExists(tokenPath):
      if symlinkExists(root) or not dirExists(root) or
          not holdsOnlyEmptyDirs(root): return false
      var all: seq[string]
      for p in walkDirRec(root, yieldFilter = {pcDir}): all.add(p)
      all.add(root)
      all.sort(proc (a, b: string): int = cmp(b.len, a.len))
      discard removeChain(all)
      r.removed.add(root & " (left empty by an earlier uninstall)")
      return true
  if not recExists(tokenPath): return false
  when mutated("empty-state-root-left-unfinished"):
    return false   # FALSIFIER: the re-run stops on the missing ledger
  result = true
  let t = readStateRemovalToken(tokenPath, root, identityOf)
  if not t.ok:
    r.errors.add(tokenPath & ": " & t.why & "; nothing was removed")
    return
  let (failed, err, gone) = removeChain(t.chain)
  if failed.len > 0:
    reportEmptyDirsLeft(r, root, failed, err, t.chain)
    return
  try:
    removeTokenDurably(tokenPath)
  except OSError as ex:
    r.errors.add(tokenPath & ": " & ex.msg)
    return
  for d in gone:
    r.removed.add(d & " (left by an earlier uninstall)")

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
                                syncer: DiscardSyncer = syncRemovedObjects;
                                markerWriter: DiscardRecordWriter = atomicRecordWriter): bool =
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
  finishDiscard(r, custody, signer, pending, writer, syncer, markerWriter)
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
  # §13 decisions 161 and 165: an earlier run removed the ledger copy
  # and could not rmdir one of the add-on's own directories; its token says
  # which. Finish that. Without the token nothing is touched here.
  let stateRoot = if opts.stateRoot.len > 0: opts.stateRoot else: StateRoot
  let tokenPath = stateRemovalTokenPath(
    if opts.logDir.len > 0: opts.logDir else: UninstallOverrideDir)
  # The records directory is the one bootstrap made (§13 decision 178,
  # amended): every checked open of it compares its identity with the one
  # recorded in the state.
  bindRecordsDir(parentDir(tokenPath), recordsDirIdentityPath(stateDir))
  defer: unbindRecordsDir(parentDir(tokenPath))
  when not mutated("state-removal-rerun-unwired"):
    if stateDir.startsWith(stateRoot & "/") and
        finishEmptyStateRoot(result, stateRoot, ledgerCopyPath(stateDir),
                             tokenPath):
      return
  let l = readLedger(ledgerCopyPath(stateDir))
  # Pre-bootstrap inputs the add-on took over stay where they are (spec
  # §6.1, §6.4; §13 decision 166): never deleted, never rewritten -- the
  # agent's records are live, and the sequence floor must stay with its
  # kept key, or a manifest this host already accepted would replay on it.
  # Every removal below keeps them; only their mode and owner change,
  # back to what they were, before the ledger copy goes. A changed
  # content-pinned input is drift like any other.
  let pb = preBootstrapInputs(l)
  # A corrupt record of a pre-bootstrap input stops the run before
  # anything is written or removed -- before the store-evidence gate too,
  # so no signed intent is written (§13 decision 166, amended; A11 rounds
  # 17 to 19).
  when not mutated("corrupt-check-after-gate"):
    if refuseCorruptInputs(result, pb, ledgerCopyPath(stateDir)): return
  # The altered store objects kept as evidence go with /var/lib/repro. They
  # are named, and nothing is removed, until the operator says to discard
  # them (having copied them out).
  let custody = if opts.custody.stateDir.len > 0: opts.custody
                else: custodySite(stateDir)
  # Nothing pending before the gate, and an intent after it: an earlier
  # run's intent that carries a valid discard marker, which this run
  # completes and did not write (§13 decision 148).
  let nothingPending = pendingStoreEvidence(custody).len == 0
  var ship = opts.ship
  if ship == nil:
    ship = proc (): tuple[ok: bool; why: string] = shipEvidenceNow(stateDir)
  let gate = storeEvidenceGate(custody, opts, ship,
    overrideDir = parentDir(tokenPath))
  when mutated("corrupt-check-after-gate"):
    # FALSIFIER: the corrupt-record stop after the gate, which may already
    # have written a signed intent.
    if refuseCorruptInputs(result, pb, ledgerCopyPath(stateDir)): return
  let evidenceKept = gate.pending
  let evidenceAtStart = evidenceKept.filterIt(
    fileExists(it) or dirExists(it) or symlinkExists(it))
  result.overrideRecord = gate.overrideRecord
  result.overrideRecordText = gate.overrideRecordText
  result.keepStore = opts.keepStore
  if nothingPending and gate.overrideRecord.len > 0:
    result.resumedIntent = true
    try:
      let hostKey = attestationPublicKeyHex(custody.evidence.attestationKey)
      result.markerKept = validDiscardMarker(custody, gate.overrideRecord,
        gate.overrideRecordText, hostKey, gate.pending).kept
    except CatchableError: discard
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
  for d in pb.drift: result.drift.add(d)
  for n in pb.notes: result.notes.add(n)
  # With the key, every sequence floor stays, later ones too (§13 decision
  # 168): read now, before anything is removed.
  let kept = inputPaths(pb.inputs) & keptFloors(pb.inputs)

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
  # A revert that died before its ledger -- a crash, never replayed --
  # left holds and directories no ledger names. They are claimed exactly as
  # the next ledger write would claim them (``revertHoldEntries``): a hold
  # holding exactly the hold text on a unit this ledger installs, and a
  # directory the revert's own record shows it made
  # (``claimedRevertHoldDirs``), so uninstall does not depend on a replay
  # having run, and never takes an operator's file or directory.
  var lateHoldDirs: seq[LedgerEntry]
  when not mutated("uninstall-ignores-unledgered-holds"):
    block:
      var installed = initHashSet[string]()
      var ledgered = initHashSet[string]()
      for u in byClass[lcUnit]:
        if u.unit.len > 0: installed.incl(u.unit)
      for e in l.entries: ledgered.incl(entryKey(e))
      for e in revertHoldEntries(l.entries, installed, [],
                                 claimedRevertHoldDirs(stateDir)):
        if entryKey(e) in ledgered: continue
        if e.class == lcRevertHold: removeOwned(e, result, driver)
        elif e.class == lcDir: lateHoldDirs.add(e)

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
  # The Evidence sink's configuration and CA stay until the state itself
  # goes, at the end of a run that finished (§13 decision 56): an
  # uninstall left incomplete keeps the outbox with the state, and a re-run
  # must still be able to ship it.
  var sinkFiles: seq[LedgerEntry]
  for f in byClass[lcEtcFile]:
    if f.path in handled:
      continue
    when not mutated("sink-config-removed-in-step-4"):
      if f.path in [EvidenceConfPath, EvidenceSinkCaPath]:
        sinkFiles.add(f)
        continue
    when not mutated("etc-input-rewritten-in-step-4"):
      if f.isPreBootstrapInput:
        continue         # left in place, never rewritten (decision 166)
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
  removeEmptyDirs(byClass[lcDir].filterIt(not it.isPreBootstrapInput) &
                  lateHoldDirs)
  if lateHoldDirs.len > 0:
    # Each removed is recorded ``abandoned`` at once, so an uninstall that
    # fails and keeps its state never claims a ``<unit>.d`` made at that
    # path before its re-run.
    discard claimedRevertHoldDirs(stateDir)
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
  let storeFailed =
    if ReproRoot in kept or StoreRoot in kept:
      # /repro or its store was there before the add-on: emptied, kept.
      removeStore(result, opts.keepStore,
                  remover = proc () = keepingRemoval(ReproRoot, kept, "store"),
                  keptInputs = kept)
    else: removeStore(result, opts.keepStore)
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
  # (§13 decision 81: the completion, before the keys and the state.)
  if completeDiscardBeforeKeys(result, l, stateDir, custody, signer,
                               evidenceKept):
    return
  # What is left goes in an order that keeps the state to the end (A11
  # code review round 12): the secrets ramfs, /run/repro, /etc/repro but
  # the sink's files, the keys, then the sink's files and /etc/repro, and
  # only then /var/lib/repro. A failure at any of them keeps the state,
  # with its ledger copy and the attestation key, so a re-run can finish.
  # Only these steps' own failures count here: a completion that failed
  # has stopped the run above, and one whose record is in place but not
  # yet durable is reported without keeping the state (decision 113).
  let errorsBeforeCleanup = result.errors.len
  let driftBeforeCleanup = result.drift.len
  template keepIfFailed() =
    when not mutated("state-removed-after-root-failure"):
      if result.errors.len > errorsBeforeCleanup or
          result.drift.len > driftBeforeCleanup:
        discard keepStateWhenIncomplete(result, l, stateDir)
        return
  # The secrets ramfs (A7) is unmounted, its plaintext gone, first.
  try:
    releaseRunDir(defaultSecretsLayout())
  except CatchableError as ex:
    result.errors.add(defaultSecretsLayout().runDir & ": " & ex.msg)
  removeRootKeepingInputs(result, "/run/repro", kept, "run")
  keepIfFailed()
  if dirExists("/etc/repro"):
    var sinkPaths: seq[string]
    for f in sinkFiles: sinkPaths.add(f.path)
    try:
      keepingRemoval("/etc/repro", kept & sinkPaths, "etc")
    except OSError as ex:
      result.errors.add("/etc/repro: " & ex.msg)
  keepIfFailed()
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
  keepIfFailed()
  for f in sinkFiles:
    removeOwned(f, result, driver)
  removeRootKeepingInputs(result, "/etc/repro", kept, "etc")
  keepIfFailed()
  # The store evidence directory (§13 decision 47) goes with the state
  # (`/var/lib/repro`), whatever --keep-store says (that keeps `/repro`).
  # Its entries were named, and the uninstall refused, before anything was
  # removed unless the operator passed --discard-store-evidence (above);
  # they were removed, each checked gone, above. One that appeared since
  # is reported with the root, once the root is gone.
  # The state goes last, and within it the ledger copy (§13 decision 150).
  # The pre-bootstrap inputs stay, wherever they are (§13 decisions 165
  # (b) and 166): the token carries every one, so a re-run never rmdirs
  # one, and their mode and owner are put back before the ledger copy
  # goes.
  removeStateRoot(result, stateRoot, ledgerCopyPath(stateDir),
                  evidenceEntries(custodySite(stateDir)),
                  preBootstrap = kept, tokenPath = tokenPath,
                  inputs = pb.inputs)
