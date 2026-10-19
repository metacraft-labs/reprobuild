## The execution-observation mark (`ActionResultRecord.observedExecution`):
## certificate issuance attests a reused test result only when the record
## came from an execution this host observed (test-certificates Standard
## §6.2.1; Test-Certificates.milestones.org D16). The mark therefore has to
## be impossible to acquire from outside.
##
## Pinned here, through the production record and install paths on a real
## temporary cache root:
##   * a record `recordActionResult` wrote is read back marked;
##   * the same record installed through `appendActionResultRecord` (the peer
##     cache's install path) is read back UNmarked, even though the caller's
##     copy says it is marked, and the stale sidecar is gone; a sidecar put
##     back from before the install does not mark the rewritten container;
##   * re-recording the execution marks it again;
##   * a sidecar naming another host (a copied cache root) does not mark;
##   * the mark never travels in the record frame (what a peer bundle, the
##     binary cache and the daemon slot carry).
##
## No mocks.

import std/[os, strutils, tempfiles, unittest]

import repro_core
import repro_hash
import repro_local_store

proc weakOf(name: string): ContentDigest =
  ## `repro_build_engine.weakFingerprintFromText`'s construction, written out
  ## so this layer does not import the one above it.
  var bytes = newSeq[byte](name.len)
  for i, ch in name:
    bytes[i] = byte(ord(ch))
  blake3DomainDigest(bytes, hdActionFingerprint)

proc markerCount(cache: ActionCache): int =
  if not dirExists(cache.hotRecordsRoot):
    return
  for path in walkDirRec(cache.hotRecordsRoot):
    if path.endsWith(ObservedExecutionFileExt):
      inc result

suite "execution-observation mark":

  test "set by a local execution, never by an install or a frame":
    let root = createTempDir("repro-observed-execution-", "")
    defer:
      try: removeDir(root)
      except OSError: discard
    let work = root / "work"
    createDir(work)
    writeFile(work / "in.txt", "input\n")
    writeFile(work / "out.txt", "output\n")
    var cache = openActionCache(root / "action-cache", attachShm = false)
    defer: cache.closeShmTier()
    var cas = openLocalCas(root / "cas")
    let weak = weakOf("observed-execution.lifecycle")

    # A local execution is recorded marked, and read back marked.
    let record = cache.recordActionResult(cas, weak, ffpTimestamp,
      [work / "in.txt"], [work / "out.txt"])
    check record.observedExecution
    var hit = cache.lookupActionResult(cas, weak, ffpTimestamp)
    require hit.status == aclHit
    check cache.observedExecutionOf(hit.record)
    check cache.markerCount == 1
    # The hot-metadata path serves records without their strong fingerprint;
    # the query recomputes it from the recorded inputs.
    var stripped = hit.record
    stripped.strongFingerprint = ContentDigest()
    check cache.observedExecutionOf(stripped)

    # The frame does not carry it.
    check not decodeActionResultRecord(
      encodeActionResultRecord(record)).observedExecution

    var savedPath = ""
    for path in walkDirRec(cache.hotRecordsRoot):
      if path.endsWith(ObservedExecutionFileExt):
        savedPath = path
    require savedPath.len > 0
    let saved = readFile(savedPath)

    # Installed as a peer record, the same bytes are no longer marked, even
    # though the copy handed in says otherwise.
    cache.appendActionResultRecord(record)
    hit = cache.lookupActionResult(cas, weak, ffpTimestamp)
    require hit.status == aclHit
    check not cache.observedExecutionOf(hit.record)
    check cache.markerCount == 0
    # A sidecar restored from before the install names the old container,
    # so it does not mark the new one.
    writeFile(savedPath, saved)
    check cache.markerCount == 1
    check not cache.observedExecutionOf(hit.record)

    # Executing it again here restores the mark.
    discard cache.recordActionResult(cas, weak, ffpTimestamp,
      [work / "in.txt"], [work / "out.txt"])
    hit = cache.lookupActionResult(cas, weak, ffpTimestamp)
    require hit.status == aclHit
    check cache.observedExecutionOf(hit.record)

    # A sidecar written on another host (a cache root copied or restored
    # from another machine) does not mark the record here: the sidecar names
    # the host that observed the execution. Simulated by changing the host
    # bytes of this host's own sidecar, which is all a copy would differ in.
    var current = ""
    for path in walkDirRec(cache.hotRecordsRoot):
      if path.endsWith(ObservedExecutionFileExt):
        current = path
    require current.len > 0
    var foreign = readFile(current)
    require foreign.len > 18
    foreign[^1] = (if foreign[^1] == 'x': 'y' else: 'x')
    writeFile(current, foreign)
    check not cache.observedExecutionOf(hit.record)
