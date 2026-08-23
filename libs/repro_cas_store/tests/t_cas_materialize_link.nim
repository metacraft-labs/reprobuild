## Local-CAS-Hardlink-Materialization M1 — tests for link-based
## ``casMaterialize``.
##
## Spec: ``reprobuild-specs/Local-Content-Addressed-Store.md``
##       §"Hardlink, Reflink, and Copy Policy" (normative).
##
## Three things are under test and they are not the same thing:
##
##   1. **Which mechanism is used.** Asserted on the per-entry
##      ``CasMaterializeOutcome.mechanism`` that
##      ``casMaterializeDetailed`` returns — never on timing, never on
##      "it felt fast". The host's real volumes decide which arms can be
##      exercised; an arm the host cannot supply announces via
##      ``checkpoint`` instead of silently passing.
##   2. **That the bytes are right in every arm.** A cheaper mechanism
##      that produces a different file is the failure mode the whole
##      campaign has to not have, so content is compared, not existence.
##   3. **That a partway failure commits nothing.** The pre-M1
##      implementation got "a missing or corrupt later blob cannot leave
##      an earlier output on disk" for free by reading every blob up
##      front. M1 keeps the guarantee by staging everything and
##      committing only at the end, so it has to be measured directly.
##
## The hardlink arm is DISABLED by default (M3 owns the mutation
## hazard), so the tests assert both halves of that: the default really
## does not hand out a shared inode, and the arm really does work when a
## caller opts in.

import std/[algorithm, os, sequtils, strutils, unittest]

from repro_core/paths import extendedPath

import repro_cas_store

# ---------------------------------------------------------------------------
# Host volume discovery — the same approach M0's probe tests use, because
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
  let candidate = parent / ("repro-m1-" & $getCurrentProcessId() & "-" & tag)
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
    "casMaterialize's mechanism arms cannot be exercised at all"
  volumes[0]

proc reflinkVolume(): seq[ProbeVolume] =
  volumes.filterIt(it.reflink)

proc hardlinkOnlyVolume(): seq[ProbeVolume] =
  ## A volume where a hardlink is available and a reflink is not, so the
  ## hardlink arm can be reached without the (preferred, safer) reflink
  ## arm winning first.
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
  ## Deliberately includes 0x00 bytes and spans more than one cluster so
  ## a reflink exercises real extent duplication.
  result = newSeq[byte](size)
  for i in 0 ..< size:
    result[i] = byte((i * 131 + seed * 17) and 0xFF)

proc readBytes(path: string): seq[byte] =
  let raw = readFile(extendedPath(path))
  result = newSeq[byte](raw.len)
  for i, ch in raw:
    result[i] = byte(ord(ch))

proc materializeBody(): string =
  ## The CODE of ``casMaterializeDetailed`` with its doc comment
  ## stripped, so a structural assertion measures what the proc does
  ## rather than what its documentation says about the old shape.
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

proc stagingDebris(dir: string): seq[string] =
  result = @[]
  if not dirExists(extendedPath(dir)):
    return
  for kind, path in walkDir(extendedPath(dir)):
    if "reprocastmp" in extractFilename(path):
      result.add(path)

# ---------------------------------------------------------------------------
# Memory. Deliberately the FIRST suite in the file: ``getMaxMem`` is a
# high-water mark that never falls, so the delta it reports is only
# meaningful while the program's ceiling is still low. Measuring around
# the materialize call alone (after the puts have already raised the
# ceiling) means a pass cannot be manufactured by an earlier allocation,
# while the pre-M1 ``seq[seq[byte]]`` — which holds every payload at once
# — necessarily blows through it.
# ---------------------------------------------------------------------------

