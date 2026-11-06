## Custody of the store objects a generation references (ReproOS Add-On
## Mode §13 decisions 46-48; threat model DET-AO-5, G41, G42).
##
## Every store object a generation references -- the static tree, the
## generation-0 files prefixes ``fs.systemFile`` copies from, the add-on's
## binary prefix, the apt closures (union and members) its units bind, the
## build outputs the agent installs, any prefix a unit, drop-in or other
## resource names -- has an EXPECTED digest, its canonical tree digest
## (``repro_local_store.storeTreeDigest``) as the process that realised it
## computed it from the bytes it staged. Expected digests live outside the
## store, root-only, where the path cannot vouch for itself:
##
## * the generations' ledgers (``storePrefix`` ``value``, attested by the
##   generation statement's ``ledgerDigest``);
## * the realisation index (``store-realised``), written by every realiser
##   at the moment it publishes, so an object realised by a switch that
##   never committed (a revert, a refused plan) keeps its digest;
## * an operator's adoption (``store-digests``) for an object realised
##   before custody existed.
##
## Never the receipt inside the path (audit session 2, G2).
##
## A switch checks each object against its expected digest
## (``verifiedDigest``), with a cache keyed by the cheap store signature
## (``storeSignature``: inode, size, times, mode of every entry) so an
## unchanged object is not re-hashed: the cache is root-only state outside
## the store, an entry is written only after a full hash EQUAL to the
## expected digest, and it answers only for that digest -- the verified path
## can neither write it nor change its answer. An object that differs, or
## that store verification quarantined, is RECOVERED (decision 47): moved
## into the root-only, bounded evidence directory (``preserveEvidence``) and
## re-realised from a trusted source, then checked against the expected
## digest again; where no trusted source exists the switch refuses. An
## object of a kind no realiser records a digest for, or (on a host under
## custody, ``custodyHost``) one with no recorded digest, refuses: default
## deny.

import std/[algorithm, os, strutils, tables, times]
from std/posix import nil

import repro_local_store/store

import ./evidence
import ./fingerprint
import ./generation0
import ./ledger
import ./mutations
import ./seams
import ./store_root

type
  StoreObjectKind* = enum
    ## What realised an object, which decides where its trusted bytes come
    ## from when it must be recovered.
    sokStaticTree = "static-tree"    ## the switch, from the plan's bytes
    sokFiles = "files"               ## bootstrap / evidence-enrol, from
                                     ## generation 0's bodies
    sokBinary = "binary"             ## bootstrap, from the pinned binary
    sokAptClosure = "apt-closure"    ## the apt realiser, from lock-pinned
                                     ## ``.deb`` archives
    sokPrefix = "prefix"             ## any other ``prefixes/<pkg>/<ver>``
                                     ## (the agent's build outputs among
                                     ## them, from the manifest's pins)
    sokOther = "other"               ## not a prefix: nothing realises it

  StoreObjectRef* = object
    path*: string
    kind*: StoreObjectKind
    referrer*: string                ## what names it (a resource address)

  CustodySite* = object
    ## Where custody keeps its state. ``custodySite`` is the host's; tests
    ## point everything into a scratch directory.
    stateDir*: string
    storeRoot*: string
    quarantinePath*: string
    adoptedPath*: string
    realisedPath*: string
    cachePath*: string
    evidenceDir*: string
    custodyPath*: string
    evidence*: EvidenceSite
    noWrites*: bool
      ## A plan: the cache is consulted, never written.

  CustodyVerdict* = enum
    cvVerified, cvUnverifiable, cvAltered

  CustodyCheck* = object
    path*: string
    verdict*: CustodyVerdict
    expected*: string
    observed*: string

const
  StoreRealisedName* = "store-realised"
  StoreDigestCacheName* = "store-digest-cache"
  StoreEvidenceName* = "store-evidence"
  StoreCustodyName* = "store-custody"
  StoreEvidenceMaxEntries* = 8
    ## Evidence entries kept; the oldest goes first.
  StoreEvidenceMaxBytes* = 1024'i64 * 1024 * 1024
    ## The bytes the evidence directory may hold; beyond it the oldest
    ## entries keep only their manifest.
  StoreEvidenceMaxAgeDays* = 90
    ## Entries older than this are removed (their DET-AO-5 record left the
    ## host when they were made).

