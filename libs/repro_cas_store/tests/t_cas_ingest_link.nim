## Local-CAS-Hardlink-Materialization M2 — tests for path-based CAS
## ingest (``casPutPath`` / ``storeCasFileBlobDetailed``).
##
## Spec: ``reprobuild-specs/Local-Content-Addressed-Store.md``
##       §"Hardlink, Reflink, and Copy Policy" (normative).
##
## Four things are under test and they are not the same thing:
##
##   1. **A blob is still a blob.** The digest, the on-disk layout and the
##      read path did not move. A blob ingested by adopting a file must be
##      indistinguishable from one ingested through ``casPut``'s
##      ``openArray[byte]`` — same digest, byte-identical on disk — or an
##      existing store stops being readable.
##   2. **Which mechanism is used.** Asserted on the per-call
##      ``CasPutPathOutcome.mechanism``, never on timing and never on "it
##      felt fast". The host's real volumes decide which arms can be
##      exercised; an arm the host cannot supply announces via
##      ``checkpoint`` rather than silently passing.
##   3. **The hash→link race.** The destination name is the digest, so
##      ingest cannot link into its final name in one pass. Whatever
##      happens to the source in the window between reading it and
##      committing it, the bytes stored MUST hash to the name they are
##      stored under. Driven deterministically through
##      ``casIngestRaceWindowHook`` — a seam, not a sleep.
##   4. **The hardlink arm is OFF.** An ingested hardlink makes the build
##      tree's output and the CAS blob one inode, so a later rebuild that
##      rewrites the output in place rewrites the store. Both halves are
##      measured: the default really declines, and the arm really works
##      (and really is hazardous) when a caller opts in.

import std/[os, sequtils, strutils, unittest]

import blake3
from repro_core/paths import extendedPath

import repro_cas_store

# ---------------------------------------------------------------------------
# Host volume discovery — the same approach M0's and M1's tests use, because
# the answer genuinely differs per volume on this workspace (ReFS store,
# NTFS %TEMP%).
# ---------------------------------------------------------------------------

type
  ProbeVolume = object
    dir: string       ## A writable scratch directory on the volume.
    fsName: string    ## Diagnostic only — never an input to a decision.
    pairKey: string
    reflink: bool
    hardlink: bool

var scratchDirs: seq[string] = @[]

proc claimScratchDir(parent: string; tag: string): string =
  if parent.len == 0 or not dirExists(extendedPath(parent)):
    return ""
  let candidate = parent / ("repro-m2-" & $getCurrentProcessId() & "-" & tag)
  try:
    createDir(extendedPath(candidate))
    let witness = candidate / "witness"
    writeFile(extendedPath(witness), "ok")
    removeFile(extendedPath(witness))
  except CatchableError, Defect:
    return ""
  scratchDirs.add(candidate)
  candidate

proc candidateParents(): seq[string] =
  result = @[getTempDir()]
  when defined(windows):
    for letter in 'A' .. 'Z':
      result.add($letter & ":\\")
  else:
    for p in ["/tmp", "/var/tmp", "/dev/shm", getHomeDir()]:
      result.add(p)
  result.add(currentSourcePath().parentDir())

proc discoverVolumes(): seq[ProbeVolume] =
  result = @[]
  var seenKeys: seq[string] = @[]
  var tag = 0
  for parent in candidateParents():
    if parent.len == 0 or not dirExists(extendedPath(parent)):
      continue
    let key = filesystemPairKey(parent, parent)
    if key in seenKeys:
      continue
    let dir = claimScratchDir(parent, "vol" & $tag)
    tag.inc
    if dir.len == 0:
      continue
    seenKeys.add(key)
    var cache: LinkCapabilityCache
    let cap = probeLinkCapabilities(cache, dir, dir)
    result.add(ProbeVolume(dir: dir, fsName: filesystemName(dir),
                           pairKey: filesystemPairKey(dir, dir),
                           reflink: cap.reflink, hardlink: cap.hardlink))

let volumes = discoverVolumes()

proc describeHost(): string =
  volumes.mapIt(it.dir & "(" & it.fsName & " reflink=" & $it.reflink &
                " hardlink=" & $it.hardlink & ")").join(", ")

proc primaryVolume(): ProbeVolume =
  doAssert volumes.len > 0,
    "no writable scratch directory could be created on this host; " &
    "casPutPath's mechanism arms cannot be exercised at all"
  volumes[0]