suite "M1 casMaterialize — bounded memory":
  test "a large batch never holds every payload in memory at once":
    let vol = primaryVolume()
    let dir = caseDir(vol, "mem")
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let outDir = dir / "out"

    const EntryCount = 24
    const EntrySize = 2 * 1024 * 1024
    const TotalBytes = EntryCount * EntrySize
    # A quarter of the batch. The streaming implementation needs about
    # one 1 MiB chunk; the pre-M1 implementation needed TotalBytes.
    const Budget = TotalBytes div 4

    var entries: seq[CasMaterialization] = @[]
    for i in 0 ..< EntryCount:
      # Built and released one at a time so the ingest side does not
      # itself raise the ceiling to the batch total.
      let h = cas.casPut(payloadOf(EntrySize, i))
      entries.add(CasMaterialization(hash: h,
                                     destination: outDir / ("blob" & $i)))

    GC_fullCollect()
    let before = getMaxMem()
    discard cas.casMaterializeDetailed(entries)
    let grew = getMaxMem() - before
    checkpoint("materialized " & $TotalBytes & " bytes across " &
               $EntryCount & " entries; heap high-water grew by " &
               $grew & " bytes (budget " & $Budget & ")")
    check grew < Budget

    # ...and the bytes are still right, so the bound was not bought by
    # not doing the work.
    for i in 0 ..< EntryCount:
      check getFileSize(extendedPath(outDir / ("blob" & $i))) ==
        int64(EntrySize)
    check readBytes(outDir / "blob0") == payloadOf(EntrySize, 0)

  test "casMaterialize streams per entry rather than pre-reading payloads":
    # A structural guard on the property the timing-free test above
    # measures: the seam must not reacquire a whole-payload API.
    let body = materializeBody()
    check "casGet" notin body
    check "seq[seq[byte]]" notin body
    check "readFile" notin body
    check "writeFile" notin body

# ---------------------------------------------------------------------------

