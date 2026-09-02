## Local-CAS-Hardlink-Materialization M3 — mutation safety for linked
## blobs, and the decision that the shared-inode arm stays OFF.
##
## Spec: ``reprobuild-specs/Local-Content-Addressed-Store.md``
##       §"Hardlink, Reflink, and Copy Policy", specifically
##       §"The shared-inode arm: a weaker guarantee" (normative).
##
## M3 asks one question: can the hardlink arm be made safe enough to
## enable? The answer this file measures is NO, and it measures it rather
## than arguing it. Five things are under test:
##
##   1. **The rule the spec makes central.** /Correctness must not depend
##      on which mechanism was used./ Expressed as an assertion: the same
##      blob materialized by link and by copy, then mutated at the
##      destination, must leave identical CAS state. This PASSES for every
##      arm the shipped defaults can select (reflink, copy) and FAILS for
##      the hardlink arm — which is the answer to "decide or codify",
##      encoded as a test rather than softened into a comment.
##   2. **Both directions.** A materialized hardlink shares an inode with
##      a file the build is about to consume; an INGESTED one shares it
##      with a file the build tree still owns and will overwrite. The
##      second is worse and is measured separately.
##   3. **Why the read-only lever does not rescue the arm.** Mode bits are
##      per-inode, so the guard lands on the build tree's own output and is
##      clearable, without privilege, through the very name it guards
##      against. Measured on this host, not reasoned about.
##   4. **The ``st_nlink`` GC signal.** With the arm off, every blob the
##      store holds has exactly one name, so a link count above one is
##      unambiguous. Opting in destroys that, permanently, for every
##      ingested blob.
##   5. **That the decision is enforced where it is made.** Both named
##      constants are off AND ``preferredMechanisms`` honours them, so the
##      policy is not merely documented.
##
## Every mechanism claim is read off the returned outcome record, never
## inferred from timing. An arm this host cannot supply announces itself
## through ``checkpoint`` rather than passing silently.

import std/[algorithm, os, sequtils, strutils, unittest]

import blake3
from repro_core/paths import extendedPath

import repro_cas_store

# ---------------------------------------------------------------------------
# Host volume discovery — the same approach M0's, M1's and M2's tests use,
# because the answer genuinely differs per volume on this workspace (ReFS
# store volume, NTFS %TEMP%).
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
  let candidate = parent / ("repro-m3-" & $getCurrentProcessId() & "-" & tag)
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
    "no writable scratch directory could be created on this host; the " &
    "mutation-safety arms cannot be exercised at all"
  volumes[0]

proc reflinkVolume(): seq[ProbeVolume] =
  volumes.filterIt(it.reflink)

proc hardlinkOnlyVolume(): seq[ProbeVolume] =
  ## A volume where a hardlink is available and a reflink is not, so the
  ## shared-inode arm can be reached without the preferred, safer reflink
  ## arm winning first.
  volumes.filterIt(it.hardlink and not it.reflink)

proc copyOnlyVolume(): seq[ProbeVolume] =
  ## A volume where the SHIPPED DEFAULTS select copy. That is any volume
  ## without reflink: the hardlink arm is off, so hardlink-capable or not,
  ## the default answer there is copy.
  volumes.filterIt(not it.reflink)

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

proc digestOf(payload: openArray[byte]): ContentHash =
  toContentHash(blake3.digest(payload))

proc fingerprint(bytes: openArray[byte]): string =
  ## ``<digest>/<length>``. Used instead of comparing multi-kilobyte byte
  ## sequences directly: the assertion is identical in strength — these
  ## payloads are content-addressed — and a failing ``check`` then prints
  ## something a reader can act on rather than two screens of integers.
  $digestOf(bytes) & "/" & $bytes.len

proc fingerprintFile(path: string): string =
  fingerprint(readBytes(path))

# ---------------------------------------------------------------------------
# The three write shapes a build step can use on an output it already owns.
# They are NOT equivalent through a shared inode, and the difference is the
# whole reason the arm cannot be enabled: the store cannot observe which one
# an arbitrary tool will pick.
# ---------------------------------------------------------------------------

proc mutateByTruncatingWrite(path: string; payload: openArray[byte]) =
  ## ``open(O_WRONLY|O_CREAT|O_TRUNC)`` / ``CreateFile(CREATE_ALWAYS)``.
  ## This is the shape every compiler's ``-o`` uses, and the shape
  ## ``writeFile`` compiles to. It writes THROUGH the existing name into
  ## the existing inode — it does not unlink and replace.
  writeFile(extendedPath(path), textOfBytes(payload))

proc mutateInPlaceAt(path: string; offset: int; patch: openArray[byte]) =
  ## The narrowest possible in-place write: seek into the existing file and
  ## overwrite a few bytes. Nothing is truncated, so the file's SIZE does
  ## not move — which is why a size-based guard cannot see this at all.
  var f = open(extendedPath(path), fmReadWriteExisting)
  try:
    f.setFilePos(int64(offset))
    doAssert f.writeBuffer(unsafeAddr patch[0], patch.len) == patch.len
  finally:
    try: f.close() except CatchableError: discard

