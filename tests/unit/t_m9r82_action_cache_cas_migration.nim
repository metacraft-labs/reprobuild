## DA-8. The two STRUCTURAL cases in this suite used to read RAW source text,
## which made both of them satisfiable by a comment: delete the guarded code,
## leave a doc comment that names it, and the audit stays green while asserting
## nothing. Both now read through ``repro_test_support``'s stripper, and the
## mode is chosen PER NEEDLE rather than per case — a scan is graded needle by
## needle, and a needle on the wrong mode is either vacuous or broken while
## both look green.
##
## Which mode each needle is on, and why, is recorded at each needle below.
## The short form: every POSITIVE needle here is a code spelling (a proc
## header, a call, an identifier), so every one of them is read from
## ``nimSourceCodeOnly`` — comments AND literals blanked, because a
## ``checkpoint``/``echo`` argument satisfies such a needle as readily as a
## comment does. Every NEGATIVE needle is read from the RAW text on purpose:
## blanking is the safe direction for a positive assertion and the UNSAFE one
## for a negative, since a forbidden spelling hidden inside a string literal
## would be blanked away and the negative would pass.

import std/[os, strutils, tempfiles, times, unittest]

import repro_build_engine
import repro_cas_store
import repro_core
import repro_hash
import repro_local_store
import repro_test_support

proc asBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.m9r82." & name), hdActionFingerprint)