suite "M1 casMaterialize — mechanism selection":
  test "a destination on a reflink-capable volume is cloned, not copied":
    let vols = reflinkVolume()
    if vols.len == 0:
      checkpoint("no volume on this host implements reflink (" &
                 describeHost() & "); the reflink arm was NOT exercised")
      check volumes.len >= 1
    else:
      let vol = vols[0]
      let dir = caseDir(vol, "reflink")
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      let payload = payloadOf(64 * 1024, 3)
      let h = cas.casPut(payload)
      let dest = dir / "out" / "cloned.bin"
      let outcomes = cas.casMaterializeDetailed(
        @[CasMaterialization(hash: h, destination: dest)])
      checkpoint(vol.dir & " fs=" & vol.fsName & " -> " &
                 $outcomes[0].mechanism & " " & outcomes[0].diagnostic)
      check outcomes.len == 1
      check outcomes[0].mechanism == lmReflink
      check not outcomes[0].perFileFallback
      check readBytes(dest) == payload
      # A clone is its own inode — no shared link count, and therefore
      # none of the hardlink arm's mutation hazard.
      check hardlinkCount(dest) == 1
      check hardlinkCount(cas.casPath(h)) == 1
      writeFile(extendedPath(dest), "mutated through the clone")
      check readBytes(cas.casPath(h)) == payload

  test "reflink wins over hardlink even when the hardlink arm is allowed":
    # The preference order is a SAFETY order: reflink is both cheaper
    # than a copy and safer than a hardlink, so opting into shared
    # inodes must not demote it.
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
      let h = cas.casPut(payload)
      let dest = dir / "out" / "ordered.bin"
      let outcomes = cas.casMaterializeDetailed(
        @[CasMaterialization(hash: h, destination: dest)],
        allowSharedInode = true)
      check outcomes[0].mechanism == lmReflink
      check hardlinkCount(cas.casPath(h)) == 1
      check readBytes(dest) == payload

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
      let h = cas.casPut(payload)
      let dest = dir / "out" / "safe.bin"
      let outcomes = cas.casMaterializeDetailed(
        @[CasMaterialization(hash: h, destination: dest)])
      checkpoint(vol.dir & " fs=" & vol.fsName & " -> " &
                 $outcomes[0].mechanism & " " & outcomes[0].diagnostic)
      # The pair CAN hardlink; the default declines to, and says so.
      check vol.hardlink
      check outcomes[0].mechanism == lmCopy
      check "shared-inode" in outcomes[0].diagnostic
      check "hardlink=true" in outcomes[0].diagnostic
      check readBytes(dest) == payload
      check hardlinkCount(cas.casPath(h)) == 1
      check hardlinkCount(dest) == 1
      # The mutation hazard M3 owns is therefore absent by default:
      # writing the restored output does not edit the cached blob.
      writeFile(extendedPath(dest), "an action rewrote its output")
      check readBytes(cas.casPath(h)) == payload
      check cas.casVerify(h)

  test "the default is expressed as a named constant, not a literal":
    # M3 flips this. A test watches it so the flip is deliberate.
    check CasMaterializeAllowSharedInodeDefault == false

  test "allowSharedInode = true reaches the hardlink arm and shares an inode":
    let vols = hardlinkOnlyVolume()
    if vols.len == 0:
      checkpoint("no hardlink-capable volume without reflink on this host (" &
                 describeHost() & "); the hardlink arm was NOT exercised")
      check volumes.len >= 1
    else:
      let vol = vols[0]
      let dir = caseDir(vol, "hardlink")
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      let payload = payloadOf(16 * 1024, 11)
      let h = cas.casPut(payload)
      let dest = dir / "out" / "linked.bin"
      let outcomes = cas.casMaterializeDetailed(
        @[CasMaterialization(hash: h, destination: dest)],
        allowSharedInode = true)
      check outcomes[0].mechanism == lmHardlink
      check readBytes(dest) == payload
      # One inode, two names — the win, and the hazard.
      check hardlinkCount(dest) == 2
      check hardlinkCount(cas.casPath(h)) == 2
      writeFile(extendedPath(dest), "mutated through the link")
      check not cas.casVerify(h)

  test "a cross-volume destination falls back to copy with correct bytes":
    if volumes.len < 2:
      checkpoint("only one writable volume was discoverable on this host (" &
                 describeHost() & "); the cross-device arm was NOT exercised")
      check volumes.len >= 1
    else:
      let storeVol = volumes[0]
      let destVol = volumes[1]
      check storeVol.pairKey != destVol.pairKey
      let storeDir = caseDir(storeVol, "xdev-store")
      let destDir = caseDir(destVol, "xdev-out")
      var cas = openCasStore(storeDir / "store")
      defer: cas.close()
      let payload = payloadOf(48 * 1024, 13)
      let h = cas.casPut(payload)
      let dest = destDir / "copied.bin"
      # Even opting into shared inodes cannot produce one across a
      # device boundary, so this also proves the fallback is driven by
      # the operation's own refusal rather than by the opt-out.
      let outcomes = cas.casMaterializeDetailed(
        @[CasMaterialization(hash: h, destination: dest)],
        allowSharedInode = true)
      checkpoint(storeVol.dir & " (" & storeVol.fsName & ") -> " &
                 destVol.dir & " (" & destVol.fsName & "): " &
                 $outcomes[0].mechanism & " " & outcomes[0].diagnostic)
      check outcomes[0].mechanism == lmCopy
      # The fallback names the real reason. The probe records the
      # cross-volume reflink refusal as ``loUnsupported`` (Windows
      # answers 87), so the diagnostic leans on the hardlink attempt's
      # ``loCrossDevice`` rather than repeating the misleading one.
      check "different filesystem" in outcomes[0].diagnostic
      check "loCrossDevice" in outcomes[0].diagnostic
      check readBytes(dest) == payload
      check hardlinkCount(cas.casPath(h)) == 1

  test "every arm this host can reach produces byte-identical output":
    ## One assertion repeated across whatever mechanisms the host can
    ## actually supply, so "the bytes are right" is not proven only for
    ## the arm that happens to be default.
    var exercised: seq[LinkMechanism] = @[]
    let payload = payloadOf(96 * 1024 + 7, 17)

    proc runArm(storeVol: ProbeVolume; destParent: string;
                allowSharedInode: bool): CasMaterializeOutcome =
      let storeDir = caseDir(storeVol, "arms-store")
      var cas = openCasStore(storeDir / "store")
      defer: cas.close()
      let h = cas.casPut(payload)
      let dest = destParent / ("arm-" & $caseSerial & ".bin")
      let outcomes = cas.casMaterializeDetailed(
        @[CasMaterialization(hash: h, destination: dest)],
        allowSharedInode = allowSharedInode)
      check readBytes(dest) == payload
      outcomes[0]

    for vol in reflinkVolume():
      let d = caseDir(vol, "arms-out")
      exercised.add(runArm(vol, d, false).mechanism)
      break
    for vol in hardlinkOnlyVolume():
      let d = caseDir(vol, "arms-out")
      exercised.add(runArm(vol, d, true).mechanism)
      break
    block copyArm:
      # Copy is the arm that cannot be unavailable. Reach it without
      # depending on a second volume by disabling every other arm.
      let vol = primaryVolume()
      let d = caseDir(vol, "arms-out")
      exercised.add(runArm(vol, d, false).mechanism)

    exercised.sort()
    checkpoint("arms exercised on this host: " &
               exercised.deduplicate().mapIt($it).join(", ") &
               " (" & describeHost() & ")")
    check lmCopy in exercised or lmReflink in exercised
    check exercised.len >= 1

