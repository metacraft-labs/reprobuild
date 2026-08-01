## Track B (Typed-Extension-Interfaces-And-Provider-Libraries.md,
## Incremental-Invalidation.md §"Binary formats from Reprobuild domain
## types"): the RSST resource-state record migrated onto a versioned SSZ
## envelope. Pins:
##
##   (a) t_rss_ssz_envelope_roundtrip — encode (SSZ envelope) -> write ->
##       read -> reconstruct yields a record EQUAL to the original across
##       every field (address/typeId/determinism/attrs/deps/identity/
##       digest/present + the lease fields), AND the on-disk bytes carry the
##       `RSST` magic + the SSZ envelope version (read-new is the SSZ path);
##   (b) BACK-COMPAT: a record written in the OLD hand-rolled LE framing
##       (magic + u32 version=2, the pre-Track-B format) is still read by the
##       current reader and decodes to the SAME record — read-old / write-new,
##       so a pre-migration cache is a normal read, never a crash;
##   (c) a truncated / garbage `.rec` fails cleanly (a decode error the
##       caller turns into a cache miss), never a silent wrong record.

import std/[tables, options, times, os, unittest]

import repro_resources
import repro_core                       # writeString / writeU32Le / writeU64Le …
import repro_project_dsl                # TypedExtensionBox + registerExtension

type
  RssAttrs = object
    value: string
    size: int

proc registerRssAttrs() =
  registerExtension[RssAttrs]("rss.stub")

proc scratchStore(sub: string): StateStore =
  let root = getTempDir() / ("repro-rss-" & $getCurrentProcessId() & "-" & sub)
  removeDir(root)
  openStateStore(root)

proc sampleRecord(address: string): ResourceStateRecord =
  ## A record exercising every field, incl. multiple (unordered) holders and
  ## a present effectiveDeadline.
  var holders = initTable[string, Time]()
  holders["run-zeta"] = fromUnix(1_700_000_900)
  holders["run-alpha"] = fromUnix(1_700_000_100)
  result = ResourceStateRecord(
    address: address,
    typeId: "rss.stub",
    determinism: rdVolatile,
    attrsTypeId: "rss.stub",
    attrsJson: "{\"value\":\"hello\",\"size\":7}",
    dependsOn: @["base", "net"],
    identity: "stub:" & address,
    digest: digestString("digest-seed-" & address),
    present: true,
    holders: holders,
    effectiveDeadline: some(fromUnix(1_700_000_900)),
    lastRenewed: fromUnix(1_700_000_050))

proc checkEqual(a, b: ResourceStateRecord) =
  check a.address == b.address
  check a.typeId == b.typeId
  check a.determinism == b.determinism
  check a.attrsTypeId == b.attrsTypeId
  check a.attrsJson == b.attrsJson
  check a.dependsOn == b.dependsOn
  check a.identity == b.identity
  check a.digest == b.digest
  check a.present == b.present
  check a.holders == b.holders
  check a.effectiveDeadline == b.effectiveDeadline
  check a.lastRenewed == b.lastRenewed

# ---------------------------------------------------------------------------
# Reproduce the PRE-Track-B on-disk bytes (magic + u32 version=2 + LE fields)
# EXACTLY as the old `encodeRecord` produced them, so the back-compat test
# feeds the reader a genuine legacy record. If this drifts from the retired
# format the test is meaningless, so it is spelled out field-for-field.
# ---------------------------------------------------------------------------
proc encodeLegacyV2(rec: ResourceStateRecord): seq[byte] =
  for ch in "RSST":
    result.add(byte(ord(ch)))
  result.writeU32Le(2'u32)                       # StateRecordVersion (legacy)
  result.writeString(rec.address)
  result.writeString(rec.typeId)
  result.writeU32Le(uint32(ord(rec.determinism)))
  result.writeString(rec.attrsTypeId)
  result.writeString(rec.attrsJson)
  result.writeU32Le(uint32(rec.dependsOn.len))
  for dep in rec.dependsOn:
    result.writeString(dep)
  result.writeString(rec.identity)
  for b in rec.digest:
    result.add(b)
  result.add(if rec.present: 1'u8 else: 0'u8)
  result.writeU32Le(uint32(rec.holders.len))
  for consumerId, deadline in rec.holders:
    result.writeString(consumerId)
    result.writeU64Le(uint64(deadline.toUnix()))
  if rec.effectiveDeadline.isSome:
    result.add(1'u8)
    result.writeU64Le(uint64(rec.effectiveDeadline.get.toUnix()))
  else:
    result.add(0'u8)
  result.writeU64Le(uint64(rec.lastRenewed.toUnix()))

proc writeRawRecord(store: StateStore; address: string; bytes: seq[byte]) =
  ## Drop raw bytes at the record path (mirrors what an older reprobuild left
  ## on disk). We reuse the store's own filename encoding via a write+read of
  ## a probe, then overwrite — simplest is to write via the public path shape:
  ## `<address>.rec` with the same safe-name mapping. For these ASCII-only
  ## addresses the mapping is identity, so the file name is `<address>.rec`.
  var s = newString(bytes.len)
  if bytes.len > 0:
    copyMem(addr s[0], unsafeAddr bytes[0], bytes.len)
  writeFile(store.root / (address & ".rec"), s)

suite "Track B: RSST versioned SSZ envelope":

  setup:
    registerRssAttrs()

  test "t_rss_ssz_envelope_roundtrip: SSZ write -> read is equal + is SSZ on disk":
    let store = scratchStore("rt")
    let rec = sampleRecord("cluster")
    writeStateRecord(store, rec)

    let back = readStateRecord(store, "cluster")
    checkEqual(back, rec)

    # The on-disk bytes are the NEW SSZ envelope: RSST magic then the SSZ
    # version half-word (3), NOT the legacy u32 version (2).
    let raw = readFile(store.root / "cluster.rec")
    check raw.len > 8
    check raw[0 .. 3] == "RSST"
    check byte(raw[4]) == 3'u8            # StateRecordSszVersion low byte
    check byte(raw[5]) == 0'u8

  test "back-compat: a legacy (u32 v2 LE) record still reads as the same record":
    let store = scratchStore("legacy")
    let rec = sampleRecord("legacy-res")
    writeRawRecord(store, "legacy-res", encodeLegacyV2(rec))

    # The reader must accept the OLD framing (read-old) and decode it to the
    # SAME record — a pre-migration cache degrades to a normal read.
    let back = readStateRecord(store, "legacy-res")
    checkEqual(back, rec)

    # And it must be listed too (listStateRecords shares the decoder).
    let all = listStateRecords(store)
    check all.len == 1
    checkEqual(all[0], rec)

  test "back-compat: a legacy 'never reap' (none deadline) record round-trips as none":
    let store = scratchStore("legacy-none")
    var rec = sampleRecord("pinned")
    rec.holders = initTable[string, Time]()
    rec.effectiveDeadline = none(Time)
    writeRawRecord(store, "pinned", encodeLegacyV2(rec))
    let back = readStateRecord(store, "pinned")
    check back.effectiveDeadline.isNone
    checkEqual(back, rec)

  test "garbage / truncated record fails cleanly (a cache miss, not a wrong record)":
    let store = scratchStore("garbage")
    writeRawRecord(store, "bad", @[byte(ord('R')), byte(ord('S')),
                                   byte(ord('S')), byte(ord('T')), 3'u8, 0'u8])
    expect CatchableError:
      discard readStateRecord(store, "bad")
