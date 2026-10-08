## The input-access sidecar (Cache-Scope P3.4b): how the execution behind a
## local action record accessed each path it observed, kept beside the `.rec`
## because the record frame cannot grow (see `ActionRecordVersion`).
##
## Pinned here: the codec round-trips, and refuses -- as `none`, never as a
## guess -- a sidecar for another record, from another version, or torn; and
## the sidecar lives and dies with its record (written beside it, untouched by
## a republish that never saw it, reaped once the record is gone).
##
## No mocks: entries are written through the production `recordActionResult`
## into a real `ActionCache` on a real temporary directory.

import std/[options, os, strutils, tempfiles, unittest]

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

proc sample(): InputAccesses =
  InputAccesses(
    reads: @["C:/work/proj/src/main.c", "C:/work/proj/src/util.c",
             "C:/work/proj/src/missing.h", "/other/root"],
    probes: @["C:/work/proj/include", "C:/work/proj/include/x.h"],
    enumerations: @[])

proc sidecarPaths(cache: ActionCache): seq[string] =
  if not dirExists(cache.hotRecordsRoot):
    return
  for path in walkDirRec(cache.hotRecordsRoot):
    if path.endsWith(InputAccessFileExt):
      result.add(path)

suite "input-access sidecar":

  test "the codec round-trips, front-coding included":
    let accesses = sample()
    let raw = encodeInputAccesses("ab12", accesses)
    let decoded = decodeInputAccesses(raw, "ab12")
    require decoded.isSome
    check decoded.get() == accesses
    # Shared prefixes are stored once: an action's observations cluster
    # under a few directories, and the sidecar stays well under the plain
    # concatenation of its paths.
    var clustered: InputAccesses
    var plain = 0
    for i in 0 ..< 200:
      let path = "C:/Users/someone/work/checkout/node_modules/pkg-" & $i &
        "/package.json"
      clustered.reads.add(path)
      plain += path.len
    let compact = encodeInputAccesses("ab12", clustered)
    check compact.len * 2 < plain
    check decodeInputAccesses(compact, "ab12").get() == clustered
    check decodeInputAccesses(encodeInputAccesses("ab12", InputAccesses()),
      "ab12").get() == InputAccesses()

  test "a sidecar for another record, version or shape is refused":
    let raw = encodeInputAccesses("ab12", sample())
    check decodeInputAccesses(raw, "cd34").isNone
    var future = raw
    future[4] = 0x7f'u8                   # the version's low byte
    check decodeInputAccesses(future, "ab12").isNone
    var magic = raw
    magic[0] = byte(ord('X'))
    check decodeInputAccesses(magic, "ab12").isNone
    check decodeInputAccesses(raw[0 ..< raw.len - 1], "ab12").isNone
    check decodeInputAccesses(raw & @[0'u8], "ab12").isNone
    check decodeInputAccesses(newSeq[byte](), "ab12").isNone

  test "written beside its record, kept across a republish, reaped after":
    let root = createTempDir("repro-input-access-", "")
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
    let weak = weakOf("input-access.lifecycle")
    let record = cache.recordActionResult(cas, weak, ffpTimestamp,
      [work / "in.txt"], [work / "out.txt"])
    check cache.inputAccessesFor(weak, record.strongFingerprint).isNone
    cache.recordInputAccesses(weak, record.strongFingerprint, sample())
    let stored = cache.inputAccessesFor(weak, record.strongFingerprint)
    require stored.isSome
    check stored.get() == sample()
    # The cache daemon and the peer installer republish records they decoded
    # from a plain frame; neither knows the accesses, and neither may erase
    # them.
    cache.writePerEdgeRecords(weak, [record])
    check cache.inputAccessesFor(weak, record.strongFingerprint).isSome
    # Another record for the same edge cannot read this one's accesses.
    writeFile(work / "in.txt", "changed input\n")
    let other = cache.recordActionResult(cas, weak, ffpTimestamp,
      [work / "in.txt"], [work / "out.txt"])
    require other.strongFingerprint != record.strongFingerprint
    check cache.inputAccessesFor(weak, other.strongFingerprint).isNone
    # Once its record is gone, the next publish in the edge reaps it.
    require cache.sidecarPaths.len == 1
    let owner = cache.sidecarPaths[0].changeFileExt(".rec")
    require fileExists(extendedPath(owner))
    removeFile(extendedPath(owner))
    writeFile(work / "in.txt", "third input\n")
    discard cache.recordActionResult(cas, weak, ffpTimestamp,
      [work / "in.txt"], [work / "out.txt"])
    check cache.sidecarPaths.len == 0
    check cache.inputAccessesFor(weak, record.strongFingerprint).isNone