proc custodySite*(stateDir: string; storeRoot = StoreRoot): CustodySite =
  let a = stateDir / "addon"
  CustodySite(stateDir: stateDir, storeRoot: storeRoot,
    quarantinePath: a / "store-quarantine", adoptedPath: a / "store-digests",
    realisedPath: a / StoreRealisedName, cachePath: a / StoreDigestCacheName,
    evidenceDir: a / StoreEvidenceName, custodyPath: a / StoreCustodyName,
    evidence: defaultSite(stateDir))

proc withEvidence*(site: CustodySite; e: EvidenceSite): CustodySite =
  result = site
  result.evidence = e

# ---------------------------------------------------------------------------
# The cheap signature (no content read).
# ---------------------------------------------------------------------------

proc storeSignature*(dir: string): string =
  ## A cheap signature of the store object at ``dir``: every entry below it
  ## (links not followed) with its type, permissions, size, inode,
  ## modification time and change time, in path order, hashed. No file
  ## content is read. Any write, truncation, rename, mode or owner change
  ## moves the change time (stat(2) ``st_ctime``), which no unprivileged
  ## call sets and root sets only by moving the system clock; an object
  ## replaced by another gets a new inode.
  var lines: seq[string]
  proc one(rel, path: string) =
    let i = getFileInfo(path, followSymlink = false)
    lines.add(rel & "\t" & $i.kind & "\t" & $i.permissions & "\t" & $i.size &
      "\t" & $i.id.device & ":" & $i.id.file & "\t" &
      $i.lastWriteTime.toUnix & "." & $i.lastWriteTime.nanosecond & "\t" &
      $i.creationTime.toUnix & "." & $i.creationTime.nanosecond)
  one(".", dir)
  for rel in walkDirRec(dir, yieldFilter = {pcFile, pcDir, pcLinkToFile,
                                             pcLinkToDir},
                        followFilter = {pcDir}, relative = true):
    one(rel, dir / rel)
  lines.sort()
  sha256Hex(lines.join("\n"))

# ---------------------------------------------------------------------------
# Root-only tables: ``<path>\t<field>...`` per line, rewritten whole.
# ---------------------------------------------------------------------------

proc readTable(path: string; fields: int): Table[string, seq[string]] =
  result = initTable[string, seq[string]]()
  try:
    for l in readFile(path).splitLines():
      let p = l.split('\t')
      if p.len == fields + 1 and p[0].len > 0: result[p[0]] = p[1 .. ^1]
  except IOError, OSError:
    discard

proc fsyncPath*(path: string) =
  ## fsync one file or directory by path (opened read-only).
  let fd = posix.open(path.cstring, posix.O_RDONLY or posix.O_CLOEXEC)
  if fd < 0:
    raiseOSError(osLastError(), "open " & path & " to sync it")
  try:
    if posix.fsync(fd) != 0:
      raiseOSError(osLastError(), "fsync " & path)
  finally:
    discard posix.close(fd)

proc syncTreeFiles(root: string) =
  ## Every file and directory under ``root``, and ``root``.
  for path in walkDirRec(root, yieldFilter = {pcFile, pcDir}):
    fsyncPath(path)
  fsyncPath(root)

proc writeTable(path: string; t: Table[string, seq[string]]) =
  ## Durably (fsync, rename, directory fsync): the realisation index may be
  ## the only record of an object's expected digest, and a crash must not
  ## leave it renamed into place empty (A11 review finding 10).
  var keys: seq[string]
  for k in t.keys: keys.add(k)
  keys.sort()
  var text = ""
  for k in keys: text.add(k & "\t" & t[k].join("\t") & "\n")
  createDir(parentDir(path))
  writeFileAtomic(path, text, 0o600)

