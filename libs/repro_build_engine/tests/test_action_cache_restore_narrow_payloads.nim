## Local-CAS-Hardlink-Materialization M2 — ``materializeActionCacheOutputs``
## reads only the payloads it actually needs in memory.
##
## M1 made the Layer-1 facade O(1) in memory: ``casMaterialize`` streams
## each entry into a temp beside its destination and never holds a whole
## payload. But the engine's restore helper still did its own ``casGet``
## over EVERY output first, because a directory output is not a file — its
## blob is a snapshot envelope that ``materializeDirectorySnapshotPayload``
## parses, so it genuinely has to be resident. Pre-reading the regular
## outputs alongside it meant peak memory was still the sum of every output
## being restored, one layer above the seam that had just been fixed. M1's
## review called that "the first thing M2 or M3 picks up, not left to
## drift".
##
## The narrowing is four lines, so the risk is not that it is hard — it is
## that it is invisible. Two things therefore have to be pinned:
##
##   * the memory property itself, measured rather than asserted; and
##   * that nothing was WEAKENED to get it. The old pre-read incidentally
##     verified every blob before any destination was touched, so this
##     file also re-measures the fail-closed guarantee that
##     ``casMaterialize``'s own existence pre-pass and staged-digest
##     verification now carry alone.
##
## The payload slots are indexed BY RECORD POSITION — ``payloads[i]`` is
## read with ``i`` taken from ``record.outputs`` — so the fixtures below
## deliberately put a directory output at a non-zero index. A filtered
## append that renumbered the slots would restore the wrong tree, and the
## round-trip case is what catches it.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_cas_store
import repro_core
import repro_hash
import repro_local_store

proc asBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.m2.narrow." & name),
                     hdActionFingerprint)

proc writeFixture(path, content: string) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), content)

proc bigText(size: int; seed: int): string =
  ## Distinct per seed so a restore that mixed two outputs up is visible.
  result = newString(size)
  for i in 0 ..< size:
    result[i] = char((i * 131 + seed * 17) and 0xFF)

proc restoreHelperBody(): string =
  ## The CODE of ``materializeActionCacheOutputs`` with its comments
  ## stripped, so a structural assertion measures what the proc does rather
  ## than what its comments say about it.
  let src = "libs/repro_build_engine/src/repro_build_engine.nim"
  doAssert fileExists(extendedPath(src)), src & " not found (run from the " &
    "repository root)"
  let text = readFile(extendedPath(src))
  let start = text.find("proc materializeActionCacheOutputs*")
  doAssert start >= 0, "materializeActionCacheOutputs not found in " & src
  let stop = text.find("\nproc ", start + 40)
  doAssert stop > start, "end of materializeActionCacheOutputs not found"
  var kept: seq[string] = @[]
  for line in text[start ..< stop].splitLines():
    let stripped = line.strip()
    if stripped.startsWith("##") or stripped.startsWith("#"):
      continue
    kept.add(line)
  kept.join("\n")

# ---------------------------------------------------------------------------
# Memory. Deliberately the FIRST suite in the file: ``getMaxMem`` is a
# high-water mark that never falls, so the delta it reports is only
# meaningful while the program's ceiling is still low. Measuring around the
# restore call alone — after the fixtures and the record have already raised
# the ceiling — means a pass cannot be manufactured by an earlier
# allocation, while a pre-read of every payload necessarily blows through
# the budget.
# ---------------------------------------------------------------------------