proc reflinkVolume(): seq[ProbeVolume] =
  volumes.filterIt(it.reflink)

proc hardlinkOnlyVolume(): seq[ProbeVolume] =
  ## A volume where a hardlink is available and a reflink is not, so the
  ## hardlink arm can be reached without the (preferred, safer) reflink arm
  ## winning first.
  volumes.filterIt(it.hardlink and not it.reflink)

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

var caseSerial = 0

proc caseDir(vol: ProbeVolume; tag: string): string =
  caseSerial.inc
  result = vol.dir / (tag & "-" & $caseSerial)
  removeDir(extendedPath(result))
  createDir(extendedPath(result))

proc payloadOf(size: int; seed: int): seq[byte] =
  ## Deliberately includes 0x00 bytes and spans more than one cluster so a
  ## reflink exercises real extent duplication.
  result = newSeq[byte](size)
  for i in 0 ..< size:
    result[i] = byte((i * 131 + seed * 17) and 0xFF)

proc textOfBytes(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc readBytes(path: string): seq[byte] =
  let raw = readFile(extendedPath(path))
  result = newSeq[byte](raw.len)
  for i, ch in raw:
    result[i] = byte(ord(ch))

proc writeSource(path: string; payload: openArray[byte]) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), textOfBytes(payload))

proc writeSourceStreamed(path: string; sizeBytes: int; seed: int) =
  ## The same bytes ``writeSource(path, payloadOf(sizeBytes, seed))`` would
  ## write, built in bounded chunks so the FIXTURE's own peak is a chunk
  ## rather than the payload.
  ##
  ## This exists for the memory guard below and it is load-bearing there.
  ## ``getMaxMem`` reports a high-water mark that never falls, so every byte
  ## the fixture allocates before the measurement starts becomes headroom
  ## the measurement silently grants to the thing under test. Building the
  ## file the obvious way allocates the payload seq AND a whole string copy
  ## of it — about 2x the payload — so an ingest that read the entire file
  ## into memory would still report ``grew == 0`` and pass. The guard would
  ## then be measuring nothing at all.
  createDir(extendedPath(parentDir(path)))
  const ChunkSize = 256 * 1024
  var f = open(extendedPath(path), fmWrite)
  try:
    var buffer = newString(ChunkSize)
    var written = 0
    while written < sizeBytes:
      let n = min(ChunkSize, sizeBytes - written)
      for i in 0 ..< n:
        buffer[i] = char(((written + i) * 131 + seed * 17) and 0xFF)
      doAssert f.writeBuffer(addr buffer[0], n) == n
      written += n
  finally:
    try: f.close() except CatchableError: discard

proc digestOf(payload: openArray[byte]): ContentHash =
  toContentHash(blake3.digest(payload))

proc blobIsSelfConsistent(cas: CasStore; hash: ContentHash): bool =
  ## The one invariant no arm may ever break: the bytes on disk hash to the
  ## name they are filed under.
  let path = cas.casPath(hash)
  if not fileExists(extendedPath(path)):
    return false
  digestOf(readBytes(path)) == hash

proc ingestBody(): string =
  ## The CODE of ``storeCasFileBlobDetailed`` with its doc comment
  ## stripped, so a structural assertion measures what the proc does rather
  ## than what its documentation says about it.
  let src = currentSourcePath().parentDir().parentDir().parentDir() /
    "repro_local_store" / "src" / "repro_local_store" / "store.nim"
  doAssert fileExists(extendedPath(src)), src & " not found"
  let text = readFile(extendedPath(src))
  let start = text.find("proc storeCasFileBlobDetailed*")
  doAssert start >= 0, "storeCasFileBlobDetailed not found in " & src
  let stop = text.find("\nproc storeCasFileBlob*", start)
  doAssert stop > start, "end of storeCasFileBlobDetailed not found"
  var kept: seq[string] = @[]
  for line in text[start ..< stop].splitLines():
    if line.strip().startsWith("##"):
      continue
    kept.add(line)
  kept.join("\n")

proc stagingDebris(storeRoot: string): seq[string] =
  ## Anything the ingest left behind in the store's staging area.
  result = @[]
  let tmpRoot = storeRoot / "tmp"
  if not dirExists(extendedPath(tmpRoot)):
    return
  for kind, path in walkDir(extendedPath(tmpRoot)):
    result.add(path)