proc readAdopted*(path: string): Table[string, string] =
  ## ``store-digests``: ``<path> <digest>`` per line (an operator's).
  result = initTable[string, string]()
  try:
    for l in readFile(path).splitLines():
      let p = l.splitWhitespace()
      if p.len == 2: result[p[0]] = p[1]
  except IOError, OSError:
    discard

proc readRealised*(site: CustodySite): Table[string, string] =
  result = initTable[string, string]()
  for k, v in readTable(site.realisedPath, 1): result[k] = v[0]

proc recordRealised*(site: CustodySite; path, digest: string) =
  ## The realiser's record of what it published at ``path``. A path the
  ## index already holds with ANOTHER digest is refused: realisation paths
  ## are content-addressed, so a second, different realisation at one path
  ## means one of the two is not what it claims.
  if digest.len == 0: return
  var t = readTable(site.realisedPath, 1)
  if path in t:
    if t[path][0] == digest: return
    raise newException(IOError, "the store path " & path & " was realised " &
      "with " & t[path][0] & " and now with " & digest)
  t[path] = @[digest]
  writeTable(site.realisedPath, t)

proc forgetRealised*(site: CustodySite; path: string) =
  ## Drop ``path`` from the index (it was moved into the evidence directory
  ## and is about to be realised again, with the digest the ledger expects).
  var t = readTable(site.realisedPath, 1)
  if path in t:
    t.del(path)
    writeTable(site.realisedPath, t)

proc ledgerFiles(stateDir: string): seq[string] =
  ## The current ledger copy, then every retained generation's
  ## (``addon_apply.ledgerCopyPath`` / ``generationLedgerPath``).
  if fileExists(stateDir / "addon-ledger"): result.add(stateDir / "addon-ledger")
  let gens = stateDir / "generations"
  if dirExists(gens):
    var ds: seq[string]
    for kind, d in walkDir(gens):
      if kind == pcDir and fileExists(d / "addon-ledger"): ds.add(d / "addon-ledger")
    ds.sort()
    result.add(ds)

proc recordedDigests*(stateDir: string): Table[string, string] =
  ## The realisation digest every ledger records, keyed by path; the current
  ## copy wins over the retained generations'.
  result = initTable[string, string]()
  for lp in ledgerFiles(stateDir):
    try:
      for e in readLedger(lp).entries:
        if e.class == lcStorePrefix and e.value.len > 0 and
            e.path notin result:
          result[e.path] = e.value
    except CatchableError:
      discard   # an unreadable ledger records nothing

proc expectedDigests*(site: CustodySite): Table[string, string] =
  ## Every expected digest: the ledgers', then the realisation index's, then
  ## an operator's adoption. Never a receipt.
  result = recordedDigests(site.stateDir)
  for k, v in readRealised(site):
    if k notin result: result[k] = v
  for k, v in readAdopted(site.adoptedPath):
    if k notin result: result[k] = v

proc custodyHost*(site: CustodySite): bool =
  ## The host has been under custody since its bootstrap (or since an
  ## operator adopted every object realised before): an object with no
  ## expected digest is then refused, not reported unverifiable.
  fileExists(site.custodyPath)

proc markCustody*(site: CustodySite) =
  createDir(parentDir(site.custodyPath))
  writeFile(site.custodyPath, "store-custody v1\n")
  setFilePermissions(site.custodyPath, {fpUserRead, fpUserWrite})

# ---------------------------------------------------------------------------
# Classification and checking.
# ---------------------------------------------------------------------------

proc classifyStoreObject*(path: string; storeRoot = StoreRoot): StoreObjectKind =
  let base = storeRoot / "prefixes" & "/"
  if not path.startsWith(base): return sokOther
  let segs = path[base.len .. ^1].split('/')
  if segs.len != 2 or segs[0].len == 0 or segs[1].len == 0 or
      segs[0] in [".", ".."] or segs[1] in [".", ".."]:
    return sokOther
  let pkg = segs[0]
  if pkg == StaticTreePackageName: sokStaticTree
  elif pkg == FilesPackage: sokFiles
  elif pkg == BinaryPackage: sokBinary
  elif pkg.startsWith("apt-closure-") or pkg.startsWith("apt-deb-"): sokAptClosure
  else: sokPrefix

