## Action-Cache-Per-Edge-Store.md §5.5 — C1 (the newest candidate must be
## addressable) and C4 (intern paths within a record).
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every case drives the production `ActionCache` over a real `Store` on a
## real temporary directory, records through the production
## `recordActionResult`, and reads through the production `readHotRecord` /
## `loadPerEdgeRecords`. The properties under test are properties of the
## FILES on disk and of the work performed to read them, so a substituted
## store would make the file vacuous: it would count a fake's reads.
##
## WHY THE COUNTER AND NOT A STOPWATCH
##
## C1's normative property is "the cost of a consultation MUST be
## proportional to the candidates it evaluates, not to the candidates the
## edge has". On a shared machine the same warm no-op measured 351 ms and
## 108 ms an hour apart, so elapsed time cannot demonstrate that at all.
## `actionRecordDecodeStats()` can: it counts decoded record frames, their
## bytes, and the container and sidecar files read to get them. The cases
## below assert on counts.
##
## WHY THE COUNTS ARE NOT VACUOUS
##
## A counter that never moved would satisfy "decodes one record" trivially.
## Every C1 case therefore has a paired control in the same test body: the
## alias is removed, or invalidated, and the SAME read is required to decode
## every container in the directory. A counter stuck at zero — or one that
## stopped counting — fails the control before it can pass the claim.

import std/[algorithm, options, os, sequtils, strutils, tempfiles, unittest]

import repro_core
import repro_hash
import repro_local_store

proc weakOf(name: string): ContentDigest =
  ## The same construction `repro_build_engine.weakFingerprintFromText` uses,
  ## written out rather than imported: a `repro_local_store` test must not
  ## depend on the layer above it, and only the domain and the bytes matter.
  var bytes = newSeq[byte](name.len)
  for i, ch in name:
    bytes[i] = byte(ord(ch))
  blake3DomainDigest(bytes, hdActionFingerprint)

type Fixture = object
  root: string
  workRoot: string
  cache: ActionCache
  store: Store

proc openFixture(tag: string): Fixture =
  let root = createTempDir("repro-newest-alias-" & tag & "-", "")
  let workRoot = root / "work"
  createDir(workRoot)
  Fixture(
    root: root,
    workRoot: workRoot,
    cache: openActionCache(root / "action-cache", attachShm = false),
    store: openStore(root / "store"))

proc closeFixture(f: var Fixture) =
  f.cache.closeShmTier()
  close(f.store)
  try: removeDir(f.root)
  except OSError: discard

proc edgeDir(f: Fixture; weak: ContentDigest): string =
  f.cache.hotRecordsRoot / perEdgeRecordFileName(weak)

proc recNames(f: Fixture; weak: ContentDigest): seq[string] =
  for kind, path in walkDir(f.edgeDir(weak)):
    if kind == pcFile and path.endsWith(".rec"):
      result.add(path.extractFilename)
  result.sort()

proc aliasPath(f: Fixture; weak: ContentDigest): string =
  ## The C1 accelerator's fixed, distinguished name. Spelled out here rather
  ## than exported from the store: a test that took the name from the
  ## implementation could not notice the implementation renaming it, and the
  ## name is part of the on-disk contract §5.5 "Compatibility" constrains.
  f.edgeDir(weak) / "newest.rbal"

proc recordVariant(f: var Fixture; weak: ContentDigest; variant: int):
    ActionResultRecord =
  ## Record one PATH-SET for `weak`. Each variant observes a different set of
  ## input files, so each gets a distinct strong fingerprint and lands in its
  ## own `<strongHex>.rec` — which is what makes the edge directory hold
  ## several candidates, the situation C1 is about.
  var inputs: seq[string] = @[]
  for i in 0 .. variant:
    let p = f.workRoot / ("src" & $i & ".c")
    if not fileExists(p):
      writeFile(p, "int v" & $i & "(void){return " & $i & ";}\n")
    inputs.add(p)
  let outputPath = f.workRoot / "out.o"
  writeFile(outputPath, "object-bytes-" & $variant & "\n")
  f.cache.recordActionResult(f.store, weak, ffpTimestamp,
    inputs, [outputPath], outputRoot = "", storeOutputBlobs = true)