proc replaceSourceInPlace(path: string; payload: openArray[byte]) =
  ## Simulate the racing writer the hash→link window is exposed to, the way
  ## a real build step does it: write a NEW file and move it over the old
  ## name. The replacement's file id is allocated while the original still
  ## holds its own, so the two identities necessarily differ — which makes
  ## the witness comparison deterministic instead of dependent on the
  ## host's filesystem timestamp granularity.
  let replacement = path & ".racing-writer"
  writeFile(extendedPath(replacement), textOfBytes(payload))
  removeFile(extendedPath(path))
  moveFile(extendedPath(replacement), extendedPath(path))

proc clearIngestHook() =
  casIngestRaceWindowHook = nil

# ---------------------------------------------------------------------------
# Memory. Deliberately the FIRST suite in the file: ``getMaxMem`` is a
# high-water mark that never falls, so the delta it reports is only
# meaningful while the program's ceiling is still low.
# ---------------------------------------------------------------------------

suite "M2 casPutPath — bounded work":
  test "ingest never holds the payload in memory":
    let vol = primaryVolume()
    let dir = caseDir(vol, "mem")
    var cas = openCasStore(dir / "store")
    defer: cas.close()

    const PayloadSize = 32 * 1024 * 1024
    const Budget = PayloadSize div 4
    let src = dir / "src" / "big.bin"
    # Written in bounded chunks, NOT as one 32 MiB payload: the fixture's
    # own allocation would otherwise raise ``getMaxMem``'s high-water mark
    # by roughly 2x the payload before the measurement even begins, leaving
    # the budget below with more slack than it reads. See
    # ``writeSourceStreamed``.
    writeSourceStreamed(src, PayloadSize, 2)

    GC_fullCollect()
    let before = getMaxMem()
    let outcome = cas.casPutPathDetailed(src)
    let grew = getMaxMem() - before
    checkpoint("ingested " & $PayloadSize & " bytes via " &
               $outcome.mechanism & "; heap high-water grew by " & $grew &
               " bytes (budget " & $Budget & ", fixture peak bounded at " &
               "256 KiB)")
    check grew < Budget
    # ...and the bytes are still right, so the bound was not bought by not
    # doing the work.
    check getFileSize(extendedPath(cas.casPath(outcome.hash))) ==
      int64(PayloadSize)
    check cas.blobIsSelfConsistent(outcome.hash)

  test "ingest does not reacquire a whole-payload API":
    # A structural guard on the property the timing-free test above
    # measures: the ingest seam must not start reading whole files.
    let body = ingestBody()
    check "seq[seq[byte]]" notin body
    check "readFile" notin body
    check "writeFile" notin body

  test "a successful ingest leaves no staging debris under tmp/":
    let vol = primaryVolume()
    let dir = caseDir(vol, "debris")
    let storeRoot = dir / "store"
    var cas = openCasStore(storeRoot)
    defer: cas.close()
    for i in 0 ..< 5:
      let src = dir / "src" / ("f" & $i & ".bin")
      writeSource(src, payloadOf(4096 + i, i))
      let h = cas.casPutPath(src)
      check cas.casGet(h) == payloadOf(4096 + i, i)
    check stagingDebris(storeRoot).len == 0

# ---------------------------------------------------------------------------