proc verifiedDigest*(site: CustodySite; path, expected: string): CustodyCheck =
  ## Whether ``path`` holds the bytes of ``expected``, hashing only when the
  ## cache cannot answer. ``expected`` empty: unverifiable, nothing hashed
  ## beyond what the caller reports.
  result.path = path
  result.expected = expected
  if expected.len == 0:
    result.verdict = cvUnverifiable
    result.observed = if dirExists(path): storeTreeDigest(path) else: "(gone)"
    return
  if not dirExists(path):
    result.verdict = cvAltered
    result.observed = "(gone)"
    return
  let sig = storeSignature(path)
  var cache = readTable(site.cachePath, 2)
  when mutated("custody-cache-ignores-signature"):
    # FALSIFYING BUILD: a cached answer is taken for the path, whatever
    # happened to it since.
    if path in cache and cache[path][1] == expected:
      result.verdict = cvVerified
      result.observed = expected
      return
  else:
    if path in cache and cache[path][0] == sig and cache[path][1] == expected:
      result.verdict = cvVerified
      result.observed = expected
      return
  result.observed = storeTreeDigest(path)
  if result.observed == expected:
    result.verdict = cvVerified
    # Written only for a full hash equal to the expectation, and keyed by
    # the signature taken BEFORE the hash: a change during the hash moves
    # the signature, so the entry can never vouch for later bytes.
    cache[path] = @[sig, expected]
    if not site.noWrites:
      try: writeTable(site.cachePath, cache)
      except CatchableError: discard   # a cache that cannot be written
                                       # only costs a hash next time
  else:
    result.verdict = cvAltered

# ---------------------------------------------------------------------------
# The evidence directory (decision 47).
# ---------------------------------------------------------------------------

proc treeManifest(dir: string): string =
  ## ``<rel>\t<kind>\t<sha256 or link target>`` for every entry: what the
  ## altered tree held, kept even when its bytes are not.
  var lines: seq[string]
  for rel in walkDirRec(dir, yieldFilter = {pcFile, pcDir, pcLinkToFile,
      pcLinkToDir}, followFilter = {pcDir}, relative = true):
    let p = dir / rel
    if symlinkExists(p): lines.add(rel & "\tl\t" & expandSymlink(p))
    elif dirExists(p): lines.add(rel & "\td\t")
    else: lines.add(rel & "\tf\t" & sha256OfFile(p))
  lines.sort()
  lines.join("\n") & "\n"

proc dirBytes(dir: string): int64 =
  for f in walkDirRec(dir, yieldFilter = {pcFile}):
    try: result += getFileSize(f) except OSError: discard

proc entryMadeAt*(entry: string): Time =
  ## The time an evidence entry's name records (``yyyyMMdd'T'HHmmss'Z'``);
  ## its directory's mtime when the name carries none.
  let name = extractFilename(entry)
  try:
    parse(name[0 ..< 16], "yyyyMMdd'T'HHmmss'Z'", utc()).toTime()
  except CatchableError:
    getLastModificationTime(entry)