suite "C1 — the newest candidate is addressable":

  test "a consultation decodes ONE record, not every record the edge has":
    var f = openFixture("one-of-n")
    defer: closeFixture(f)
    let weak = weakOf("alias.one-of-n")
    for variant in 0 ..< 6:
      discard f.recordVariant(weak, variant)
    # The premise: the edge really does hold several candidates. Without
    # this, "decoded one record" would be a statement about an edge that
    # only ever had one.
    check f.recNames(weak).len == 6
    check fileExists(f.aliasPath(weak))

    resetOutputStateCheckStats()
    let hot = f.cache.readHotRecord(weak)
    check hot.found
    let viaAlias = actionRecordDecodeStats()
    check viaAlias.records == 1
    check viaAlias.containerReads == 1

    # THE CONTROL. Remove the accelerator and nothing else, then repeat the
    # SAME read. It must still answer, and it must now pay for all six —
    # which is what makes the 1 above a measurement rather than a counter
    # that cannot move.
    removeFile(f.aliasPath(weak))
    resetOutputStateCheckStats()
    let unaccelerated = f.cache.readHotRecord(weak)
    check unaccelerated.found
    let viaUnion = actionRecordDecodeStats()
    check viaUnion.records == 6
    check viaUnion.containerReads == 6
    check viaUnion.bytes > viaAlias.bytes

    # And the two reads must agree on the ANSWER. A fast path that returns a
    # different record from the union read is a correctness bug wearing an
    # optimization's clothes.
    check hot.record.inputs == unaccelerated.record.inputs
    check hot.record.outputs == unaccelerated.record.outputs

  test "the union fallback warms the alias, so an old cache gains it":
    ## §8 step 5 warms the shared-memory index after a union fallback for the
    ## same reason: a cache written before the accelerator existed publishes
    ## nothing on a warm no-op, so without this it would pay the union read
    ## forever.
    var f = openFixture("warm")
    defer: closeFixture(f)
    let weak = weakOf("alias.warm")
    for variant in 0 ..< 3:
      discard f.recordVariant(weak, variant)
    removeFile(f.aliasPath(weak))
    check not fileExists(f.aliasPath(weak))

    resetOutputStateCheckStats()
    discard f.cache.readHotRecord(weak)
    check actionRecordDecodeStats().records == 3
    check fileExists(f.aliasPath(weak))

    resetOutputStateCheckStats()
    discard f.cache.readHotRecord(weak)
    check actionRecordDecodeStats().records == 1

  test "an alias whose directory has moved under it is refused":
    ## The staleness case that a binary predating the alias creates: it
    ## publishes a `.rec` and cannot know to update the alias. The reader
    ## must notice and fall back — and must return the record that publish
    ## added, not the one the alias still names.
    var f = openFixture("stale-members")
    defer: closeFixture(f)
    let weak = weakOf("alias.stale-members")
    discard f.recordVariant(weak, 0)
    let aliasBefore = readFile(f.aliasPath(weak))
    let newest = f.recordVariant(weak, 1)
    # Put the alias back exactly as the first publish left it: an alias that
    # names the OLD newest and attests to a one-file directory.
    writeFile(f.aliasPath(weak), aliasBefore)
    check f.recNames(weak).len == 2

    resetOutputStateCheckStats()
    let hot = f.cache.readHotRecord(weak)
    check hot.found
    # Refused: it read both containers, which is the union read.
    check actionRecordDecodeStats().records == 2
    # And it answered with the TRUE newest. This is the assertion that fails
    # if the reader trusts a stale alias — the failure mode C1 must not
    # have, since §5.3's newest-wins is normative.
    check hot.record.inputs.len == newest.inputs.len
    check hot.record.inputs.len == 2

  test "an alias whose container was rewritten in place is refused":
    ## The other staleness case, and the one a member-set comparison alone
    ## cannot see: a CONVERGENT rewrite keeps the same strong fingerprint and
    ## therefore the same file name, so the directory looks identical. Only
    ## the durable write sequence moves — which is why the alias records it.
    var f = openFixture("stale-seq")
    defer: closeFixture(f)
    let weak = weakOf("alias.stale-seq")
    discard f.recordVariant(weak, 0)
    let names = f.recNames(weak)
    check names.len == 1
    let aliasBefore = readFile(f.aliasPath(weak))

    # Re-record the SAME path-set. Same strong fingerprint, same file name,
    # fresh write sequence.
    discard f.recordVariant(weak, 0)
    check f.recNames(weak) == names
    check readFile(f.aliasPath(weak)) != aliasBefore

    writeFile(f.aliasPath(weak), aliasBefore)
    resetOutputStateCheckStats()
    let hot = f.cache.readHotRecord(weak)
    check hot.found
    # It refused the alias and re-read through the union path, which for a
    # one-container edge is one container — so the observable proof is that
    # the alias got REWRITTEN by the warm, not left as the stale bytes.
    check readFile(f.aliasPath(weak)) != aliasBefore

  test "a truncated or garbage alias is a miss, never an error":
    var f = openFixture("garbage")
    defer: closeFixture(f)
    let weak = weakOf("alias.garbage")
    for variant in 0 ..< 2:
      discard f.recordVariant(weak, variant)
    for garbage in ["", "x", "RBNA", "RBNAnot-a-record-at-all",
        "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"]:
      writeFile(f.aliasPath(weak), garbage)
      let hot = f.cache.readHotRecord(weak)
      check hot.found
      check hot.record.inputs.len == 2

  test "an alias naming a container that is gone is refused":
    var f = openFixture("dangling")
    defer: closeFixture(f)
    let weak = weakOf("alias.dangling")
    discard f.recordVariant(weak, 0)
    discard f.recordVariant(weak, 1)
    let alias = readFile(f.aliasPath(weak))
    let names = f.recNames(weak)
    # Delete the container the alias names, leaving the alias behind — what a
    # GC that does not know about the alias would do.
    removeFile(f.edgeDir(weak) / names[^1])
    removeFile(f.edgeDir(weak) / names[0])
    discard f.recordVariant(weak, 2)
    writeFile(f.aliasPath(weak), alias)
    let hot = f.cache.readHotRecord(weak)
    check hot.found
    check hot.record.inputs.len == 3

  test "the alias file is invisible to every pre-existing reader":
    ## §5.5 "Compatibility": "an implementation MUST choose an alias name
    ## that existing readers either ignore or handle as a duplicate of a
    ## container they already read". Every reader that predates it filters on
    ## one of three suffixes; this pins that the chosen name matches none of
    ## them, so a binary built before this change sees the directory it
    ## always saw.
    var f = openFixture("invisible")
    defer: closeFixture(f)
    let weak = weakOf("alias.invisible")
    discard f.recordVariant(weak, 0)
    let name = f.aliasPath(weak).extractFilename
    check fileExists(f.aliasPath(weak))
    check not name.endsWith(".rec")
    check not name.endsWith(".octime")
    check not name.endsWith(DeterminismFileExt)
    # And the union read, which is the pre-existing reader, does not mistake
    # it for a record.
    check f.cache.loadPerEdgeRecords(weak).len == 1

  test "retention still evicts the oldest, and the alias survives it":
    ## `capRecFiles` now publishes the alias, so a cap that fires must leave
    ## a CURRENT one — otherwise the edge that hits the cap, which is the
    ## edge consulted most, is the one that loses the accelerator.
    var f = openFixture("cap")
    defer: closeFixture(f)
    let weak = weakOf("alias.cap")
    for variant in 0 ..< 11:
      discard f.recordVariant(weak, variant)
    check f.recNames(weak).len == 8

    resetOutputStateCheckStats()
    let hot = f.cache.readHotRecord(weak)
    check hot.found
    check actionRecordDecodeStats().records == 1
    # The survivor is the newest path-set, the 11-input one.
    check hot.record.inputs.len == 11