suite "M2 casPutPath — a blob is still a blob":
  test "a path-ingested blob has the same digest as the byte-ingested one":
    let vol = primaryVolume()
    let dir = caseDir(vol, "same-digest")
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let payload = payloadOf(70 * 1024 + 13, 101)
    let src = dir / "src" / "payload.bin"
    writeSource(src, payload)
    let viaBytes = cas.casPut(payload)
    let viaPath = cas.casPutPathDetailed(src)
    check viaPath.hash == viaBytes
    # The second ingest of content the store already holds commits nothing.
    check viaPath.alreadyPresent
    check $viaPath.hash == $digestOf(payload)

  test "a path-ingested blob is byte-identical on disk to the byte-ingested one":
    ## Two independent stores, so neither call can be satisfied by the
    ## other's blob. The on-disk file itself is compared, not merely the
    ## digest, because "the digest matched" would still hold if the layout
    ## or the framing had moved.
    let vol = primaryVolume()
    let dir = caseDir(vol, "identical")
    let payload = payloadOf(33 * 1024 + 7, 103)
    let src = dir / "src" / "payload.bin"
    writeSource(src, payload)

    var byteStore = openCasStore(dir / "store-bytes")
    let byteHash = byteStore.casPut(payload)
    let bytePath = byteStore.casPath(byteHash)
    let byteBlob = readBytes(bytePath)
    let byteRelative = bytePath.replace(dir / "store-bytes", "")
    byteStore.close()

    var pathStore = openCasStore(dir / "store-path")
    let pathOutcome = pathStore.casPutPathDetailed(src)
    let pathBlob = pathStore.casPath(pathOutcome.hash)
    let pathRelative = pathBlob.replace(dir / "store-path", "")
    checkpoint("ingested via " & $pathOutcome.mechanism & " " &
               pathOutcome.diagnostic)
    check pathOutcome.hash == byteHash
    check readBytes(pathBlob) == byteBlob
    check readBytes(pathBlob) == payload
    # Same shard, same filename — the layout did not move either.
    check pathRelative == byteRelative
    pathStore.close()

  test "an ingested blob reads back through the unchanged read path":
    let vol = primaryVolume()
    let dir = caseDir(vol, "readback")
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let payload = payloadOf(9 * 1024, 107)
    let src = dir / "src" / "payload.bin"
    writeSource(src, payload)
    let h = cas.casPutPath(src)
    # ``casGet`` verifies the digest before returning, and ``casVerify``
    # re-reads: both are the pre-M2 read path, untouched.
    check cas.casGet(h) == payload
    check cas.casVerify(h)
    check cas.casExists(h)

  test "ingesting the same path twice is idempotent and reports alreadyPresent":
    let vol = primaryVolume()
    let dir = caseDir(vol, "idempotent")
    let storeRoot = dir / "store"
    var cas = openCasStore(storeRoot)
    defer: cas.close()
    let payload = payloadOf(5000, 109)
    let src = dir / "src" / "payload.bin"
    writeSource(src, payload)
    let first = cas.casPutPathDetailed(src)
    let second = cas.casPutPathDetailed(src)
    check first.hash == second.hash
    check not first.alreadyPresent
    check second.alreadyPresent
    check cas.casGet(second.hash) == payload
    check stagingDebris(storeRoot).len == 0

# ---------------------------------------------------------------------------