proc mutateByReplacingTheName(path: string; payload: openArray[byte]) =
  ## The careful shape: stage a new file and put it at the name, so the
  ## OLD inode is unlinked from that name rather than written through.
  let staged = path & ".newgeneration"
  writeFile(extendedPath(staged), textOfBytes(payload))
  if fileExists(extendedPath(path)):
    removeFile(extendedPath(path))
  moveFile(extendedPath(staged), extendedPath(path))

# ---------------------------------------------------------------------------
# CAS state, as a comparable value. "Identical CAS state afterwards" is the
# assertion the milestone asks for, so it has to be a value, not a vibe.
# ---------------------------------------------------------------------------

type
  BlobRecord = object
    ## Deliberately a DIGEST of the stored bytes rather than the bytes: a
    ## blob is content-addressed, so "the content changed" and "the digest
    ## of the content changed" are the same statement, and a failure
    ## message that prints two 64-char hex strings is one a reader can act
    ## on where two 40 KiB byte arrays are not.
    relative: string   ## ``<shard>/<64-hex>`` — proves the layout too.
    content: string    ## BLAKE3-256 of the file AS IT SITS ON DISK.
    sizeBytes: int
    links: int         ## ``st_nlink`` / ``nNumberOfLinks``.

  CasSnapshot = object
    blobs: seq[BlobRecord]

proc snapshotCas(cas: CasStore): CasSnapshot =
  let blobRoot = cas.root() / "cas" / "blake3"
  var recs: seq[BlobRecord] = @[]
  if dirExists(extendedPath(blobRoot)):
    for shardKind, shardPath in walkDir(extendedPath(blobRoot)):
      if shardKind != pcDir:
        continue
      for kind, p in walkDir(extendedPath(shardPath)):
        if kind != pcFile:
          continue
        let raw = readBytes(p)
        recs.add(BlobRecord(
          relative: extractFilename(shardPath) & "/" & extractFilename(p),
          content: $toContentHash(blake3.digest(raw)),
          sizeBytes: raw.len,
          links: hardlinkCount(p)))
  recs.sort(proc (a, b: BlobRecord): int = cmp(a.relative, b.relative))
  CasSnapshot(blobs: recs)

proc describe(s: CasSnapshot): string =
  s.blobs.mapIt("name=" & it.relative[3 .. 12] & "… content=" &
                it.content[0 .. 9] & "… (" & $it.sizeBytes & "B, links=" &
                $it.links & ")").join(", ")

# ---------------------------------------------------------------------------
# Structural reads of the production sources, for the properties that are
# statements about the CODE rather than about a run of it.
# ---------------------------------------------------------------------------

proc materializeBody(): string =
  let src = currentSourcePath().parentDir().parentDir() / "src" /
    "repro_cas_store.nim"
  doAssert fileExists(extendedPath(src)), src & " not found"
  let text = readFile(extendedPath(src))
  let start = text.find("proc casMaterializeDetailed*")
  doAssert start >= 0, "casMaterializeDetailed not found in " & src
  let stop = text.find("\nproc casMaterialize*", start)
  doAssert stop > start, "end of casMaterializeDetailed not found"
  var kept: seq[string] = @[]
  for line in text[start ..< stop].splitLines():
    if line.strip().startsWith("##"):
      continue
    kept.add(line)
  kept.join("\n")

# ---------------------------------------------------------------------------