suite "C4 — paths are interned within a record":

  test "a record round-trips every path shape byte-for-byte":
    ## Interning splits each path at its last separator and reassembles it on
    ## read. A codec that NORMALISED instead would turn a recorded input into
    ## a path that never matches what the monitor observed, i.e. a permanent
    ## miss. These are the shapes that break naive splitting.
    var record = ActionResultRecord(
      weakFingerprint: weakOf("c4.shapes"),
      policy: ffpTimestamp,
      outputPayloadKind: opkMetadataOnly)
    let shapes = ["", "/", "a", "/a", "a/", "/a/", "rel/x", "./x", "../x",
      "/very/long/checkout/prefix/that/repeats/src/one.c",
      "/very/long/checkout/prefix/that/repeats/src/two.c",
      "//double//separators//x", "trailing/", "no-separator-at-all"]
    for shape in shapes:
      record.inputs.add(FileFingerprint(path: shape, policy: ffpTimestamp,
        metadata: FileMetadata(kind: ffkRegular, sizeBytes: 1, mtimeNs: 2)))
    for shape in shapes:
      record.outputs.add(OutputBlob(path: shape,
        metadata: FileMetadata(kind: ffkRegular, sizeBytes: 3, mtimeNs: 4)))
    record.strongFingerprint = computeStrongFingerprint(
      record.weakFingerprint, record.inputs)
    let decoded = decodeActionResultRecord(encodeActionResultRecord(record))
    check decoded.inputs.mapIt(it.path) == @shapes
    check decoded.outputs.mapIt(it.path) == @shapes
    check decoded.strongFingerprint == record.strongFingerprint

  test "shared directory prefixes are stored once":
    ## The saving §5.5 C4 is after: "a record carrying 78 inputs at p50 and
    ## 10,018 at p90 is dominated by long shared directory prefixes from one
    ## checkout".
    ##
    ## The control is the SECOND record below, whose paths share no prefix at
    ## all. It must NOT shrink — if both shrank, the encoding would be
    ## getting smaller for some reason other than the repetition, and this
    ## case would not be measuring interning.
    const Prefix = "/some/quite/long/checkout/root/that/repeats/src/"
    proc build(paths: openArray[string]): seq[byte] =
      var record = ActionResultRecord(
        weakFingerprint: weakOf("c4.prefix"),
        policy: ffpTimestamp,
        outputPayloadKind: opkMetadataOnly)
      for p in paths:
        record.inputs.add(FileFingerprint(path: p, policy: ffpTimestamp,
          metadata: FileMetadata(kind: ffkRegular, sizeBytes: 1, mtimeNs: 2)))
      encodeActionResultRecord(record)

    var shared: seq[string] = @[]
    var distinctDirs: seq[string] = @[]
    for i in 0 ..< 200:
      shared.add(Prefix & "unit" & $i & ".c")
      distinctDirs.add("/d" & $i & Prefix & "unit" & $i & ".c")

    let sharedBytes = build(shared).len
    let distinctBytes = build(distinctDirs).len
    var rawShared = 0
    for p in shared:
      rawShared += p.len
    var rawDistinct = 0
    for p in distinctDirs:
      rawDistinct += p.len

    # The claim, stated as a property rather than as a ratio: the whole
    # encoded record is SMALLER than the raw bytes of the paths it carries.
    # No encoder that writes each path out in full can satisfy that, whatever
    # else it does, so this fails the moment interning stops happening.
    check sharedBytes < rawShared

    # THE CONTROL, in the same body. The same 200 paths with no shared
    # prefix must NOT shrink: the table dedups nothing and costs an index
    # word per path, so the record is larger than its raw path bytes. If
    # both arms shrank, the encoding would be getting smaller for some
    # reason other than the repetition and this case would be measuring
    # something else.
    check distinctBytes > rawDistinct
    check sharedBytes * 2 < distinctBytes

  test "the STRONG fingerprint did not move":
    ## The trap this change had to avoid, pinned to a value produced by the
    ## binary that predates it. `strongIdentityPayload` computes the cache
    ## KEY; `encodeRecord` computes the STORAGE bytes. Interning inside the
    ## former would have shifted every strong fingerprint in every existing
    ## cache on every machine — a silent global invalidation that looks
    ## exactly like a working build, one full rebuild later.
    ##
    ## The two hex values below were produced by a build of the parent commit
    ## and are pasted, not computed, so this case fails if the key payload is
    ## ever touched again.
    let weak = weakOf("legacy-fixture-edge")
    var inputs = @[
      FileFingerprint(path: "/work/checkout/src/alpha.c",
        policy: ffpTimestamp,
        metadata: FileMetadata(kind: ffkRegular, sizeBytes: 11, mtimeNs: 22)),
      FileFingerprint(path: "/work/checkout/src/beta.c",
        policy: ffpTimestamp,
        metadata: FileMetadata(kind: ffkRegular, sizeBytes: 33, mtimeNs: 44)),
      FileFingerprint(path: "relative.h", policy: ffpTimestamp,
        metadata: FileMetadata(kind: ffkRegular, sizeBytes: 55, mtimeNs: 66))]
    check digestHex(computeStrongFingerprint(weak, inputs)) ==
      "28c642b92be7b7deafe4cc2394d8a4f0c99d9e0e1c3a8e6de09ee44d7ddb3a51"
    check digestHex(computeStrongFingerprint(weak, inputs, [
        EnvFingerprint(name: "SOURCE_DATE_EPOCH", present: true, value: "17"),
        EnvFingerprint(name: "CFLAGS", present: false, value: "")])) ==
      "5b03cfce4f66a4cc78d246c58ebfa898eb4767db766c584e1ba1eec2b98a6e07"