suite "M2 materializeActionCacheOutputs — bounded memory":
  test "restoring many large outputs does not hold them all in memory":
    let tempRoot = createTempDir("repro-m2-narrow-mem-", "")
    defer:
      try: removeDir(extendedPath(tempRoot)) except OSError: discard

    let sharedRoot = tempRoot / ".repro"
    let actionRoot = tempRoot / "work"
    const OutputCount = 8
    const OutputSize = 4 * 1024 * 1024
    const TotalBytes = OutputCount * OutputSize
    # A quarter of the batch. The narrowed helper needs a bounded chunk;
    # the pre-M2 helper needed TotalBytes resident at once.
    const Budget = TotalBytes div 4

    writeFixture(actionRoot / "input.txt", "alpha\n")
    var outputNames: seq[string] = @[]
    for i in 0 ..< OutputCount:
      let name = "out" & $i & ".bin"
      outputNames.add(name)
      # Written and released one at a time so the fixtures do not
      # themselves raise the ceiling to the batch total.
      writeFixture(actionRoot / name, bigText(OutputSize, i))

    var cas = openCasStore(sharedRoot)
    defer: cas.close()
    var cache = openActionCache(sharedRoot / "action-cache")
    let record = cache.recordActionResult(cas.inner, weakFor("mem"),
      ffpChecksum, [actionRoot / "input.txt"], outputNames, actionRoot)
    check record.outputs.len == OutputCount

    for name in outputNames:
      removeFile(extendedPath(actionRoot / name))

    GC_fullCollect()
    let before = getMaxMem()
    cas.materializeActionCacheOutputs(record, actionRoot)
    let grew = getMaxMem() - before
    checkpoint("restored " & $TotalBytes & " bytes across " & $OutputCount &
               " outputs; heap high-water grew by " & $grew &
               " bytes (budget " & $Budget & ")")
    check grew < Budget

    # ...and the bytes are still right, so the bound was not bought by not
    # doing the work.
    for i, name in outputNames:
      check getFileSize(extendedPath(actionRoot / name)) == int64(OutputSize)
    check readFile(extendedPath(actionRoot / outputNames[0])) ==
      bigText(OutputSize, 0)
    check readFile(extendedPath(actionRoot / outputNames[^1])) ==
      bigText(OutputSize, OutputCount - 1)

  test "only directory payloads are read into memory":
    ## A structural guard on the property the measurement above pins: the
    ## helper must not reacquire a whole-record pre-read. ``payloads`` is
    ## still indexed by record position, which is why the pre-sized
    ## ``newSeq`` (holes and all) is the shape being asserted rather than a
    ## filtered append.
    let body = restoreHelperBody()
    check "payloads.add(" notin body
    check "newSeq[seq[byte]](record.outputs.len)" in body
    check "for output in record.outputs:\n    payloads" notin body
    # The one casGet that survives is guarded by the directory test.
    check body.count("casGet") == 1
    let getLine = body.find("casGet")
    let guard = body.rfind("ffkDirectory", last = getLine)
    check guard >= 0
    check guard > body.find("var payloads")

# ---------------------------------------------------------------------------