suite "M3 mechanism independence — restore side":
  test "mutating a materialized output leaves the CAS untouched in every arm the default can select":
    ## THE milestone's assertion, run against every arm the shipped
    ## configuration can actually reach on this host. The destination is
    ## mutated three different ways, because a build step that reopens its
    ## output has three shapes available to it and the store cannot choose
    ## which one it uses.
    var exercised: seq[LinkMechanism] = @[]
    let payload = payloadOf(40 * 1024 + 9, 3)
    for vol in volumes:
      let dir = caseDir(vol, "indep")
      var cas = openCasStore(dir / "store")
      # ``casGet`` RAISES on a corrupt blob, which is exactly what a broken
      # arm produces here, so the handle is closed from a ``finally`` — a
      # trailing ``cas.close()`` would be skipped by the very failure this
      # case exists to detect, and the store would then hold its index open
      # against the teardown.
      try:
        let h = cas.casPut(payload)
        let dest = dir / "out" / "restored.bin"
        let outcomes = cas.casMaterializeDetailed(
          @[CasMaterialization(hash: h, destination: dest)])
        let before = cas.snapshotCas()
        check fingerprintFile(dest) == fingerprint(payload)

        mutateByTruncatingWrite(dest, payloadOf(40 * 1024 + 9, 5))
        mutateInPlaceAt(dest, 1024, [0xDE'u8, 0xAD'u8, 0xBE'u8, 0xEF'u8])
        mutateByReplacingTheName(dest, payloadOf(11, 7))

        let after = cas.snapshotCas()
        checkpoint(vol.dir & " (" & vol.fsName & ") -> " &
                   $outcomes[0].mechanism & "; CAS before " &
                   before.describe() & " after " & after.describe())
        # The whole state, not merely the one blob: content digests, link
        # counts and the on-disk names all have to be where they were.
        check after == before
        check cas.casVerify(h)
        check fingerprint(cas.casGet(h)) == fingerprint(payload)
        # ...and the arm that got us here was NOT the shared-inode one.
        check outcomes[0].mechanism != lmHardlink
        exercised.add(outcomes[0].mechanism)
      finally:
        cas.close()

    checkpoint("arms the shipped defaults selected on this host: " &
               exercised.deduplicate().mapIt($it).join(", ") &
               " (" & describeHost() & ")")
    check exercised.len >= 1
    check lmHardlink notin exercised

  test "the same blob materialized by link and by copy leaves identical CAS state":
    ## The milestone's sentence, taken literally: one payload, two stores,
    ## one destination produced by a LINK and one by a COPY, both mutated
    ## the same way, and the two stores compared against each other as well
    ## as against themselves.
    let linkVols = reflinkVolume()
    let copyVols = copyOnlyVolume()
    if linkVols.len == 0 or copyVols.len == 0:
      checkpoint("this host cannot supply both a link arm and a copy arm " &
                 "under the shipped defaults (" & describeHost() &
                 "); the link-versus-copy comparison was NOT exercised")
      check volumes.len >= 1
    else:
      let payload = payloadOf(24 * 1024 + 3, 11)
      let mutation = payloadOf(24 * 1024 + 3, 13)

      proc runArm(vol: ProbeVolume; tag: string):
          tuple[mech: LinkMechanism; snap: CasSnapshot; relative: string;
                verified: bool] =
        let dir = caseDir(vol, tag)
        var cas = openCasStore(dir / "store")
        defer: cas.close()
        let h = cas.casPut(payload)
        let dest = dir / "out" / "same-blob.bin"
        let outcomes = cas.casMaterializeDetailed(
          @[CasMaterialization(hash: h, destination: dest)])
        check fingerprintFile(dest) == fingerprint(payload)
        mutateByTruncatingWrite(dest, mutation)
        mutateInPlaceAt(dest, 512, [0x00'u8, 0xFF'u8])
        let snap = cas.snapshotCas()
        (outcomes[0].mechanism, snap,
         cas.casPath(h).replace(dir / "store", ""), cas.casVerify(h))

      let viaLink = runArm(linkVols[0], "same-link")
      let viaCopy = runArm(copyVols[0], "same-copy")
      checkpoint("link arm = " & $viaLink.mech & " (" & linkVols[0].fsName &
                 "), copy arm = " & $viaCopy.mech & " (" &
                 copyVols[0].fsName & ")")
      # The comparison is only meaningful if the two runs really did use
      # different mechanisms, and one of them really was a link.
      check viaLink.mech != viaCopy.mech
      check viaLink.mech in [lmReflink, lmHardlink]
      check viaCopy.mech == lmCopy
      # Identical CAS state afterwards — same blob names, same bytes, same
      # link counts, and both still verify.
      check viaLink.snap == viaCopy.snap
      check viaLink.relative == viaCopy.relative
      check viaLink.verified
      check viaCopy.verified
      check viaLink.snap.blobs.len == 1
      check viaLink.snap.blobs[0].content == $digestOf(payload)
      check viaLink.snap.blobs[0].sizeBytes == payload.len
      check viaLink.snap.blobs[0].links == 1

  test "the hardlink arm, reachable only by an explicit opt-in, is the one that fails it":
    ## The negative half, pinned rather than softened. This is the evidence
    ## behind M3's decision: the arm does not satisfy the property the two
    ## cases above establish for every default-reachable arm, so it stays
    ## off. The same store, the same blob and the same mutation are run
    ## twice — once with the shipped default and once opted in — so the
    ## difference is attributable to the arm and to nothing else.
    let vols = hardlinkOnlyVolume()
    if vols.len == 0:
      checkpoint("no hardlink-capable volume without reflink on this host (" &
                 describeHost() & "); the shared-inode arm was NOT exercised")
      check volumes.len >= 1
    else:
      let vol = vols[0]
      let dir = caseDir(vol, "shared-inode")
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      let payload = payloadOf(16 * 1024, 17)
      let mutation = payloadOf(16 * 1024, 19)

      # Arm one: the shipped default.
      let safeHash = cas.casPut(payload)
      let safeDest = dir / "out" / "default.bin"
      let safeOutcome = cas.casMaterializeDetailed(
        @[CasMaterialization(hash: safeHash, destination: safeDest)])
      let safeBefore = cas.snapshotCas()
      mutateByTruncatingWrite(safeDest, mutation)
      check safeOutcome[0].mechanism == lmCopy
      check cas.snapshotCas() == safeBefore
      check cas.casVerify(safeHash)

      # Arm two: the same operation, opted in.
      let riskHash = cas.casPut(payloadOf(16 * 1024, 23))
      let riskDest = dir / "out" / "optedin.bin"
      let riskOutcome = cas.casMaterializeDetailed(
        @[CasMaterialization(hash: riskHash, destination: riskDest)],
        allowSharedInode = true)
      check riskOutcome[0].mechanism == lmHardlink
      check hardlinkCount(cas.casPath(riskHash)) == 2
      let riskBefore = cas.snapshotCas()
      mutateByTruncatingWrite(riskDest, mutation)
      let riskAfter = cas.snapshotCas()
      checkpoint("opted in: " & $riskOutcome[0].mechanism &
                 "; CAS before " & riskBefore.describe() & " after " &
                 riskAfter.describe())
      # The property the default arms hold, broken.
      check riskAfter != riskBefore
      check not cas.casVerify(riskHash)
      # ...and specifically broken by the destination write reaching the
      # blob's own bytes, not by anything incidental.
      check fingerprintFile(cas.casPath(riskHash)) == fingerprint(mutation)
      # The blob written through the default arm is still fine, so the
      # damage is scoped to the arm and is not a property of the store.
      check cas.casVerify(safeHash)

  test "an in-place truncating write reaches the blob; replacing the name does not":
    ## Why "builds write via rename" cannot be assumed away. Through ONE
    ## shared inode the two shapes have opposite outcomes, and the store
    ## has no way to observe which one an arbitrary tool will use.
    let vols = hardlinkOnlyVolume()
    if vols.len == 0:
      checkpoint("no hardlink-capable volume without reflink on this host (" &
                 describeHost() & "); the write-shape comparison was NOT " &
                 "exercised")
      check volumes.len >= 1
    else:
      let vol = vols[0]
      let dir = caseDir(vol, "write-shape")
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      let truncated = payloadOf(8192, 29)
      let replaced = payloadOf(8192, 31)
      let truncatedHash = cas.casPut(truncated)
      let replacedHash = cas.casPut(replaced)
      let truncatedDest = dir / "out" / "truncated.bin"
      let replacedDest = dir / "out" / "replaced.bin"
      let outcomes = cas.casMaterializeDetailed(@[
        CasMaterialization(hash: truncatedHash, destination: truncatedDest),
        CasMaterialization(hash: replacedHash, destination: replacedDest),
      ], allowSharedInode = true)
      check outcomes[0].mechanism == lmHardlink
      check outcomes[1].mechanism == lmHardlink
      check hardlinkCount(truncatedDest) == 2
      check hardlinkCount(replacedDest) == 2

      mutateByTruncatingWrite(truncatedDest, payloadOf(8192, 37))
      mutateByReplacingTheName(replacedDest, payloadOf(8192, 41))

      # Same mechanism, same store, same call — opposite outcomes.
      check not cas.casVerify(truncatedHash)
      check cas.casVerify(replacedHash)
      check fingerprint(cas.casGet(replacedHash)) == fingerprint(replaced)
      # Replacing the name dropped the extra reference; the truncating
      # write kept it, because the inode was never unlinked.
      check hardlinkCount(cas.casPath(replacedHash)) == 1
      check hardlinkCount(cas.casPath(truncatedHash)) == 2

  test "a partial in-place overwrite reaches the blob without moving its size":
    ## The narrowest form of the hazard, and the reason a cheap guard does
    ## not exist: the blob's length is unchanged, so anything that checks
    ## sizes sees nothing at all. Only a full re-hash notices.
    let vols = hardlinkOnlyVolume()
    if vols.len == 0:
      checkpoint("no hardlink-capable volume without reflink on this host (" &
                 describeHost() & "); the partial-write arm was NOT exercised")
      check volumes.len >= 1
    else:
      let vol = vols[0]
      let dir = caseDir(vol, "partial")
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      let payload = payloadOf(12 * 1024, 43)
      let h = cas.casPut(payload)
      let dest = dir / "out" / "partial.bin"
      let outcomes = cas.casMaterializeDetailed(
        @[CasMaterialization(hash: h, destination: dest)],
        allowSharedInode = true)
      check outcomes[0].mechanism == lmHardlink
      let blobPath = cas.casPath(h)
      let sizeBefore = getFileSize(extendedPath(blobPath))

      mutateInPlaceAt(dest, 4096, [0x01'u8, 0x02'u8, 0x03'u8, 0x04'u8])

      checkpoint("four bytes overwritten at offset 4096 through the link; " &
                 "blob size " & $sizeBefore & " -> " &
                 $getFileSize(extendedPath(blobPath)))
      check getFileSize(extendedPath(blobPath)) == sizeBefore
      check not cas.casVerify(h)
      let corrupted = readBytes(blobPath)
      check corrupted.len == payload.len
      check corrupted[4096 .. 4099] == @[0x01'u8, 0x02'u8, 0x03'u8, 0x04'u8]