suite "M2 casPutPath — mechanism selection":
  test "a source on a reflink-capable store volume is cloned, not copied":
    let vols = reflinkVolume()
    if vols.len == 0:
      checkpoint("no volume on this host implements reflink (" &
                 describeHost() & "); the ingest reflink arm was NOT " &
                 "exercised")
      check volumes.len >= 1
    else:
      let vol = vols[0]
      let dir = caseDir(vol, "reflink")
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      let payload = payloadOf(64 * 1024, 3)
      let src = dir / "src" / "out.bin"
      writeSource(src, payload)
      let outcome = cas.casPutPathDetailed(src)
      checkpoint(vol.dir & " fs=" & vol.fsName & " -> " &
                 $outcome.mechanism & " " & outcome.diagnostic)
      check outcome.mechanism == lmReflink
      check not outcome.perFileFallback
      check not outcome.sourceChanged
      check outcome.hash == digestOf(payload)
      check readBytes(cas.casPath(outcome.hash)) == payload
      # A clone is its own inode. That is the whole reason this arm needs
      # no guard rail at all: nothing is shared that a write could reach.
      check hardlinkCount(src) == 1
      check hardlinkCount(cas.casPath(outcome.hash)) == 1

  test "a cloned blob is isolated from later writes to the source":
    ## The property that lets the reflink arm be on by default while the
    ## hardlink arm is off. The build tree still owns the source and will
    ## overwrite it on the next rebuild; the store must not notice.
    let vols = reflinkVolume()
    if vols.len == 0:
      checkpoint("no reflink-capable volume on this host (" &
                 describeHost() & "); the COW isolation arm was NOT " &
                 "exercised")
      check volumes.len >= 1
    else:
      let vol = vols[0]
      let dir = caseDir(vol, "cow")
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      let payload = payloadOf(48 * 1024, 5)
      let src = dir / "src" / "out.bin"
      writeSource(src, payload)
      let outcome = cas.casPutPathDetailed(src)
      check outcome.mechanism == lmReflink
      # A rebuild rewrites the output in place.
      writeFile(extendedPath(src), repeat('x', 48 * 1024))
      check cas.casVerify(outcome.hash)
      check cas.casGet(outcome.hash) == payload

  test "reflink wins over hardlink even when the hardlink arm is allowed":
    ## The preference order is a SAFETY order: a reflink is both cheaper
    ## than a copy and safer than a hardlink, so opting into shared inodes
    ## must not demote it. On the ingest side the stakes are higher than on
    ## the restore side — a hardlinked blob would be a second name for a
    ## file the build tree still owns.
    let vols = reflinkVolume().filterIt(it.hardlink)
    if vols.len == 0:
      checkpoint("no volume on this host supports BOTH mechanisms (" &
                 describeHost() & "); the ordering arm was NOT exercised")
      check volumes.len >= 1
    else:
      let vol = vols[0]
      let dir = caseDir(vol, "order")
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      let payload = payloadOf(32 * 1024, 5)
      let src = dir / "src" / "out.bin"
      writeSource(src, payload)
      let outcome = cas.casPutPathDetailed(src, allowSharedInode = true)
      check outcome.mechanism == lmReflink
      check hardlinkCount(src) == 1
      check hardlinkCount(cas.casPath(outcome.hash)) == 1
      check cas.casGet(outcome.hash) == payload

  test "the hardlink arm is OFF by default on a hardlink-capable pair":
    let vols = hardlinkOnlyVolume()
    if vols.len == 0:
      checkpoint("no hardlink-capable volume without reflink on this host (" &
                 describeHost() & "); the default-off arm was NOT exercised " &
                 "against a pair that could have hardlinked")
      check volumes.len >= 1
    else:
      let vol = vols[0]
      let dir = caseDir(vol, "defaultoff")
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      let payload = payloadOf(16 * 1024, 7)
      let src = dir / "src" / "out.bin"
      writeSource(src, payload)
      let outcome = cas.casPutPathDetailed(src)
      checkpoint(vol.dir & " fs=" & vol.fsName & " -> " &
                 $outcome.mechanism & " " & outcome.diagnostic)
      # The pair CAN hardlink; the default declines to, and says so.
      check vol.hardlink
      check outcome.mechanism == lmCopy
      check "shared-inode" in outcome.diagnostic
      check "hardlink=true" in outcome.diagnostic
      check hardlinkCount(src) == 1
      check hardlinkCount(cas.casPath(outcome.hash)) == 1
      # The mutation hazard is therefore absent by default: the build tree
      # rewriting its own output does not touch the store. M3 generalised
      # this to every arm the defaults can select.
      writeFile(extendedPath(src), repeat('z', 16 * 1024))
      check cas.casVerify(outcome.hash)
      check cas.casGet(outcome.hash) == payload

  test "the ingest default is expressed as a named constant, not a literal":
    # M2 made this a named constant so M3's answer would be one reviewable
    # line, exactly as M1's did. M3's answer is that BOTH stay false, so
    # the watch now guards a settled decision; the evidence is in
    # ``t_cas_link_mutation_safety.nim``.
    check CasIngestAllowSharedInodeDefault == false
    check CasMaterializeAllowSharedInodeDefault == false

  test "allowSharedInode = true reaches the hardlink arm and shares an inode":
    let vols = hardlinkOnlyVolume()
    if vols.len == 0:
      checkpoint("no hardlink-capable volume without reflink on this host (" &
                 describeHost() & "); the ingest hardlink arm was NOT " &
                 "exercised")
      check volumes.len >= 1
    else:
      let vol = vols[0]
      let dir = caseDir(vol, "hardlink")
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      let payload = payloadOf(16 * 1024, 11)
      let src = dir / "src" / "out.bin"
      writeSource(src, payload)
      let outcome = cas.casPutPathDetailed(src, allowSharedInode = true)
      check outcome.mechanism == lmHardlink
      check outcome.hash == digestOf(payload)
      check readBytes(cas.casPath(outcome.hash)) == payload
      # One inode, two names — the win, and precisely the hazard that keeps
      # this arm off. A rebuild that rewrites the output in place rewrites
      # the store's blob, which then no longer hashes to its own name.
      check hardlinkCount(src) == 2
      check hardlinkCount(cas.casPath(outcome.hash)) == 2
      writeFile(extendedPath(src), repeat('y', 16 * 1024))
      check not cas.casVerify(outcome.hash)

  test "a cross-volume source falls back to copy with correct bytes":
    if volumes.len < 2:
      checkpoint("only one writable volume was discoverable on this host (" &
                 describeHost() & "); the cross-device arm was NOT exercised")
      check volumes.len >= 1
    else:
      let storeVol = volumes[0]
      let srcVol = volumes[1]
      check storeVol.pairKey != srcVol.pairKey
      let storeDir = caseDir(storeVol, "xdev-store")
      let srcDir = caseDir(srcVol, "xdev-src")
      var cas = openCasStore(storeDir / "store")
      defer: cas.close()
      let payload = payloadOf(48 * 1024, 13)
      let src = srcDir / "out.bin"
      writeSource(src, payload)
      # Even opting into shared inodes cannot produce one across a device
      # boundary, so this also proves the fallback is driven by the
      # operation's own refusal rather than by the opt-out.
      let outcome = cas.casPutPathDetailed(src, allowSharedInode = true)
      checkpoint(srcVol.dir & " (" & srcVol.fsName & ") -> " &
                 storeVol.dir & " (" & storeVol.fsName & "): " &
                 $outcome.mechanism & " " & outcome.diagnostic)
      check outcome.mechanism == lmCopy
      check "different filesystem" in outcome.diagnostic
      check "loCrossDevice" in outcome.diagnostic
      check outcome.hash == digestOf(payload)
      check cas.casGet(outcome.hash) == payload
      check hardlinkCount(cas.casPath(outcome.hash)) == 1