proc pruneEvidence*(site: CustodySite; now = getTime()) =
  ## Retention (decision 47): at most ``StoreEvidenceMaxEntries`` entries,
  ## none older than ``StoreEvidenceMaxAgeDays``, and no more than
  ## ``StoreEvidenceMaxBytes`` of altered bytes -- beyond it the oldest
  ## entries keep their record and manifest and lose their tree.
  if not dirExists(site.evidenceDir): return
  var entries: seq[string]
  for kind, d in walkDir(site.evidenceDir):
    if kind == pcDir: entries.add(d)
  entries.sort()                          # names start with a UTC stamp
  while entries.len > StoreEvidenceMaxEntries:
    removeDir(entries[0])
    entries.delete(0)
  var kept: seq[string]
  for d in entries:
    # Aged by the UTC stamp its name begins with -- when it was made -- not
    # by the directory's mtime, which removing its tree/ moves (A11 review
    # finding 14).
    let made = when mutated("evidence-aged-by-mtime"):
                 getLastModificationTime(d)
               else: entryMadeAt(d)
    if (now - made).inDays > StoreEvidenceMaxAgeDays: removeDir(d)
    else: kept.add(d)
  var total = 0'i64
  for d in kept:
    if dirExists(d / "tree"): total += dirBytes(d / "tree")
  var i = 0
  while total > StoreEvidenceMaxBytes and i < kept.len:
    let t = kept[i] / "tree"
    if dirExists(t):
      total -= dirBytes(t)
      removeDir(t)
    inc i

proc cRename(a, b: cstring): cint {.importc: "rename", header: "<stdio.h>".}
  ## rename(2): fails (EXDEV) across filesystems instead of copying.

proc asideRoot*(site: CustodySite): string =
  ## Where an altered object is renamed first: inside the store (one
  ## filesystem, so the rename is atomic and instant), never served. A
  ## crash leaves it here, and the next custody pass files it as evidence
  ## (``fileLeftoverAsides``).
  site.storeRoot / "tmp" / "custody-aside"

proc moveAside*(site: CustodySite; path: string; now = getTime()): string =
  ## Rename the object at ``path`` aside (``asideRoot``) and return where.
  createDir(asideRoot(site))
  let stamp = now.utc.format("yyyyMMdd'T'HHmmss'Z'")
  result = asideRoot(site) / (stamp & "-" & extractFilename(parentDir(path)) &
                              "-" & extractFilename(path))
  var n = 1
  let base = result
  while dirExists(result):
    inc n
    result = base & "." & $n
  writeFileAtomic(result & ".from", path & "\n", 0o600)
  moveDir(path, result)        # a directory rename, within the store
  # Both directories, so a crash leaves the object at one name or the
  # other, never neither.
  fsyncPath(asideRoot(site))
  fsyncPath(parentDir(path))

proc fileEvidence*(site: CustodySite; aside, path, expected, observed,
                   why: string; now = getTime()): string =
  ## Turn the altered object renamed aside into a new entry of the evidence
  ## directory (``<UTC stamp>-<package>-<version>/``: ``tree/`` the object as
  ## it was, ``manifest`` its entries' digests, ``record`` what was expected
  ## and found) and return the entry. Root-only (0700), pruned. The evidence
  ## directory is outside the store: a rename where they share a
  ## filesystem, otherwise a copy of at most ``StoreEvidenceMaxBytes`` -- a
  ## larger tree keeps its manifest only (A11 review finding 10).
  createDir(site.evidenceDir)
  setFilePermissions(site.evidenceDir, {fpUserRead, fpUserWrite, fpUserExec})
  pruneEvidence(site, now)
  let stamp = now.utc.format("yyyyMMdd'T'HHmmss'Z'")
  let name = stamp & "-" & extractFilename(parentDir(path)) & "-" &
             extractFilename(path)
  result = site.evidenceDir / name
  var n = 1
  while dirExists(result):
    inc n
    result = site.evidenceDir / (name & "." & $n)
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})
  writeFileAtomic(result / "manifest", treeManifest(aside), 0o600)
  var kept = "tree"
  when mutated("recovery-discards-evidence"):
    # FALSIFYING BUILD: the altered tree is deleted, not kept.
    removeDir(aside)
    kept = "nothing"
  else:
    if cRename(aside.cstring, (result / "tree").cstring) == 0:
      fsyncPath(result)
      fsyncPath(asideRoot(site))
    else:
      # Another filesystem (a btrfs store subvolume): a bounded copy.
      let size = dirBytes(aside)
      when not mutated("evidence-copy-unbounded"):
        if size > StoreEvidenceMaxBytes:
          kept = "manifest only (" & $size & " bytes, over the limit)"
        else:
          copyDirWithPermissions(aside, result / "tree")
          syncTreeFiles(result / "tree")
      else:
        copyDirWithPermissions(aside, result / "tree")
      fsyncPath(result)
      removeDir(aside)
  try: removeFile(aside & ".from") except OSError: discard
  writeFileAtomic(result / "record", "path\t" & path & "\nexpected\t" &
    expected & "\nobserved\t" & observed & "\nwhy\t" & why & "\nat\t" &
    stamp & "\nkept\t" & kept & "\n", 0o600)
  fsyncPath(site.evidenceDir)
  pruneEvidence(site, now)