suite "M2 materializeActionCacheOutputs — nothing was weakened":
  test "a directory output still round-trips alongside regular outputs":
    ## The directory output sits at a NON-ZERO record index on purpose: a
    ## narrowing that renumbered the payload slots instead of leaving holes
    ## would silently hand the snapshot parser the wrong (or an empty)
    ## payload, and this is the case that notices.
    let tempRoot = createTempDir("repro-m2-narrow-dir-", "")
    defer:
      try: removeDir(extendedPath(tempRoot)) except OSError: discard

    let sharedRoot = tempRoot / ".repro"
    let actionRoot = tempRoot / "work"
    writeFixture(actionRoot / "input.txt", "alpha\n")
    writeFixture(actionRoot / "first.txt", "cached first\n")
    writeFixture(actionRoot / "tree" / "nested" / "payload.txt",
                 "cached tree\n")
    createDir(extendedPath(actionRoot / "tree" / "empty"))
    writeFixture(actionRoot / "last.txt", "cached last\n")

    var cas = openCasStore(sharedRoot)
    defer: cas.close()
    var cache = openActionCache(sharedRoot / "action-cache")
    let record = cache.recordActionResult(cas.inner, weakFor("dir"),
      ffpChecksum, [actionRoot / "input.txt"],
      ["first.txt", "tree", "last.txt"], actionRoot)
    require record.outputs.len == 3
    check record.outputs[0].metadata.kind != ffkDirectory
    check record.outputs[1].metadata.kind == ffkDirectory
    check record.outputs[2].metadata.kind != ffkDirectory

    removeFile(extendedPath(actionRoot / "first.txt"))
    removeDir(extendedPath(actionRoot / "tree"))
    removeFile(extendedPath(actionRoot / "last.txt"))

    cas.materializeActionCacheOutputs(record, actionRoot)
    check readFile(extendedPath(actionRoot / "first.txt")) == "cached first\n"
    check readFile(extendedPath(actionRoot / "last.txt")) == "cached last\n"
    check readFile(extendedPath(
      actionRoot / "tree" / "nested" / "payload.txt")) == "cached tree\n"
    check dirExists(extendedPath(actionRoot / "tree" / "empty"))

  test "a corrupt regular-output blob still restores nothing at all":
    ## The pre-read used to carry this for free: every blob was read, and
    ## therefore digest-verified, before any destination was touched. With
    ## the regular outputs no longer pre-read, the guarantee rests entirely
    ## on ``casMaterialize``'s existence pre-pass plus its verification of
    ## each STAGED result before any rename commits. Measured here rather
    ## than assumed, because this is the property the narrowing could most
    ## plausibly have cost.
    let tempRoot = createTempDir("repro-m2-narrow-corrupt-", "")
    defer:
      try: removeDir(extendedPath(tempRoot)) except OSError: discard

    let sharedRoot = tempRoot / ".repro"
    let actionRoot = tempRoot / "work"
    writeFixture(actionRoot / "input.txt", "alpha\n")
    writeFixture(actionRoot / "a.txt", "cached a\n")
    writeFixture(actionRoot / "b.txt", "cached b\n")

    var cas = openCasStore(sharedRoot)
    defer: cas.close()
    var cache = openActionCache(sharedRoot / "action-cache")
    let record = cache.recordActionResult(cas.inner, weakFor("corrupt"),
      ffpChecksum, [actionRoot / "input.txt"], ["a.txt", "b.txt"],
      actionRoot)
    require record.outputs.len == 2

    # Corrupt the SECOND blob in place, keeping its length so nothing
    # short-circuits on size.
    let secondBlob = cas.casPath(
      toContentHash(record.outputs[1].blob.digest.bytes))
    let originalLen = readFile(extendedPath(secondBlob)).len
    writeFile(extendedPath(secondBlob), repeat('x', originalLen))

    removeFile(extendedPath(actionRoot / "a.txt"))
    removeFile(extendedPath(actionRoot / "b.txt"))

    var raised = false
    try:
      cas.materializeActionCacheOutputs(record, actionRoot)
    except ECasDigestMismatch:
      raised = true
    check raised
    check not fileExists(extendedPath(actionRoot / "a.txt"))
    check not fileExists(extendedPath(actionRoot / "b.txt"))

  test "a missing regular-output blob restores nothing at all":
    let tempRoot = createTempDir("repro-m2-narrow-missing-", "")
    defer:
      try: removeDir(extendedPath(tempRoot)) except OSError: discard

    let sharedRoot = tempRoot / ".repro"
    let actionRoot = tempRoot / "work"
    writeFixture(actionRoot / "input.txt", "alpha\n")
    writeFixture(actionRoot / "a.txt", "cached a\n")
    writeFixture(actionRoot / "b.txt", "cached b\n")

    var cas = openCasStore(sharedRoot)
    defer: cas.close()
    var cache = openActionCache(sharedRoot / "action-cache")
    let record = cache.recordActionResult(cas.inner, weakFor("missing"),
      ffpChecksum, [actionRoot / "input.txt"], ["a.txt", "b.txt"],
      actionRoot)
    require record.outputs.len == 2
    removeFile(extendedPath(cas.casPath(
      toContentHash(record.outputs[1].blob.digest.bytes))))
    removeFile(extendedPath(actionRoot / "a.txt"))
    removeFile(extendedPath(actionRoot / "b.txt"))

    var raised = false
    try:
      cas.materializeActionCacheOutputs(record, actionRoot)
    except ECasMissing:
      raised = true
    check raised
    check not fileExists(extendedPath(actionRoot / "a.txt"))
    check not fileExists(extendedPath(actionRoot / "b.txt"))