# ---------------------------------------------------------------------------

suite "M3 mechanism independence — ingest side":
  test "rewriting the source after ingest leaves the CAS untouched in every arm the default can select":
    ## The ingest direction is the more dangerous of the two, because the
    ## shared inode would be with a file the build tree still OWNS. Here
    ## the source is rewritten exactly as a rebuild would rewrite it, in
    ## all three shapes, and the store must not notice.
    var exercised: seq[LinkMechanism] = @[]
    let payload = payloadOf(28 * 1024 + 5, 47)
    for vol in volumes:
      let dir = caseDir(vol, "ingest-indep")
      var cas = openCasStore(dir / "store")
      try:
        let src = dir / "src" / "out.bin"
        writeSource(src, payload)
        let outcome = cas.casPutPathDetailed(src)
        let before = cas.snapshotCas()
        check outcome.hash == digestOf(payload)

        mutateByTruncatingWrite(src, payloadOf(28 * 1024 + 5, 53))
        mutateInPlaceAt(src, 2048, [0xAB'u8, 0xCD'u8])
        mutateByReplacingTheName(src, payloadOf(31, 59))

        let after = cas.snapshotCas()
        checkpoint(vol.dir & " (" & vol.fsName & ") -> " & $outcome.mechanism &
                   "; CAS before " & before.describe() & " after " &
                   after.describe())
        check after == before
        check cas.casVerify(outcome.hash)
        check fingerprint(cas.casGet(outcome.hash)) == fingerprint(payload)
        check outcome.mechanism != lmHardlink
        exercised.add(outcome.mechanism)
      finally:
        cas.close()

    checkpoint("ingest arms the shipped defaults selected on this host: " &
               exercised.deduplicate().mapIt($it).join(", ") &
               " (" & describeHost() & ")")
    check exercised.len >= 1
    check lmHardlink notin exercised

  test "the same file ingested by link and by copy leaves identical CAS state":
    let linkVols = reflinkVolume()
    let copyVols = copyOnlyVolume()
    if linkVols.len == 0 or copyVols.len == 0:
      checkpoint("this host cannot supply both a link arm and a copy arm " &
                 "under the shipped defaults (" & describeHost() &
                 "); the ingest link-versus-copy comparison was NOT exercised")
      check volumes.len >= 1
    else:
      let payload = payloadOf(20 * 1024 + 7, 61)

      proc runArm(vol: ProbeVolume; tag: string):
          tuple[mech: LinkMechanism; snap: CasSnapshot; relative: string;
                verified: bool] =
        let dir = caseDir(vol, tag)
        var cas = openCasStore(dir / "store")
        defer: cas.close()
        let src = dir / "src" / "out.bin"
        writeSource(src, payload)
        let outcome = cas.casPutPathDetailed(src)
        mutateByTruncatingWrite(src, payloadOf(20 * 1024 + 7, 67))
        mutateInPlaceAt(src, 256, [0x7F'u8])
        (outcome.mechanism, cas.snapshotCas(),
         cas.casPath(outcome.hash).replace(dir / "store", ""),
         cas.casVerify(outcome.hash))

      let viaLink = runArm(linkVols[0], "ingest-link")
      let viaCopy = runArm(copyVols[0], "ingest-copy")
      checkpoint("ingest link arm = " & $viaLink.mech & " (" &
                 linkVols[0].fsName & "), copy arm = " & $viaCopy.mech &
                 " (" & copyVols[0].fsName & ")")
      check viaLink.mech != viaCopy.mech
      check viaLink.mech in [lmReflink, lmHardlink]
      check viaCopy.mech == lmCopy
      check viaLink.snap == viaCopy.snap
      check viaLink.relative == viaCopy.relative
      check viaLink.verified
      check viaCopy.verified
      check viaLink.snap.blobs.len == 1
      check viaLink.snap.blobs[0].content == $digestOf(payload)
      check viaLink.snap.blobs[0].sizeBytes == payload.len
      check viaLink.snap.blobs[0].links == 1

  test "the ingest hardlink arm, reachable only by an explicit opt-in, is the one that fails it":
    ## Worse than the restore side and measured as such: nothing unusual
    ## has to happen. The build tree simply rebuilds and rewrites the
    ## output it has always owned, and the store's blob stops hashing to
    ## the name it is filed under.
    let vols = hardlinkOnlyVolume()
    if vols.len == 0:
      checkpoint("no hardlink-capable volume without reflink on this host (" &
                 describeHost() & "); the ingest shared-inode arm was NOT " &
                 "exercised")
      check volumes.len >= 1
    else:
      let vol = vols[0]
      let dir = caseDir(vol, "ingest-shared")
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      let payload = payloadOf(16 * 1024, 71)

      # Arm one: the shipped default, same store, same content shape.
      let safeSrc = dir / "src" / "default.bin"
      writeSource(safeSrc, payload)
      let safeOutcome = cas.casPutPathDetailed(safeSrc)
      check safeOutcome.mechanism == lmCopy
      let safeBefore = cas.snapshotCas()
      mutateByTruncatingWrite(safeSrc, payloadOf(16 * 1024, 73))
      check cas.snapshotCas() == safeBefore
      check cas.casVerify(safeOutcome.hash)

      # Arm two: opted in.
      let riskSrc = dir / "src" / "optedin.bin"
      writeSource(riskSrc, payloadOf(16 * 1024, 79))
      let riskOutcome = cas.casPutPathDetailed(riskSrc,
                                               allowSharedInode = true)
      check riskOutcome.mechanism == lmHardlink
      # One inode, two names — and the second name belongs to the build
      # tree, which is why no check inside ingest can ever retire it.
      check hardlinkCount(riskSrc) == 2
      check hardlinkCount(cas.casPath(riskOutcome.hash)) == 2
      let riskBefore = cas.snapshotCas()
      mutateByTruncatingWrite(riskSrc, payloadOf(16 * 1024, 83))
      let riskAfter = cas.snapshotCas()
      checkpoint("opted-in ingest: " & $riskOutcome.mechanism &
                 "; CAS before " & riskBefore.describe() & " after " &
                 riskAfter.describe())
      check riskAfter != riskBefore
      check not cas.casVerify(riskOutcome.hash)
      check fingerprintFile(cas.casPath(riskOutcome.hash)) ==
        fingerprint(payloadOf(16 * 1024, 83))
      check cas.casVerify(safeOutcome.hash)

# ---------------------------------------------------------------------------

suite "M3 — why read-only blobs do not rescue the shared-inode arm":
  test "mode bits are per-inode, so a read-only blob makes the output read-only and refuses the write":
    ## The lever the spec names, measured. It DOES stop the write — and
    ## that is the problem, not the solution: the file it makes read-only
    ## is the build tree's own output, which a step that reopens its output
    ## for write is entitled to expect it can write.
    let vols = hardlinkOnlyVolume()
    if vols.len == 0:
      checkpoint("no hardlink-capable volume without reflink on this host (" &
                 describeHost() & "); the read-only lever was NOT exercised")
      check volumes.len >= 1
    else:
      let vol = vols[0]
      let dir = caseDir(vol, "readonly")
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      let payload = payloadOf(8192, 89)
      let h = cas.casPut(payload)
      let blobPath = cas.casPath(h)
      # Protect the store the way the lever proposes.
      setFilePermissions(extendedPath(blobPath), {fpUserRead})
      let dest = dir / "out" / "protected.bin"
      let outcomes = cas.casMaterializeDetailed(
        @[CasMaterialization(hash: h, destination: dest)],
        allowSharedInode = true)
      check outcomes[0].mechanism == lmHardlink
      # The guard landed on the OUTPUT as well, because it is one inode.
      let destPerms = getFilePermissions(extendedPath(dest))
      checkpoint("blob made read-only; the hardlinked output reports " &
                 $destPerms)
      check fpUserWrite notin destPerms
      var refused = false
      try:
        mutateByTruncatingWrite(dest, payloadOf(8192, 97))
      except CatchableError, Defect:
        refused = true
      check refused
      check cas.casVerify(h)
      # Restore write permission so the case's own teardown is unimpeded.
      setFilePermissions(extendedPath(blobPath), {fpUserRead, fpUserWrite})

  test "the read-only guard is clearable through the output's own name, without privilege":
    ## Which is what makes it an accident guard rather than a safety
    ## property. The party the guard exists to stop holds a name for the
    ## inode and can therefore lift the guard itself — no elevation, no
    ## special API, and on Windows a great many tools clear the attribute
    ## as a matter of course.
    let vols = hardlinkOnlyVolume()
    if vols.len == 0:
      checkpoint("no hardlink-capable volume without reflink on this host (" &
                 describeHost() & "); the guard-removal arm was NOT exercised")
      check volumes.len >= 1
    else:
      let vol = vols[0]
      let dir = caseDir(vol, "readonly-cleared")
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      let payload = payloadOf(8192, 101)
      let mutation = payloadOf(8192, 103)
      let h = cas.casPut(payload)
      let blobPath = cas.casPath(h)
      setFilePermissions(extendedPath(blobPath), {fpUserRead})
      let dest = dir / "out" / "cleared.bin"
      let outcomes = cas.casMaterializeDetailed(
        @[CasMaterialization(hash: h, destination: dest)],
        allowSharedInode = true)
      check outcomes[0].mechanism == lmHardlink

      # An ordinary unprivileged caller, holding only the output's name.
      setFilePermissions(extendedPath(dest), {fpUserRead, fpUserWrite})
      # The blob's own mode moved with it, because the mode is the inode's.
      check fpUserWrite in getFilePermissions(extendedPath(blobPath))
      mutateByTruncatingWrite(dest, mutation)
      checkpoint("guard cleared through the output name; blob now verifies=" &
                 $cas.casVerify(h))
      check not cas.casVerify(h)
      check fingerprintFile(blobPath) == fingerprint(mutation)

  test "with the shared-inode arm off, a read-only blob leaves the output writable":
    ## The tension the spec calls "real" is a consequence OF the hardlink
    ## arm and of nothing else. A reflink and a copy each produce their own
    ## inode, so the blob's mode does not reach the output at all — which
    ## is measured here for every arm the shipped defaults can select.
    var exercised: seq[LinkMechanism] = @[]
    let payload = payloadOf(8192, 107)
    for vol in volumes:
      let dir = caseDir(vol, "readonly-default")
      var cas = openCasStore(dir / "store")
      let h = cas.casPut(payload)
      let blobPath = cas.casPath(h)
      # The write this case makes is the one a build step makes, so it is
      # deliberately NOT wrapped in a swallow: if the arm ever starts
      # handing out a read-only output, the write raises and the case
      # fails. The ``finally`` exists only so the fixture cannot leave an
      # unwritable blob and an open store behind for the teardown.
      try:
        setFilePermissions(extendedPath(blobPath), {fpUserRead})
        let dest = dir / "out" / "writable.bin"
        let outcomes = cas.casMaterializeDetailed(
          @[CasMaterialization(hash: h, destination: dest)])
        let destPerms = getFilePermissions(extendedPath(dest))
        checkpoint(vol.dir & " (" & vol.fsName & ") -> " &
                   $outcomes[0].mechanism &
                   "; read-only blob, output reports " & $destPerms)
        check outcomes[0].mechanism != lmHardlink
        check fpUserWrite in destPerms
        check fpUserWrite notin getFilePermissions(extendedPath(blobPath))
        # A build step reopening its own output is not obstructed...
        mutateByTruncatingWrite(dest, payloadOf(8192, 109))
        # ...and the protected blob is untouched by that write.
        check cas.casVerify(h)
        exercised.add(outcomes[0].mechanism)
      finally:
        try:
          setFilePermissions(extendedPath(blobPath), {fpUserRead, fpUserWrite})
        except CatchableError, Defect:
          discard
        cas.close()
    check exercised.len >= 1
    check lmHardlink notin exercised

  test "applyPermissions through a shared inode would chmod the CAS blob, which is why the arm excludes it":
    ## M1 introduced the exclusion in passing; M3 confirms it is still
    ## right and supplies its evidence. The exclusion applies exactly
    ## where mode bits mean something, because
    ## ``casMaterializeDetailed`` does not apply permissions where they
    ## do not — so the guard and the thing it guards are enabled
    ## together, and the structural check below pins that they stay that
    ## way.
    ##
    ## Platform-And-Filesystem-Facts F3 changed the SPELLING of that
    ## guard from ``when not defined(windows)`` to
    ## ``when HostHonoursPosixModeBits`` — a compile-time reading of the
    ## OS fact table's ``honoursPosixModeBits``, which is what the
    ## platform check always meant. The pin follows the spelling and
    ## keeps its strength: what it asserts is still that the guard and
    ## the guarded block are the same condition, and it now also asserts
    ## that the condition is the declared fact rather than a platform
    ## name standing in for one.
    let body = materializeBody()
    check "if entry.applyPermissions:" in body
    check "entryAllowsSharedInode = false" in body
    check "when HostHonoursPosixModeBits:" in body
    # ...and that the old spelling is gone, so the two cannot coexist
    # with only one of them updated.
    check "when not defined(windows):" notin body

    let vols = hardlinkOnlyVolume()
    if vols.len == 0:
      checkpoint("no hardlink-capable volume without reflink on this host (" &
                 describeHost() & "); the chmod-reaches-the-blob measurement " &
                 "was NOT taken")
      check volumes.len >= 1
    else:
      # Measure the fact the exclusion rests on: a mode change made through
      # a hardlinked name is a mode change to the CAS blob.
      let vol = vols[0]
      let dir = caseDir(vol, "perms-reach")
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      let h = cas.casPut(payloadOf(4096, 113))
      let blobPath = cas.casPath(h)
      let dest = dir / "out" / "moded.bin"
      let outcomes = cas.casMaterializeDetailed(
        @[CasMaterialization(hash: h, destination: dest)],
        allowSharedInode = true)
      check outcomes[0].mechanism == lmHardlink
      let blobBefore = getFilePermissions(extendedPath(blobPath))
      setFilePermissions(extendedPath(dest), {fpUserRead})
      let blobAfter = getFilePermissions(extendedPath(blobPath))
      checkpoint("chmod through the linked output moved the blob's mode " &
                 $blobBefore & " -> " & $blobAfter)
      check blobBefore != blobAfter
      check fpUserWrite notin blobAfter
      setFilePermissions(extendedPath(blobPath), {fpUserRead, fpUserWrite})

# ---------------------------------------------------------------------------

suite "M3 — the st_nlink GC signal":
  test "under the shipped defaults every blob the store holds has exactly one name":
    ## Which is what makes the signal usable at all. M0 recorded
    ## ``st_nlink`` as the free hint that a blob has outstanding
    ## materializations the GC did not record; that hint only carries
    ## information while the store's own operations never raise the count.
    ## Measured across BOTH directions and every arm the defaults select.
    for vol in volumes:
      let dir = caseDir(vol, "gc-signal")
      var cas = openCasStore(dir / "store")
      try:
        let viaBytes = cas.casPut(payloadOf(4096, 127))
        let src = dir / "src" / "adopted.bin"
        writeSource(src, payloadOf(4096, 131))
        let viaPath = cas.casPutPathDetailed(src)
        let dest = dir / "out" / "restored.bin"
        let outcomes = cas.casMaterializeDetailed(@[
          CasMaterialization(hash: viaBytes, destination: dest),
          CasMaterialization(hash: viaPath.hash,
                             destination: dir / "out" / "restored2.bin"),
        ])
        let snap = cas.snapshotCas()
        checkpoint(vol.dir & " (" & vol.fsName & "): ingest " &
                   $viaPath.mechanism & ", restore " &
                   $outcomes[0].mechanism & "; " & snap.describe())
        check snap.blobs.len == 2
        for rec in snap.blobs:
          check rec.links == 1
      finally:
        cas.close()

  test "opting into the ingest arm gives every stored blob a second name the store does not own":
    ## And that is what would retire the signal rather than merely
    ## complicate it: the extra name belongs to the build tree, persists
    ## after the ingest returns, and the store never sees it go. A GC that
    ## read ``st_nlink > 1`` as "outstanding materialization" would read it
    ## that way for every blob it holds, forever.
    let vols = hardlinkOnlyVolume()
    if vols.len == 0:
      checkpoint("no hardlink-capable volume without reflink on this host (" &
                 describeHost() & "); the GC-signal contingency was NOT " &
                 "exercised")
      check volumes.len >= 1
    else:
      let vol = vols[0]
      let dir = caseDir(vol, "gc-contingent")
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      var sources: seq[string] = @[]
      for i in 0 ..< 3:
        let src = dir / "src" / ("out" & $i & ".bin")
        writeSource(src, payloadOf(2048 + i, 137 + i))
        let outcome = cas.casPutPathDetailed(src, allowSharedInode = true)
        check outcome.mechanism == lmHardlink
        sources.add(src)
      let snap = cas.snapshotCas()
      checkpoint("three blobs ingested with the arm opted in: " &
                 snap.describe())
      check snap.blobs.len == 3
      for rec in snap.blobs:
        check rec.links == 2
      # The store cannot retire the extra name, because it belongs to a
      # tree the store does not own — demonstrated by the count only
      # falling when the BUILD TREE removes its own file.
      removeFile(extendedPath(sources[0]))
      var withOneName = 0
      for rec in cas.snapshotCas().blobs:
        if rec.links == 1: withOneName.inc
      check withOneName == 1

# ---------------------------------------------------------------------------

suite "M3 — the decision, expressed where it is enforced":
  test "both shared-inode defaults are off, and the policy function honours them":
    ## M1 and M2 each landed a named constant so M3's answer would be a
    ## reviewable one-line change. M3's answer is that they stay ``false``,
    ## so the test that watched for a flip now records a settled decision —
    ## and, because a constant nobody reads proves nothing, it also
    ## measures that ``preferredMechanisms`` actually declines the arm.
    check CasMaterializeAllowSharedInodeDefault == false
    check CasIngestAllowSharedInodeDefault == false

    var offeredWhenOptedIn = 0
    for vol in volumes:
      var cache: LinkCapabilityCache
      let cap = probeLinkCapabilities(cache, vol.dir, vol.dir)
      check lmHardlink notin
        cap.preferredMechanisms(
          allowSharedInode = CasMaterializeAllowSharedInodeDefault)
      check lmHardlink notin
        cap.preferredMechanisms(
          allowSharedInode = CasIngestAllowSharedInodeDefault)
      # Not vacuous: on a pair that CAN hardlink, the opt-in still offers
      # it, so the two assertions above are about the default and not about
      # the host lacking the capability.
      if cap.hardlink:
        check lmHardlink in cap.preferredMechanisms(allowSharedInode = true)
        offeredWhenOptedIn.inc
    checkpoint($offeredWhenOptedIn & " of " & $volumes.len &
               " discovered volumes could have hardlinked (" &
               describeHost() & ")")
    check volumes.len >= 1

  test "copy is always the final arm, so declining to share is always possible":
    ## The property the whole decision rests on: refusing the shared-inode
    ## arm can never leave a caller with no mechanism, because copy cannot
    ## be unavailable. Without it, "the arm stays off" would be a promise
    ## the store could not keep on some filesystem pair.
    for vol in volumes:
      var cache: LinkCapabilityCache
      let cap = probeLinkCapabilities(cache, vol.dir, vol.dir)
      for optIn in [false, true]:
        let mechs = cap.preferredMechanisms(allowSharedInode = optIn)
        check mechs.len >= 1
        check mechs[^1] == lmCopy
        check mechs.count(lmCopy) == 1
    check volumes.len >= 1

# ---------------------------------------------------------------------------

suite "M3 mutation safety — teardown":
  # Deliberately a test rather than an ``addExitProc``: under ORC the
  # exit-proc closure runs after this module's globals are destroyed.
  test "every scratch directory this suite created is removed":
    var survivors: seq[string] = @[]
    for d in scratchDirs:
      var lastError = ""
      try:
        removeDir(extendedPath(d))
      except CatchableError as err:
        lastError = err.msg
      except Defect:
        lastError = "defect while removing"
      if dirExists(extendedPath(d)):
        let why = if lastError.len > 0: " (" & lastError & ")" else: ""
        survivors.add(d & why)
    # Named rather than merely counted: a survivor is almost always a store
    # handle some earlier case left open, and the message has to say which
    # directory so that is findable without re-running under a debugger.
    checkpoint("surviving scratch directories: " & survivors.join(", "))
    check survivors.len == 0