# ---------------------------------------------------------------------------

suite "M2 casPutPath — the hash→link race":
  test "the reflink arm hashes the staged clone, not the source":
    ## Structural, and load-bearing: hashing the SOURCE and then cloning it
    ## would reopen the window this arm closes by construction. A clone is
    ## a copy-on-write snapshot, so digesting the clone digests exactly the
    ## bytes that get committed.
    let body = ingestBody()
    check "streamHashPath(stagePath)" in body
    check "sameFileIdentity(sourceBefore, afterHash)" in body

  test "a writer racing the reflink arm cannot mis-digest the blob":
    let vols = reflinkVolume()
    if vols.len == 0:
      checkpoint("no reflink-capable volume on this host (" &
                 describeHost() & "); the clone-snapshot race was NOT " &
                 "exercised")
      check volumes.len >= 1
    else:
      let vol = vols[0]
      let dir = caseDir(vol, "race-reflink")
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      let original = payloadOf(24 * 1024, 17)
      let racing = payloadOf(24 * 1024, 19)
      check original.len == racing.len
      let src = dir / "src" / "out.bin"
      writeSource(src, original)
      defer: clearIngestHook()
      casIngestRaceWindowHook = proc (p: string) {.closure.} =
        replaceSourceInPlace(p, racing)
      let outcome = cas.casPutPathDetailed(src)
      clearIngestHook()
      checkpoint("racing writer fired; ingest used " & $outcome.mechanism)
      check outcome.mechanism == lmReflink
      # The clone froze the bytes before the writer ran, so the committed
      # blob is the SNAPSHOT — and it hashes to its own name.
      check outcome.hash == digestOf(original)
      check cas.casGet(outcome.hash) == original
      check cas.blobIsSelfConsistent(outcome.hash)
      # ...and the source really did change, so the hook really fired.
      check readBytes(src) == racing

  test "a source replaced between hash and link declines the hardlink arm":
    let vols = hardlinkOnlyVolume()
    if vols.len == 0:
      checkpoint("no hardlink-capable volume without reflink on this host (" &
                 describeHost() & "); the witness fallback was NOT exercised")
      check volumes.len >= 1
    else:
      let vol = vols[0]
      let dir = caseDir(vol, "race-hardlink")
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      let original = payloadOf(20 * 1024, 23)
      let racing = payloadOf(20 * 1024, 29)
      check original.len == racing.len
      let src = dir / "src" / "out.bin"
      writeSource(src, original)
      defer: clearIngestHook()
      casIngestRaceWindowHook = proc (p: string) {.closure.} =
        replaceSourceInPlace(p, racing)
      let outcome = cas.casPutPathDetailed(src, allowSharedInode = true)
      clearIngestHook()
      checkpoint("racing writer fired; ingest used " & $outcome.mechanism &
                 " sourceChanged=" & $outcome.sourceChanged & " " &
                 outcome.diagnostic)
      # The witness saw the source move, so the arm that would have stored
      # a stale digest declined and copy took over.
      check outcome.mechanism == lmCopy
      check outcome.sourceChanged
      check "changed between hash and link" in outcome.diagnostic
      # The copy arm re-read, so what is stored is the racing content — and
      # crucially it is filed under ITS OWN digest, not the stale one.
      check outcome.hash == digestOf(racing)
      check outcome.hash != digestOf(original)
      check cas.blobIsSelfConsistent(outcome.hash)
      check not cas.casExists(digestOf(original))
      check hardlinkCount(cas.casPath(outcome.hash)) == 1

  test "a source that changes size mid-ingest fails rather than storing":
    let vol = primaryVolume()
    let dir = caseDir(vol, "race-size")
    let storeRoot = dir / "store"
    var cas = openCasStore(storeRoot)
    defer: cas.close()
    let original = payloadOf(16 * 1024, 31)
    let shorter = payloadOf(4 * 1024, 37)
    let src = dir / "src" / "out.bin"
    writeSource(src, original)
    defer: clearIngestHook()
    casIngestRaceWindowHook = proc (p: string) {.closure.} =
      replaceSourceInPlace(p, shorter)
    var raised = false
    var message = ""
    try:
      discard cas.casPutPathDetailed(src, allowSharedInode = true)
    except IOError as err:
      raised = true
      message = err.msg
    clearIngestHook()
    checkpoint("size-changing racing writer: raised=" & $raised & " " &
               message)
    if raised:
      check "file changed while hashing" in message
      # Nothing was committed under either digest...
      check not cas.casExists(digestOf(shorter))
      check stagingDebris(storeRoot).len == 0
    else:
      # The clone arm snapshots before the writer runs, so it legitimately
      # stores the ORIGINAL content — under the original's own digest.
      check cas.casExists(digestOf(original))
      check cas.blobIsSelfConsistent(digestOf(original))
    # In neither case may the store hold the original name over the
    # shorter bytes, or vice versa.
    check not cas.casExists(digestOf(original)) or
      cas.casGet(digestOf(original)) == original

  test "no arm this host can reach ever stores a mis-digested blob":
    ## One assertion repeated across whatever mechanisms the host can
    ## actually supply, with the racing writer firing every time, so the
    ## invariant is not proven only for the arm that happens to be default.
    var exercised: seq[LinkMechanism] = @[]
    let original = payloadOf(12 * 1024 + 5, 41)
    let racing = payloadOf(12 * 1024 + 5, 43)

    proc runArm(vol: ProbeVolume; tag: string;
                allowSharedInode: bool): LinkMechanism =
      let dir = caseDir(vol, tag)
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      let src = dir / "src" / "out.bin"
      writeSource(src, original)
      casIngestRaceWindowHook = proc (p: string) {.closure.} =
        replaceSourceInPlace(p, racing)
      let outcome = cas.casPutPathDetailed(
        src, allowSharedInode = allowSharedInode)
      clearIngestHook()
      check cas.blobIsSelfConsistent(outcome.hash)
      check outcome.hash == digestOf(original) or
        outcome.hash == digestOf(racing)
      outcome.mechanism

    defer: clearIngestHook()
    for vol in reflinkVolume():
      exercised.add(runArm(vol, "invariant-reflink", false))
      break
    for vol in hardlinkOnlyVolume():
      exercised.add(runArm(vol, "invariant-hardlink", true))
      break
    exercised.add(runArm(primaryVolume(), "invariant-copy", false))

    checkpoint("arms exercised on this host: " &
               exercised.deduplicate().mapIt($it).join(", ") &
               " (" & describeHost() & ")")
    check exercised.len >= 1