proc preserveEvidence*(site: CustodySite; path, expected, observed,
                       why: string; now = getTime()): string =
  ## ``moveAside`` and ``fileEvidence`` at once (when nothing serves the
  ## object in between).
  let aside = moveAside(site, path, now)
  fileEvidence(site, aside, path, expected, observed, why, now)

proc markRecorded*(entry: string) =
  ## The entry's DET-AO-5 record is written: nothing to flush for it.
  if entry.len > 0:
    try: writeFileAtomic(entry / "recorded", "", 0o600)
    except CatchableError: discard

proc evidenceEntries*(site: CustodySite): seq[string] =
  if dirExists(site.evidenceDir):
    for kind, d in walkDir(site.evidenceDir):
      if kind == pcDir: result.add(d)
  result.sort()

proc recordRecovered*(site: CustodySite; obj: StoreObjectRef;
                      expected, observed, entry, source: string) =
  ## The DET-AO-5 record of a recovery: the object was altered, its bytes
  ## are kept at ``entry``, and it was re-realised from ``source``.
  discard recordEvidence(EvidenceEvent(detector: edStore,
    category: ecDetection, trigger: "store-recovered",
    fields: @[("path", obj.path), ("kind", $obj.kind),
              ("digest", expected), ("observedDigest", observed),
              ("evidence", entry), ("source", source),
              ("message", obj.path & " no longer held the bytes it was " &
               "realised with; kept at " & entry & " and re-realised from " &
               source)], attest: true), site.evidence)

proc recordRefused*(site: CustodySite; obj: StoreObjectRef;
                    expected, observed, why: string) =
  ## The DET-AO-5 record of an altered object the switch could not recover.
  discard recordEvidence(EvidenceEvent(detector: edStore,
    category: ecDetection, trigger: "store-digest-mismatch",
    fields: @[("path", obj.path), ("kind", $obj.kind),
              ("digest", expected), ("observedDigest", observed),
              ("message", obj.path & " no longer holds the bytes it was " &
               "realised with, and is not recovered: " & why)],
    attest: true), site.evidence)

# ---------------------------------------------------------------------------
# The custody pass a switch runs (decisions 47, 48).
# ---------------------------------------------------------------------------

type
  Recovery* = object
    ## How one altered object is recovered, decided BEFORE anything moves.
    ok*: bool
    why*: string          ## when not ``ok``: why there is no trusted source
    source*: string       ## where the trusted bytes come from (for the record)
    realise*: proc (): string
      ## Re-realise the object at its path from ``source``; returns the
      ## digest of the bytes it staged.
    evictOnRefusal*: bool
      ## Not recoverable now, but moved into the evidence directory anyway,
      ## so the next fetch stages what re-realising it needs (an apt
      ## closure member whose ``.deb`` the apply has no copy of).

  CustodyResult* = object
    refusals*: seq[string]
    unverifiable*: seq[tuple[path, observed: string]]
    recovered*: seq[tuple[path, entry, source: string]]
    verified*: seq[string]

proc custodyOrder(o: StoreObjectRef): int =
  ## Members before the unions built from them: a union's files are hard
  ## links of its members', so a member is recovered first and the union
  ## after it is rebuilt from the recovered member.
  let pkg = extractFilename(parentDir(o.path))
  if pkg.startsWith("apt-deb-"): 0
  elif pkg.startsWith("apt-closure-"): 1
  else: 2