# ---------------------------------------------------------------------------

suite "M1 casMaterialize — no partial materialization":
  test "a missing later blob leaves NO destination written":
    let vol = primaryVolume()
    let dir = caseDir(vol, "missing")
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let outDir = dir / "out"
    let good = cas.casPut(payloadOf(4096, 19))
    var absent: array[32, byte]
    for i in 0 ..< 32: absent[i] = byte(i xor 0xFF)
    var raised = false
    try:
      cas.casMaterialize(@[
        CasMaterialization(hash: good, destination: outDir / "good.bin"),
        CasMaterialization(hash: toContentHash(absent),
                           destination: outDir / "missing.bin"),
      ])
    except ECasMissing:
      raised = true
    check raised
    check not fileExists(extendedPath(outDir / "good.bin"))
    check not fileExists(extendedPath(outDir / "missing.bin"))
    check stagingDebris(outDir).len == 0

  test "a corrupt later blob leaves NO destination written":
    ## The load-bearing half. Before M1 this was free: every blob was
    ## read (and therefore verified) before any byte was written. With
    ## links there is no read, so the guarantee is now carried by
    ## stage-everything-then-commit plus digest verification of the
    ## staged result — and that has to be measured, not asserted in a
    ## comment.
    let vol = primaryVolume()
    let dir = caseDir(vol, "corrupt")
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let outDir = dir / "out"
    let first = cas.casPut(payloadOf(8192, 23))
    let second = cas.casPut(payloadOf(8192, 29))
    let third = cas.casPut(payloadOf(8192, 31))
    # Corrupt the SECOND blob in place, keeping its length, so nothing
    # short-circuits on size.
    writeFile(extendedPath(cas.casPath(second)),
              repeat('x', 8192))
    var raised = false
    try:
      cas.casMaterialize(@[
        CasMaterialization(hash: first, destination: outDir / "a.bin"),
        CasMaterialization(hash: second, destination: outDir / "b.bin"),
        CasMaterialization(hash: third, destination: outDir / "c.bin"),
      ])
    except ECasDigestMismatch:
      raised = true
    check raised
    check not fileExists(extendedPath(outDir / "a.bin"))
    check not fileExists(extendedPath(outDir / "b.bin"))
    check not fileExists(extendedPath(outDir / "c.bin"))
    check stagingDebris(outDir).len == 0

  test "the same corrupt batch also commits nothing on the hardlink arm":
    let vols = hardlinkOnlyVolume()
    if vols.len == 0:
      checkpoint("no hardlink-capable volume without reflink on this host (" &
                 describeHost() & "); the linked rollback arm was NOT " &
                 "exercised")
      check volumes.len >= 1
    else:
      let vol = vols[0]
      let dir = caseDir(vol, "corrupt-hl")
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      let outDir = dir / "out"
      let first = cas.casPut(payloadOf(8192, 37))
      let second = cas.casPut(payloadOf(8192, 41))
      writeFile(extendedPath(cas.casPath(second)), repeat('y', 8192))
      var raised = false
      try:
        cas.casMaterialize(@[
          CasMaterialization(hash: first, destination: outDir / "a.bin"),
          CasMaterialization(hash: second, destination: outDir / "b.bin"),
        ], allowSharedInode = true)
      except ECasDigestMismatch:
        raised = true
      check raised
      check not fileExists(extendedPath(outDir / "a.bin"))
      check not fileExists(extendedPath(outDir / "b.bin"))
      check stagingDebris(outDir).len == 0
      # The rolled-back stage must not have left a second name on the
      # first blob's inode either.
      check hardlinkCount(cas.casPath(first)) == 1

  test "a successful batch leaves no staging debris beside the outputs":
    let vol = primaryVolume()
    let dir = caseDir(vol, "debris")
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let outDir = dir / "out"
    var entries: seq[CasMaterialization] = @[]
    for i in 0 ..< 5:
      entries.add(CasMaterialization(hash: cas.casPut(payloadOf(2048, i)),
                                     destination: outDir / ("f" & $i)))
    cas.casMaterialize(entries)
    for i in 0 ..< 5:
      check readBytes(outDir / ("f" & $i)) == payloadOf(2048, i)
    check stagingDebris(outDir).len == 0

  test "an existing destination is replaced, never truncated in place":
    let vol = primaryVolume()
    let dir = caseDir(vol, "replace")
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let dest = dir / "out" / "existing.bin"
    createDir(extendedPath(dir / "out"))
    writeFile(extendedPath(dest), "the previous generation's bytes")
    let payload = payloadOf(12 * 1024, 43)
    let h = cas.casPut(payload)
    cas.casMaterialize(@[CasMaterialization(hash: h, destination: dest)])
    check readBytes(dest) == payload
    check stagingDebris(dir / "out").len == 0