# ---------------------------------------------------------------------------

suite "M2 casPutPath — per-file limits are not pair capabilities":
  test "a source at the per-file link cap falls back to copy for that file only":
    when defined(windows):
      let vols = hardlinkOnlyVolume()
      if vols.len == 0:
        checkpoint("no hardlink-capable volume without reflink on this " &
                   "host (" & describeHost() & "); the link-cap arm was " &
                   "NOT exercised")
        check volumes.len >= 1
      else:
        let vol = vols[0]
        let dir = caseDir(vol, "linkcap")
        let storeRoot = dir / "store"
        var cas = openCasStore(storeRoot)
        defer: cas.close()
        let payload = payloadOf(1024, 61)
        let srcDir = dir / "src"
        let src = srcDir / "capped.bin"
        writeSource(src, payload)
        # Drive the SOURCE's inode to the NTFS 1024-name cap so the ingest
        # attempt is the one that trips it. This is a property of this one
        # file; the filesystem pair is unaffected.
        var extra = 0
        while extra < 4096:
          let attempt = attemptHardlink(src, srcDir / ("n" & $extra))
          if attempt.outcome != loOk:
            check attempt.isPerFileFallback()
            break
          extra.inc
        checkpoint("source inode carries " & $(extra + 1) & " names")
        check extra > 0
        let outcome = cas.casPutPathDetailed(src, allowSharedInode = true)
        checkpoint("capped ingest -> " & $outcome.mechanism &
                   " perFileFallback=" & $outcome.perFileFallback & " " &
                   outcome.diagnostic)
        # It MUST NOT surface as an error, MUST be a copy, and the bytes
        # must still be right.
        check outcome.mechanism == lmCopy
        check outcome.perFileFallback
        check cas.casGet(outcome.hash) == payload
        # ...and it MUST NOT downgrade the cached pair verdict.
        var fresh: LinkCapabilityCache
        check probeLinkCapabilities(fresh, srcDir, storeRoot / "tmp").hardlink
        # A DIFFERENT source on the same pair still hardlinks, which is
        # what "per-file, not per-pair" means.
        let other = srcDir / "uncapped.bin"
        writeSource(other, payloadOf(1024, 67))
        let otherOutcome = cas.casPutPathDetailed(other,
                                                  allowSharedInode = true)
        check otherOutcome.mechanism == lmHardlink
        check not otherOutcome.perFileFallback
        removeDir(extendedPath(srcDir))
    else:
      checkpoint("the 1024-name cap is an NTFS property; the per-file " &
                 "fallback arm was not exercised on this platform")
      check volumes.len >= 1

  test "perFileFallback is false on an ordinary ingest":
    let vol = primaryVolume()
    let dir = caseDir(vol, "nofallback")
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let src = dir / "src" / "plain.bin"
    writeSource(src, payloadOf(2048, 71))
    let outcome = cas.casPutPathDetailed(src)
    check not outcome.perFileFallback
    check not outcome.sourceChanged