proc fileLeftoverAsides*(site: CustodySite) =
  ## Objects a crashed recovery renamed aside and never filed: each becomes
  ## an evidence entry and a DET-AO-5 record now, so the alteration is never
  ## lost to the crash (A11 review finding 10).
  if not dirExists(asideRoot(site)) or mutated("custody-ignores-leftovers"):
    return
  for kind, d in walkDir(asideRoot(site)):
    if kind != pcDir: continue
    let path = try: readFile(d & ".from").strip() except CatchableError: ""
    let entry = fileEvidence(site, d, (if path.len > 0: path else: d), "",
      storeTreeDigest(d), "kept after a recovery interrupted by a crash")
    discard recordEvidence(EvidenceEvent(detector: edStore,
      category: ecDetection, trigger: "store-recovery-interrupted",
      fields: @[("path", path), ("evidence", entry),
                ("message", path & ": a recovery was interrupted; the " &
                 "altered object is kept at " & entry)], attest: true),
      site.evidence)
    markRecorded(entry)

proc flushUnrecorded*(site: CustodySite) =
  ## Entries a crash left without their DET-AO-5 record (filed, the record
  ## not yet written): written now.
  if mutated("custody-skips-unrecorded"): return
  for entry in evidenceEntries(site):
    if fileExists(entry / "recorded") or not fileExists(entry / "record"):
      continue
    var path, expected, observed = ""
    for l in readFile(entry / "record").splitLines():
      let p = l.split('\t', 1)
      if p.len == 2:
        case p[0]
        of "path": path = p[1]
        of "expected": expected = p[1]
        of "observed": observed = p[1]
        else: discard
    let ok = expected.len > 0 and dirExists(path) and
             storeTreeDigest(path) == expected
    discard recordEvidence(EvidenceEvent(detector: edStore,
      category: ecDetection,
      trigger: (if ok: "store-recovered" else: "store-digest-mismatch"),
      fields: @[("path", path), ("digest", expected),
                ("observedDigest", observed), ("evidence", entry),
                ("message", path & (if ok: " was recovered" else:
                 " was moved aside and is not recovered") &
                 "; its record was interrupted by a crash")], attest: true),
      site.evidence)
    markRecorded(entry)