proc unhex(hex: string): seq[byte] =
  var i = 0
  while i + 1 < hex.len:
    result.add(byte(parseHexInt(hex[i .. i + 1])))
    i += 2

# Byte-for-byte output of a build of the PARENT COMMIT: `V3Hex` and `V4Hex`
# are what its `encodeActionResultRecord` produced for a record with and
# without observed environment inputs; `V2ContainerHex` is a whole `.rec`
# container its `writePerEdgeRecords` wrote, trailer and all. They are pasted
# from that binary's output rather than re-derived here, because a fixture a
# test computes for itself only proves that two functions in one repository
# agree with each other.
const
  V3Hex =
    "5242415203000001ff0a7492dcea8b2d164fa295cd71a82be0f776350af9943e" &
    "11b1557feb1f72ef00030000001a0000002f776f726b2f636865636b6f75742f" &
    "7372632f616c7068612e6300010b000000000000001600000000000000001900" &
    "00002f776f726b2f636865636b6f75742f7372632f626574612e630001210000" &
    "00000000002c00000000000000000a00000072656c61746976652e6800013700" &
    "000000000000420000000000000000000128c642b92be7b7deafe4cc2394d8a4" &
    "f0c99d9e0e1c3a8e6de09ee44d7ddb3a5100010000000b0000006f75742f616c" &
    "7068612e6f014d000000000000005800000000000000060000010bfb98276058" &
    "9878c1fb3d6995bef2709347eefd76ef57674b7cae2b545fd0d74d0000000000" &
    "0000"
  V4Hex =
    "5242415204000001ff0a7492dcea8b2d164fa295cd71a82be0f776350af9943e" &
    "11b1557feb1f72ef00030000001a0000002f776f726b2f636865636b6f75742f" &
    "7372632f616c7068612e6300010b000000000000001600000000000000001900" &
    "00002f776f726b2f636865636b6f75742f7372632f626574612e630001210000" &
    "00000000002c00000000000000000a00000072656c61746976652e6800013700" &
    "0000000000004200000000000000000200000011000000534f555243455f4441" &
    "54455f45504f4348010200000031370600000043464c41475300000000000001" &
    "5b03cfce4f66a4cc78d246c58ebfa898eb4767db766c584e1ba1eec2b98a6e07" &
    "00010000000b0000006f75742f616c7068612e6f014d00000000000000580000" &
    "0000000000060000010bfb982760589878c1fb3d6995bef2709347eefd76ef57" &
    "674b7cae2b545fd0d74d00000000000000"
  V2ContainerHex =
    "52425045020001000000220100005242415203000001ff0a7492dcea8b2d164f" &
    "a295cd71a82be0f776350af9943e11b1557feb1f72ef00030000001a0000002f" &
    "776f726b2f636865636b6f75742f7372632f616c7068612e6300010b00000000" &
    "000000160000000000000000190000002f776f726b2f636865636b6f75742f73" &
    "72632f626574612e63000121000000000000002c00000000000000000a000000" &
    "72656c61746976652e6800013700000000000000420000000000000000000128" &
    "c642b92be7b7deafe4cc2394d8a4f0c99d9e0e1c3a8e6de09ee44d7ddb3a5100" &
    "010000000b0000006f75742f616c7068612e6f014d0000000000000058000000" &
    "00000000060000010bfb982760589878c1fb3d6995bef2709347eefd76ef5767" &
    "4b7cae2b545fd0d74d00000000000000394e85670100000000000000"
  LegacyContainerName =
    "28c642b92be7b7deafe4cc2394d8a4f0c99d9e0e1c3a8e6de09ee44d7ddb3a51.rec"
  LegacyStrongHex =
    "28c642b92be7b7deafe4cc2394d8a4f0c99d9e0e1c3a8e6de09ee44d7ddb3a51"