proc writeFixture(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

proc removeIfExists(path: string) =
  if fileExists(path):
    removeFile(path)

proc r11Hash(blob: CasBlobRef): ContentHash =
  toContentHash(blob.digest.bytes)

proc r11Path(cas: CasStore; blob: CasBlobRef): string =
  cas.casPath(blob.r11Hash())

suite "M9.R.82 action-cache R11 CAS migration":
  test "engine restore path routes through R11 materialization helper":
    # NOT VACUOUS — the stripper this case now depends on is graded here, in
    # both directions, before it is used. `when false:` is a THIRD way to write
    # a comment (Nim only PARSES such a body, it never sem-checks it), so it
    # reaches a lexical stripper as code; the arm that blanks it can fail in
    # two opposite ways and BOTH of them look green from the audits below:
    # under-blanking leaves the bypass open, and over-blanking eats the LIVE
    # `else:` arm of a `when false:` and reddens audits for the wrong reason.
    const WhenFalseFixture =
      "when false:\n" &
      "  let doc = \"\"\"\n" &
      "collect(\"apps\", INERT_IN_LITERAL)\n" &
      "\"\"\"\n" &
      "  echo INERT_AFTER_LITERAL\n" &
      "\n" &
      "  echo INERT_AFTER_BLANK_LINE\n" &
      "else:\n" &
      "  echo LIVE_IN_ELSE_ARM\n" &
      "when false: discard INERT_ONE_LINER\n" &
      "when true:\n" &
      "  echo LIVE_UNDER_WHEN_TRUE\n" &
      "let s = \"when false:\"\n" &
      "echo LIVE_AT_TOP_LEVEL\n"
    for mode in [true, false]:
      let read = nimSourceStripped(WhenFalseFixture, blankStrings = mode)
      # Length and line structure are the premise every offset-anchored slice
      # in this file rests on.
      check read.len == WhenFalseFixture.len
      check read.count('\n') == WhenFalseFixture.count('\n')
      # Inert in both modes: a `when false:` body is a comment.
      check not read.contains("INERT_IN_LITERAL")
      check not read.contains("INERT_AFTER_LITERAL")
      check not read.contains("INERT_AFTER_BLANK_LINE")
      check not read.contains("INERT_ONE_LINER")
      # Live in both modes. Getting the polarity wrong here is a false
      # NEGATIVE, so it is pinned as hard as the blanking is.
      check read.contains("LIVE_IN_ELSE_ARM")
      check read.contains("LIVE_UNDER_WHEN_TRUE")
      check read.contains("LIVE_AT_TOP_LEVEL")
    # A `when false:` written inside a string literal is text, not a block, so
    # it must not move the scan — checked in the mode that keeps literals.
    check nimSourceCommentsBlanked(WhenFalseFixture).contains("when false:\"")

    let engineRaw = readFile(
      "libs/repro_build_engine/src/repro_build_engine.nim")
    let engineCode = nimSourceCodeOnly(engineRaw)
    check engineCode.len == engineRaw.len

    # NEGATIVE needle, so it is read RAW. Blanking would hide a
    # `.restoreOutputs(` spelled inside a string literal, which for a negative
    # is the unsafe direction.
    check not engineRaw.contains(".restoreOutputs(")

    # CODE needles, all three, so all three are read from `engineCode`. The
    # engine's own doc comments name this helper as a precedent (line ~3412
    # today), so over raw text the presence check was satisfied by prose.
    #
    # The needle is also strengthened from "the name appears somewhere" to
    # what the case actually claims: the helper is DECLARED, and BOTH restore
    # arms reach it. Three whole-identifier occurrences = the declaration plus
    # the `aclHit` and `aclHybridCutoff` call sites; a call site that stops
    # sharing the helper drops the count even if it keeps the name in a
    # comment. Counted as a WHOLE identifier, folded the way Nim folds one, so
    # `materialize_action_cache_outputs` — the same symbol to the compiler —
    # counts too.
    check engineCode.contains("proc materializeActionCacheOutputs*(")
    check countNimIdentifier(engineCode, "materializeActionCacheOutputs") >= 3
    # The helper verifies through Layer-1 `casMaterialize` before touching any
    # destination. Graded as an identifier rather than as `.casMaterialize(`
    # because Nim has four spellings of one call and only two carry the dot.
    check containsNimIdentifier(engineCode, "casMaterialize")

  test "Store file blob recording streams through R11 CAS":
    let storeRaw = readFile(
      "libs/repro_local_store/src/repro_local_store.nim")
    let storeCode = nimSourceCodeOnly(storeRaw)
    # The two readings index each other. Both blank IN PLACE and preserve
    # length and newline positions, which is what makes it sound to locate the
    # slice in one and cut it out of the other.
    check storeCode.len == storeRaw.len

    # THE SLICE MARKERS ARE CODE NEEDLES AND ARE LOCATED IN `storeCode`, NOT
    # IN THE RAW TEXT. Cutting the slice out of raw text was the defect: a
    # comment — or a string literal — that re-spells the proc header, or that
    # contains "\nproc ", MOVES the slice, and the assertions inside it are
    # then made about whatever the widened slice happens to contain. That is
    # the hole site 3 of this campaign turned out to have at both of ITS
    # markers. Locating in stripped text and cutting at the SAME offsets is
    # sound precisely because of the length equality checked above.
    let marker = "proc storeFileBlob*(cas: var Store; path: string; sizeBytes: uint64): CasBlobRef ="
    let start = storeCode.find(marker)
    check start >= 0
    if start >= 0:
      let nextProc = storeCode.find("\nproc ", start + marker.len)
      let stop = if nextProc >= 0: nextProc else: storeCode.len
      let bodyCode = storeCode[start ..< stop]
      let bodyRaw = storeRaw[start ..< stop]
      # POSITIVE needles: a call and an identifier, i.e. code. Read from the
      # code-only slice.
      check bodyCode.contains("storeCasFileBlob(path, sizeBytes)")
      check containsNimIdentifier(bodyCode, "r11CasDigest")
      # NEGATIVE needles: read from the RAW slice, for the same reason as the
      # engine negative above — a forbidden spelling must not be able to hide
      # in a literal or a comment.
      check not bodyRaw.contains("readFile")
      check not bodyRaw.contains("storeBlob(payload)")

  test "record writes R11 CAS layout and cache hit restores through helper":
    let tempRoot = createTempDir("repro-m9r82-r11-restore-", "")
    defer:
      try: removeDir(extendedPath(tempRoot)) except OSError: discard

    let sharedRoot = tempRoot / ".repro"
    let actionRoot = tempRoot / "work"
    let inputPath = actionRoot / "input.txt"
    let outputPath = actionRoot / "out.txt"
    writeFixture(inputPath, "alpha\n")
    writeFixture(outputPath, "cached alpha\n")

    var cas = openCasStore(sharedRoot)
    defer: cas.close()
    var cache = openActionCache(sharedRoot / "action-cache")
    let record = cache.recordActionResult(cas.inner, weakFor("r11-restore"),
      ffpChecksum, [inputPath], ["out.txt"], actionRoot)

    let blobHex = $record.outputs[0].blob.r11Hash()
    let r11Object = sharedRoot / "cas" / "blake3" / blobHex[0 .. 1] / blobHex
    let legacyObject = sharedRoot / "cas" / blobHex[0 .. 1] / blobHex[2 .. ^1]
    check cas.r11Path(record.outputs[0].blob) == r11Object
    check fileExists(r11Object)
    check not fileExists(legacyObject)

    removeIfExists(outputPath)
    var reloaded = openActionCache(sharedRoot / "action-cache")
    let hit = reloaded.lookupActionResult(cas.inner, weakFor("r11-restore"),
      ffpChecksum)
    check hit.status == aclHit
    cas.materializeActionCacheOutputs(hit.record, actionRoot)
    check readFile(outputPath) == "cached alpha\n"

  test "directory outputs round-trip through R11 CAS":
    let tempRoot = createTempDir("repro-m9r82-r11-directory-", "")
    defer:
      try: removeDir(extendedPath(tempRoot)) except OSError: discard

    let sharedRoot = tempRoot / ".repro"
    let actionRoot = tempRoot / "work"
    let inputPath = actionRoot / "input.txt"
    let outputDir = actionRoot / "tree"
    writeFixture(inputPath, "alpha\n")
    writeFixture(outputDir / "nested" / "payload.txt", "cached tree\n")
    createDir(outputDir / "empty")
    when defined(posix):
      createSymlink("nested/payload.txt", outputDir / "payload-link")

    var cas = openCasStore(sharedRoot)
    defer: cas.close()
    var cache = openActionCache(sharedRoot / "action-cache")
    let record = cache.recordActionResult(cas.inner,
      weakFor("r11-directory"), ffpChecksum, [inputPath], ["tree"],
      actionRoot)
    require record.outputs.len == 1
    check record.outputs[0].metadata.kind == ffkDirectory
    let snapshot = cas.casGet(record.outputs[0].blob.r11Hash())
    check snapshot.len >= 4
    check snapshot[0 .. 3] == @[byte('R'), byte('B'), byte('D'), byte('T')]

    removeDir(outputDir)
    var reloaded = openActionCache(sharedRoot / "action-cache")
    let hit = reloaded.lookupActionResult(cas.inner,
      weakFor("r11-directory"), ffpChecksum)
    check hit.status == aclHit
    cas.materializeActionCacheOutputs(hit.record, actionRoot)
    check readFile(outputDir / "nested" / "payload.txt") == "cached tree\n"
    check dirExists(outputDir / "empty")
    when defined(posix):
      check symlinkExists(outputDir / "payload-link")
      check expandSymlink(outputDir / "payload-link") == "nested/payload.txt"

    writeFile(outputDir / "stale.txt", "must be replaced\n")
    cas.materializeActionCacheOutputs(hit.record, actionRoot)
    check not fileExists(outputDir / "stale.txt")
    check readFile(outputDir / "nested" / "payload.txt") == "cached tree\n"

  test "legacy LocalCas records reject cleanly under R11 verifier":
    let tempRoot = createTempDir("repro-m9r82-legacy-reject-", "")
    defer:
      try: removeDir(extendedPath(tempRoot)) except OSError: discard

    let sharedRoot = tempRoot / ".repro"
    let actionRoot = tempRoot / "work"
    let inputPath = actionRoot / "input.txt"
    let outputPath = actionRoot / "out.txt"
    writeFixture(inputPath, "alpha\n")
    writeFixture(outputPath, "legacy cached alpha\n")

    let legacyCas = openLocalCas(sharedRoot / "cas")
    var cache = openActionCache(sharedRoot / "action-cache")
    discard cache.recordActionResult(legacyCas, weakFor("legacy-record"),
      ffpChecksum, [inputPath], ["out.txt"], actionRoot)
    removeIfExists(outputPath)

    var r11Cas = openCasStore(sharedRoot)
    defer: r11Cas.close()
    let lookup = cache.lookupActionResult(r11Cas.inner, weakFor("legacy-record"),
      ffpChecksum)
    check lookup.status == aclRejectedCorruptOutput
    check not fileExists(outputPath)

  test "hybrid cutoff uses same R11 materialization helper":
    let tempRoot = createTempDir("repro-m9r82-hybrid-", "")
    defer:
      try: removeDir(extendedPath(tempRoot)) except OSError: discard

    let sharedRoot = tempRoot / ".repro"
    let actionRoot = tempRoot / "work"
    let inputPath = actionRoot / "input.txt"
    let outputPath = actionRoot / "out.txt"
    writeFixture(inputPath, "alpha\n")
    writeFixture(outputPath, "hybrid cached alpha\n")

    var cas = openCasStore(sharedRoot)
    defer: cas.close()
    var cache = openActionCache(sharedRoot / "action-cache")
    let record = cache.recordActionResult(cas.inner, weakFor("hybrid-cutoff"),
      ffpHybrid, [inputPath], ["out.txt"], actionRoot)
    let priorMetadata = record.inputs[0].metadata

    removeIfExists(outputPath)
    setLastModificationTime(inputPath,
      getFileInfo(inputPath).lastWriteTime + initDuration(seconds = 10))
    let cutoff = cache.lookupActionResult(cas.inner, weakFor("hybrid-cutoff"),
      ffpHybrid)
    check cutoff.status == aclHybridCutoff
    check cutoff.record.inputs[0].metadata != priorMetadata
    cas.materializeActionCacheOutputs(cutoff.record, actionRoot)
    check readFile(outputPath) == "hybrid cached alpha\n"

  test "corrupt later R11 blob rejects without partial output restore":
    let tempRoot = createTempDir("repro-m9r82-fail-closed-", "")
    defer:
      try: removeDir(extendedPath(tempRoot)) except OSError: discard

    let sharedRoot = tempRoot / ".repro"
    let actionRoot = tempRoot / "work"
    let inputPath = actionRoot / "input.txt"
    let outputA = actionRoot / "a.txt"
    let outputB = actionRoot / "b.txt"
    writeFixture(inputPath, "alpha\n")
    writeFixture(outputA, "cached a\n")
    writeFixture(outputB, "cached b\n")

    var cas = openCasStore(sharedRoot)
    defer: cas.close()
    var cache = openActionCache(sharedRoot / "action-cache")
    let record = cache.recordActionResult(cas.inner, weakFor("corrupt-later"),
      ffpChecksum, [inputPath], ["a.txt", "b.txt"], actionRoot)
    writeFile(cas.r11Path(record.outputs[1].blob), "corrupted later blob\n")
    removeIfExists(outputA)
    removeIfExists(outputB)

    let lookup = cache.lookupActionResult(cas.inner, weakFor("corrupt-later"),
      ffpChecksum)
    check lookup.status == aclRejectedCorruptOutput

    var raised = false
    try:
      cas.materializeActionCacheOutputs(record, actionRoot)
    except ECasDigestMismatch:
      raised = true
    check raised
    check not fileExists(outputA)
    check not fileExists(outputB)

  test "metadata-only records remain non-restorable payload hits":
    let tempRoot = createTempDir("repro-m9r82-metadata-only-", "")
    defer:
      try: removeDir(extendedPath(tempRoot)) except OSError: discard

    let sharedRoot = tempRoot / ".repro"
    let actionRoot = tempRoot / "work"
    let inputPath = actionRoot / "input.txt"
    let outputPath = actionRoot / "out.txt"
    writeFixture(inputPath, "alpha\n")
    writeFixture(outputPath, "metadata only\n")

    var cas = openCasStore(sharedRoot)
    defer: cas.close()
    var cache = openActionCache(sharedRoot / "action-cache")
    let record = cache.recordActionResult(cas.inner, weakFor("metadata-only"),
      ffpHybrid, [inputPath], ["out.txt"], actionRoot,
      storeOutputBlobs = false)
    check record.outputPayloadKind == opkMetadataOnly

    let metadataHit = cache.lookupActionResult(cas.inner,
      weakFor("metadata-only"), ffpHybrid, verifyOutputBlobs = false)
    check metadataHit.status == aclHit

    removeIfExists(outputPath)
    let restoreLookup = cache.lookupActionResult(cas.inner,
      weakFor("metadata-only"), ffpHybrid)
    check restoreLookup.status == aclMissNoOutputPayload
    expect CacheIntegrityError:
      cas.materializeActionCacheOutputs(record, actionRoot)
    check not fileExists(outputPath)