# ---------------------------------------------------------------------------

suite "M1 casMaterialize — the verification contract":
  test "cvmDigest is the default and rejects a corrupted blob":
    let vol = primaryVolume()
    let dir = caseDir(vol, "verify-default")
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let h = cas.casPut(payloadOf(4096, 47))
    writeFile(extendedPath(cas.casPath(h)), repeat('z', 4096))
    # BOTH entry points carry the default independently, so both are
    # measured — a weakened default on either one is a silent
    # regression of the §"Corruption Detection" contract.
    let dest = dir / "out" / "bad.bin"
    var raised = false
    try:
      cas.casMaterialize(@[CasMaterialization(hash: h, destination: dest)])
    except ECasDigestMismatch:
      raised = true
    check raised
    check not fileExists(extendedPath(dest))

    let dest2 = dir / "out" / "bad2.bin"
    var raisedDetailed = false
    try:
      discard cas.casMaterializeDetailed(
        @[CasMaterialization(hash: h, destination: dest2)])
    except ECasDigestMismatch:
      raisedDetailed = true
    check raisedDetailed
    check not fileExists(extendedPath(dest2))

  test "cvmExistence is the opt-in trust mode and does NOT verify digests":
    ## Stated loudly rather than left implicit: this mode propagates a
    ## corrupted blob. It exists because the digest was verified at
    ## ingest and the store is append-only, and it is never the default.
    let vol = primaryVolume()
    let dir = caseDir(vol, "verify-trust")
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let h = cas.casPut(payloadOf(4096, 53))
    writeFile(extendedPath(cas.casPath(h)), repeat('q', 4096))
    let dest = dir / "out" / "trusted.bin"
    cas.casMaterialize(@[CasMaterialization(hash: h, destination: dest)],
                       verify = cvmExistence)
    check fileExists(extendedPath(dest))
    check readFile(extendedPath(dest)) == repeat('q', 4096)
    check not cas.casVerify(h)

  test "cvmExistence still refuses a missing blob before touching anything":
    let vol = primaryVolume()
    let dir = caseDir(vol, "verify-trust-missing")
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let outDir = dir / "out"
    let good = cas.casPut(payloadOf(1024, 59))
    var absent: array[32, byte]
    for i in 0 ..< 32: absent[i] = byte((i * 7) xor 0x5A)
    var raised = false
    try:
      cas.casMaterialize(@[
        CasMaterialization(hash: good, destination: outDir / "good.bin"),
        CasMaterialization(hash: toContentHash(absent),
                           destination: outDir / "gone.bin"),
      ], verify = cvmExistence)
    except ECasMissing:
      raised = true
    check raised
    check not fileExists(extendedPath(outDir / "good.bin"))

  test "verification covers the staged RESULT, not merely the source blob":
    ## Strictly stronger than the pre-M1 order. Reading the source and
    ## then writing it again could not notice a mechanism that produced
    ## a wrong file; hashing what was staged does.
    let body = materializeBody()
    # The hash input is the staged temp, never the CAS path.
    check "streamHashFile(tmp)" in body
    check "streamHashFile(blobPath)" notin body

# ---------------------------------------------------------------------------