suite "records written before the trust epoch are refused":
  ## INVERTED, DELIBERATELY. This suite used to be called "records written
  ## before the format change still read" and asserted that a v3/v4 record and
  ## a legacy container kept working, on the §5.5 "Compatibility" reasoning
  ## that "a cache full of records this binary's predecessor wrote must keep
  ## working, or upgrading reprobuild silently discards every warm build on
  ## the machine".
  ##
  ## That reasoning was correct for a FORMAT bump and is wrong for a TRUST
  ## one. Every record version that existed before
  ## `ActionRecordVersionEvidenceEpoch` — 2, 3, 4 and 5 — was written by a
  ## binary whose no-evidence publish guard was dead, so those records are
  ## internally consistent but were never validated against anything, and no
  ## predicate can pick the bad ones out (see the constant's own comment).
  ## Discarding every warm build on the machine is not a regrettable side
  ## effect here; it is the remediation. The fixtures are kept exactly as they
  ## were so that what changed is visibly the VERDICT and not the input.

  test "a v3 record produced by an older binary is refused, not decoded":
    ## Refused rather than misread: the decoder raises on the version word
    ## before it interprets a single byte of the body, so there is no path on
    ## which these bytes are parsed under the wrong schema.
    expect EnvelopeError:
      discard decodeActionResultRecord(unhex(V3Hex))

  test "a v4 record produced by an older binary is refused, env included":
    expect EnvelopeError:
      discard decodeActionResultRecord(unhex(V4Hex))

  test "a container written by an older binary reads as EMPTY, not as an error":
    ## End to end, not just the codec, and this is the case that matters most:
    ## the drain is only safe if a pre-epoch container degrades to a cache
    ## MISS. If it escaped as an exception it would take down builds that
    ## merely happen to have a warm cache directory.
    ##
    ## The `.rec` file dropped here is the exact byte sequence an older
    ## `writePerEdgeRecords` produced — the state of every edge directory in
    ## every cache on every machine right now.
    var f = openFixture("legacy-container")
    defer: closeFixture(f)
    let weak = weakOf("legacy-fixture-edge")
    let dir = f.edgeDir(weak)
    createDir(dir)
    var raw = ""
    for b in unhex(V2ContainerHex):
      raw.add(char(b))
    writeFile(dir / LegacyContainerName, raw)

    # No raise, and nothing servable comes out of it.
    let union = f.cache.loadPerEdgeRecords(weak)
    check union.len == 0

    resetOutputStateCheckStats()
    let hot = f.cache.readHotRecord(weak)
    check not hot.found

    # The file is left ALONE rather than deleted. Draining is a read-side
    # refusal; reaching in and unlinking a user's cache entries would be a
    # second, much larger decision, and `repro store gc` already owns it.
    check fileExists(dir / LegacyContainerName)

  test "the record this binary writes is at the epoch, and only that decodes":
    ## The boundary from the other side. A bump that left the version word
    ## alone would be the dangerous case: an old reader would parse new bytes
    ## as if they were old ones.
    var record = ActionResultRecord(
      weakFingerprint: weakOf("boundary"),
      policy: ffpTimestamp,
      outputPayloadKind: opkMetadataOnly)
    record.inputs = @[FileFingerprint(path: "/a/b.c", policy: ffpTimestamp,
      metadata: FileMetadata(kind: ffkRegular, sizeBytes: 1, mtimeNs: 2))]
    let encoded = encodeActionResultRecord(record)
    let version = uint16(encoded[4]) or (uint16(encoded[5]) shl 8)
    check version == 6'u16
    check decodeActionResultRecord(encoded).inputs.len == 1

    # Every pre-epoch version is refused on bytes that are otherwise a valid
    # v6 frame — 5 included. 5 is the one worth naming: it is what a binary
    # built from mainline writes today, and accepting it would drain the old
    # records while leaving the recent ones, which is the failure mode this
    # whole change exists to avoid.
    for stale in [2'u16, 3'u16, 4'u16, 5'u16]:
      var patched = encoded
      patched[4] = byte(stale and 0xff'u16)
      patched[5] = byte((stale shr 8) and 0xff'u16)
      expect EnvelopeError:
        discard decodeActionResultRecord(patched)

    # And an unknown FUTURE version is refused rather than guessed at, which
    # is the same rule applied in the same direction.
    var future = encoded
    future[4] = byte(99)
    future[5] = byte(0)
    expect EnvelopeError:
      discard decodeActionResultRecord(future)