# ---------------------------------------------------------------------------

suite "M2 casPutPath — edges":
  test "a zero-length file ingests correctly in whichever arm is used":
    ## The reflink primitive special-cases a zero byte count (the FSCTL
    ## would answer ERROR_INVALID_PARAMETER and be misread as
    ## "unsupported"), so the empty file is worth its own case on the
    ## ingest side too.
    let vol = primaryVolume()
    let dir = caseDir(vol, "empty")
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let src = dir / "src" / "zero.bin"
    writeSource(src, @[])
    let outcome = cas.casPutPathDetailed(src)
    checkpoint("zero-length file ingested via " & $outcome.mechanism)
    check outcome.hash == cas.casPut(@[])
    check getFileSize(extendedPath(cas.casPath(outcome.hash))) == 0
    check cas.casGet(outcome.hash).len == 0

  test "a missing source is refused before anything is staged":
    let vol = primaryVolume()
    let dir = caseDir(vol, "missing")
    let storeRoot = dir / "store"
    var cas = openCasStore(storeRoot)
    defer: cas.close()
    var raised = false
    try:
      discard cas.casPutPath(dir / "src" / "does-not-exist.bin")
    except StoreError:
      raised = true
    check raised
    check stagingDebris(storeRoot).len == 0

  test "a multi-chunk file ingests byte-identically in whichever arm is used":
    ## Larger than the 1 MiB streaming chunk in every arm, so a chunk-
    ## boundary bug cannot hide behind a single-read payload.
    let vol = primaryVolume()
    let dir = caseDir(vol, "multichunk")
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let payload = payloadOf(3 * 1024 * 1024 + 12345, 73)
    let src = dir / "src" / "big.bin"
    writeSource(src, payload)
    let outcome = cas.casPutPathDetailed(src)
    checkpoint("multi-chunk file ingested via " & $outcome.mechanism)
    check outcome.hash == digestOf(payload)
    check readBytes(cas.casPath(outcome.hash)) == payload
    check cas.blobIsSelfConsistent(outcome.hash)

# ---------------------------------------------------------------------------

suite "M2 casPutPath — teardown":
  # Deliberately a test rather than an ``addExitProc``: under ORC the
  # exit-proc closure runs after this module's globals are destroyed.
  test "every scratch directory this suite created is removed":
    clearIngestHook()
    for d in scratchDirs:
      try:
        removeDir(extendedPath(d))
      except CatchableError, Defect:
        discard
      check not dirExists(extendedPath(d))