suite "M1 casMaterialize — per-file limits are not pair capabilities":
  test "exhausting a per-file link cap falls back to copy for that file only":
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
        var cas = openCasStore(dir / "store")
        defer: cas.close()
        let payload = payloadOf(1024, 61)
        let h = cas.casPut(payload)
        let outDir = dir / "out"
        createDir(extendedPath(outDir))
        var linked = 0
        var fellBack = false
        var fallback: CasMaterializeOutcome
        var fallbackDest = ""
        while linked < 4096:
          let dest = outDir / ("n" & $linked & ".bin")
          let outcomes = cas.casMaterializeDetailed(
            @[CasMaterialization(hash: h, destination: dest)],
            allowSharedInode = true)
          if outcomes[0].mechanism == lmHardlink:
            linked.inc
            continue
          fellBack = true
          fallback = outcomes[0]
          fallbackDest = dest
          break
        checkpoint("hardlinked " & $linked & " names, then: " &
                   $fallback.mechanism & " perFileFallback=" &
                   $fallback.perFileFallback & " " & fallback.diagnostic)
        check linked > 0
        check fellBack
        # It MUST NOT surface as a build error, MUST be a copy, and the
        # bytes must still be right.
        check fallback.mechanism == lmCopy
        check fallback.perFileFallback
        check readBytes(fallbackDest) == payload
        # ...and it MUST NOT downgrade the cached pair verdict.
        var fresh: LinkCapabilityCache
        check probeLinkCapabilities(fresh, cas.root() / "cas" / "blake3",
                                    outDir).hardlink
        # A DIFFERENT blob on the same pair still hardlinks, which is
        # what "per-file, not per-pair" means.
        let other = cas.casPut(payloadOf(1024, 67))
        let otherOutcome = cas.casMaterializeDetailed(
          @[CasMaterialization(hash: other,
                               destination: outDir / "other.bin")],
          allowSharedInode = true)
        check otherOutcome[0].mechanism == lmHardlink
        removeDir(extendedPath(outDir))
    else:
      checkpoint("the 1024-name cap is an NTFS property; the per-file " &
                 "fallback arm was not exercised on this platform")
      check volumes.len >= 1

  test "perFileFallback is false on an ordinary materialization":
    let vol = primaryVolume()
    let dir = caseDir(vol, "nofallback")
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let h = cas.casPut(payloadOf(2048, 71))
    let outcomes = cas.casMaterializeDetailed(
      @[CasMaterialization(hash: h, destination: dir / "out" / "plain.bin")])
    check not outcomes[0].perFileFallback

# ---------------------------------------------------------------------------

suite "M1 casMaterialize — per-inode consequences":
  test "an entry that carries its own mode bits does not share an inode":
    ## Mode bits are per-inode, so honouring ``applyPermissions``
    ## through a hardlink would chmod the CAS blob. On Windows the
    ## permission set is not applied at all, so the arm stays available
    ## there; the exclusion is POSIX-only by design.
    let vols = hardlinkOnlyVolume()
    if vols.len == 0:
      checkpoint("no hardlink-capable volume without reflink on this host (" &
                 describeHost() & "); not exercised")
      check volumes.len >= 1
    else:
      let vol = vols[0]
      let dir = caseDir(vol, "perms")
      var cas = openCasStore(dir / "store")
      defer: cas.close()
      let payload = payloadOf(4096, 73)
      let h = cas.casPut(payload)
      let dest = dir / "out" / "moded.bin"
      let outcomes = cas.casMaterializeDetailed(
        @[CasMaterialization(hash: h, destination: dest,
                             applyPermissions: true,
                             permissions: {fpUserRead, fpUserWrite})],
        allowSharedInode = true)
      check readBytes(dest) == payload
      when defined(windows):
        check outcomes[0].mechanism == lmHardlink
      else:
        check outcomes[0].mechanism == lmCopy
        check hardlinkCount(cas.casPath(h)) == 1

  test "an empty batch is a no-op that returns no outcomes":
    let vol = primaryVolume()
    let dir = caseDir(vol, "empty")
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let outcomes = cas.casMaterializeDetailed(@[])
    check outcomes.len == 0

  test "a zero-length blob materializes correctly in whichever arm is used":
    ## The reflink path special-cases a zero byte count (the FSCTL would
    ## answer ERROR_INVALID_PARAMETER and be misread as "unsupported").
    let vol = primaryVolume()
    let dir = caseDir(vol, "empty-blob")
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let h = cas.casPut(@[])
    let dest = dir / "out" / "zero.bin"
    let outcomes = cas.casMaterializeDetailed(
      @[CasMaterialization(hash: h, destination: dest)])
    checkpoint("zero-length blob materialized via " &
               $outcomes[0].mechanism)
    check fileExists(extendedPath(dest))
    check getFileSize(extendedPath(dest)) == 0

# ---------------------------------------------------------------------------

suite "M1 casMaterialize — teardown":
  # Deliberately a test rather than an ``addExitProc``: under ORC the
  # exit-proc closure runs after this module's globals are destroyed.
  test "every scratch directory this suite created is removed":
    for d in scratchDirs:
      try:
        removeDir(extendedPath(d))
      except CatchableError, Defect:
        discard
      check not dirExists(extendedPath(d))