proc custodyPass*(site: CustodySite; objects: openArray[StoreObjectRef];
                  recover: proc (o: StoreObjectRef): Recovery;
                  mayRecover: bool): CustodyResult =
  ## Check every object against its expected digest; recover what is
  ## altered (``mayRecover``: a plan only reports), refuse what has no
  ## trusted source, no digest on a host under custody, or no realiser.
  var objs = @objects
  objs.sort(proc (a, b: StoreObjectRef): int =
    result = cmp(custodyOrder(a), custodyOrder(b))
    if result == 0: result = cmp(a.path, b.path))
  var seen: seq[string]
  if mayRecover and not site.noWrites:
    fileLeftoverAsides(site)
    flushUnrecorded(site)
  let expectedAll = expectedDigests(site)
  let custody = custodyHost(site)
  for o in objs:
    if o.path in seen: continue
    seen.add(o.path)
    if o.kind == sokOther:
      result.refusals.add(o.path & " (named by " & o.referrer & ") is not " &
        "a store prefix: nothing realises it, so nothing records its digest")
      continue
    let quarantined = o.path in readStoreQuarantine(site.quarantinePath)
    let expected = expectedAll.getOrDefault(o.path, "")
    if expected.len == 0 and not dirExists(o.path):
      # An apt closure member is realised afresh from its lock-pinned
      # archive (a realisation, recorded as one); anything else is refused.
      if o.kind == sokAptClosure and mayRecover:
        let r = recover(o)
        if r.ok:
          try:
            let d = r.realise()
            if d.len > 0 and dirExists(o.path) and storeTreeDigest(o.path) == d:
              recordRealised(site, o.path, d)
              result.verified.add(o.path)
              continue
          except CatchableError as e:
            result.refusals.add(o.path & " (named by " & o.referrer &
              ") does not exist, and realising it failed: " & e.msg)
            continue
      result.refusals.add(o.path & " (named by " & o.referrer & ") does not " &
        "exist, and no realisation records a digest to recover it to")
      continue
    var chk = verifiedDigest(site, o.path, expected)
    if quarantined and chk.verdict == cvVerified:
      # Verification saw other bytes there. The cache is not asked: only a
      # full hash equal to the recorded digest -- a realiser published it
      # again since (a recovery the fetch had to stage for), or its bytes
      # are back -- takes it out of the quarantine.
      if storeTreeDigest(o.path) == expected:
        releaseStoreQuarantine(o.path, site.quarantinePath)
      else:
        chk.verdict = cvAltered
    case chk.verdict
    of cvVerified:
      result.verified.add(o.path)
    of cvUnverifiable:
      when mutated("custody-admits-undigested"):
        result.unverifiable.add((o.path, chk.observed))
      else:
        if custody:
          result.refusals.add(o.path & " (named by " & o.referrer & ") has " &
            "no realisation digest recorded outside the store; on a host " &
            "under store custody that is refused (default deny)")
        else:
          result.unverifiable.add((o.path, chk.observed))
    of cvAltered:
      if not mayRecover:
        result.refusals.add(o.path & " no longer holds the bytes it was " &
          "realised with (" & chk.observed & ", expected " & expected &
          "); the switch would recover it")
        continue
      let r = recover(o)
      if not r.ok:
        var entry = ""
        if r.evictOnRefusal and dirExists(o.path):
          entry = preserveEvidence(site, o.path, expected, chk.observed, r.why)
        else:
          quarantineStorePath(o.path, site.quarantinePath)
        recordRefused(site, o, expected, chk.observed, r.why &
          (if entry.len > 0: "; kept at " & entry else: ""))
        markRecorded(entry)
        result.refusals.add(o.path & " no longer holds the bytes it was " &
          "realised with and is not recovered: " & r.why &
          (if entry.len > 0: " (kept at " & entry & ")" else: ""))
        continue
      # The expected digest is KEPT until the replacement is verified (the
      # realisation index may be its only record; finding 10).
      when mutated("custody-forgets-before-rebuild"):
        forgetRealised(site, o.path)
      # Renamed aside within the store first (atomic); a crash before it is
      # filed leaves it there, and the next pass files it
      # (``fileLeftoverAsides``).
      let aside = if dirExists(o.path): moveAside(site, o.path) else: ""
      seamPause(site.stateDir, "custody-after-move-aside")
      let entry = if aside.len > 0:
                    fileEvidence(site, aside, o.path, expected, chk.observed,
                                 "altered; recovered from " & r.source)
                  else: ""
      var again = ""
      try:
        again = r.realise()
      except CatchableError as e:
        quarantineStorePath(o.path, site.quarantinePath)
        recordRefused(site, o, expected, chk.observed, "re-realising it " &
          "from " & r.source & " failed: " & e.msg)
        markRecorded(entry)
        result.refusals.add(o.path & ": re-realising it from " & r.source &
          " failed: " & e.msg)
        continue
      let now = if dirExists(o.path): storeTreeDigest(o.path) else: "(gone)"
      if again != expected or now != expected:
        quarantineStorePath(o.path, site.quarantinePath)
        recordRefused(site, o, expected, now, "re-realised from " & r.source &
          " it hashes to " & now & " (staged " & again & "), not the " &
          "recorded digest")
        markRecorded(entry)
        result.refusals.add(o.path & ": re-realised from " & r.source &
          ", it hashes to " & now & ", not " & expected)
        continue
      recordRealised(site, o.path, expected)
      seamPause(site.stateDir, "custody-before-record")
      # Recorded only now that the recovery is done, then the quarantine
      # goes; a crash in between leaves the entry unrecorded, which the next
      # pass records (``flushUnrecorded``).
      recordRecovered(site, o, expected, chk.observed, entry, r.source)
      markRecorded(entry)
      releaseStoreQuarantine(o.path, site.quarantinePath)
      result.recovered.add((o.path, entry, r.source))
