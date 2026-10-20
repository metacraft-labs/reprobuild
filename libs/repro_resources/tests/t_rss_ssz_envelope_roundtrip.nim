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
##       caller turns into a cache miss), never a silent wrong record;
##   (d) v4 (keep holders named): `keepHolders` + `keepHoldersKnown`
##       round-trip, are written canonically (sorted, de-duplicated), and are
##       bounded; a record written in the v3 SSZ envelope (GOLDEN bytes
##       produced by the pre-v4 encoder) still decodes, with
##       `keepHoldersKnown == false` when its deadline is `none`, because v3
##       never recorded keep holders, and `true` when it carries a dated
##       deadline, which proves no keep holder existed;
##   (e) renewing such an UNKNOWN record never re-arms a deadline under a pin
##       it cannot see, and renewing a dated v3 record follows the normal
##       rule;
##   (f) a v3 record NO lease ever renewed (`lastRenewed == fromUnix(0)`,
##       GOLDEN bytes from the pre-v4 non-leased write) decodes as KNOWN, and
##       a dated renewal of it arms a real deadline;
##   (g) v5 (the provider artifact named): `providerArtifact` round-trips, the
##       written envelope version is 5, and a record written in the v4 SSZ
##       envelope (GOLDEN bytes produced by the pre-v5 encoder) still decodes
##       — with `providerArtifact == none`, because a v4 writer recorded no
##       route to the provider — every other field intact. A `some(ref)` whose
##       `binaryPath` is empty is REFUSED rather than persisted: it would be a
##       session launch of nothing (Ephemeral-State-Leases.md §4.2).

import std/[tables, options, times, os, unittest]
from std/strutils import parseHexInt

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
  ## A record exercising every field, incl. multiple (unordered) holders,
  ## keep holders, and a present effectiveDeadline. (A keep holder with a
  ## dated effective deadline is not a state the merge produces; the codec
  ## does not care, and this keeps every field non-default.)
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
    keepHolders: @["pin-a", "pin-b"],
    keepHoldersKnown: true,
    effectiveDeadline: some(fromUnix(1_700_000_900)),
    lastRenewed: fromUnix(1_700_000_050),
    providerArtifact: some(ResourceProviderArtifactRef(
      binaryPath: "/nix/store/stub-provider/bin/prov",
      providerArtifactId: "deadbeef",
      workingDir: "/work/dir")))

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
  check a.keepHolders == b.keepHolders
  check a.keepHoldersKnown == b.keepHoldersKnown
  check a.effectiveDeadline == b.effectiveDeadline
  check a.lastRenewed == b.lastRenewed
  check a.providerArtifact.isSome == b.providerArtifact.isSome
  if a.providerArtifact.isSome and b.providerArtifact.isSome:
    check a.providerArtifact.get.binaryPath == b.providerArtifact.get.binaryPath
    check a.providerArtifact.get.providerArtifactId ==
      b.providerArtifact.get.providerArtifactId
    check a.providerArtifact.get.workingDir == b.providerArtifact.get.workingDir

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

proc legacyShaped(rec: ResourceStateRecord; known: bool): ResourceStateRecord =
  ## What a pre-v4 format can carry of `rec`: no keep holders. Whether the
  ## decoder may claim to know them (`known`) is stated by each caller from
  ## the record's own shape — a dated deadline or a never-renewed record
  ## proves there are none — rather than re-derived here from the rule under
  ## test.
  ##
  ## It also drops `providerArtifact`: no pre-v5 format recorded one, so a
  ## record decoded from the legacy LE framing or the v3 / v4 envelopes has
  ## none, and the reaper falls back to its registry or the in-process arm for
  ## that type (Ephemeral-State-Leases.md §4.2).
  result = rec
  result.keepHolders = @[]
  result.keepHoldersKnown = known
  result.providerArtifact = none(ResourceProviderArtifactRef)

proc hexBytes(hex: string): seq[byte] =
  for i in countup(0, hex.len - 1, 2):
    result.add(byte(parseHexInt(hex[i .. i + 1])))

# GOLDEN v3 SSZ envelopes, written by the pre-v4 `encodeRecord` (reprobuild
# `a6491129`, before keep holders were persisted) through the public
# `writeStateRecord` and hex-dumped from the resulting `.rec` file. They are
# bytes, not a re-implementation of the v3 encoder, so a v3 reader that drifts
# from what was really on disk fails here.
#
# `GoldenV3Dated`: address "v3-res", holders {run-alpha: 1_700_000_100,
# run-zeta: 1_700_000_900}, effectiveDeadline some(1_700_000_900).
const GoldenV3Dated =
  "5253535403000100cd0000005200000058000000030000006000000068000000" &
  "8200000091000000348cec3bb35875d9663112d07931ab3f626a6f917f77d342" &
  "86ddef7a4b642caa019c0000000184f453650000000032f15365000000007633" &
  "2d7265737273732e737475627273732e737475627b2276616c7565223a226865" &
  "6c6c6f222c2273697a65223a377d080000000c000000626173656e6574737475" &
  "623a76332d726573080000001d0000000c00000064f153650000000072756e2d" &
  "616c7068610c00000084f453650000000072756e2d7a65746167379cfac38532" &
  "187d3112a55e9a6468af15e2cf2e6cd999913a90deeaebe2d9"

# `GoldenV3Pinned`: address "v3-pinned", holders {slow: 1_700_000_900},
# effectiveDeadline NONE — the shape the issue describes: a keep pin and a
# dated holder, where the record names only the dated one.
const GoldenV3Pinned =
  "5253535403000100b6000000520000005b00000003000000630000006b000000" &
  "8500000094000000b3f49d79e66b07ddcd5e19132ddce1cfba0c4ca283429967" &
  "fd9c75528f7109de01a200000000000000000000000032f15365000000007633" &
  "2d70696e6e65647273732e737475627273732e737475627b2276616c7565223a" &
  "2268656c6c6f222c2273697a65223a377d080000000c000000626173656e6574" &
  "737475623a76332d70696e6e6564040000000c00000084f4536500000000736c" &
  "6f77100afbc009c167294b8e7ec89f7961d543e2f5d21a2235f4e7beab654153" &
  "98b1"

# `GoldenV3Unleased`: written by the a6491129 `state_store.nim` through the
# NON-leased reconcile write (`writeStateRecord(store, inst, binding)`, every
# lease parameter defaulted): address "v3-unleased", no holders,
# effectiveDeadline none, lastRenewed fromUnix(0). The pre-v4 writers set
# `lastRenewed = now` on every renewal, so a zero `lastRenewed` is a record no
# lease ever renewed — and therefore one no keep holder can be pinning.
const GoldenV3Unleased =
  "5253535403000100a4000000520000005d00000003000000650000006d000000" &
  "8c00000094000000b6a8992a25a2ab30096193144851797e7930f499176d4b24" &
  "3f0855bdeff3c8cd01a400000000000000000000000000000000000000007633" &
  "2d756e6c65617365647273732e737475627273732e7374756201000200000009" &
  "0000000400000068656c6c6f0800000007000000000000000400000062617365" &
  "737475623a76332d756e6c6561736564e95be1cc947533c99d308c64cf6cc3c1" &
  "dd69a5d09c2f54b6dbec6ff0390fae81"

# GOLDEN v4 SSZ envelopes, written by the pre-v5 `encodeRecord` (reprobuild
# `a5d01d86`, before the provider artifact was persisted) through the public
# `writeStateRecord` and hex-dumped from the resulting `.rec` file. Bytes, not
# a re-implementation of the v4 encoder — a v4 reader that drifts from what was
# really on disk fails here.
#
# THEY MUST NOT BE REGENERATED by the current encoder. Regenerating them would
# produce v5 bytes and make the read-old case assert that v5 decodes as v5,
# which is what the round-trip case above already covers and is not the
# property at issue: a store written by the previous repro must still be
# readable by this one.
#
# `GoldenV4Dated`: address "v4-res", typeId/attrsTypeId "rss.stub",
# determinism rdVolatile, attrsJson {"value":"hello","size":7},
# dependsOn @["base","net"], identity "stub:v4-res",
# digest digestString("digest-seed-v4-res"), present = true,
# holders {run-alpha: 1_700_000_100, run-zeta: 1_700_000_900},
# keepHolders @[], keepHoldersKnown = true,
# effectiveDeadline some(1_700_000_900), lastRenewed 1_700_000_050.
const GoldenV4Dated =
  "5253535404000100D2000000570000005D00000003000000650000006D000000" &
  "87000000960000000C67FC9C0DA780A15495C43CB03FDFAFA4DC34EA92B6B054" &
  "14BCE075D61DFCD401A1000000D2000000010184F453650000000032F1536500" &
  "00000076342D7265737273732E737475627273732E737475627B2276616C7565" &
  "223A2268656C6C6F222C2273697A65223A377D080000000C000000626173656E" &
  "6574737475623A76342D726573080000001D0000000C00000064F15365000000" &
  "0072756E2D616C7068610C00000084F453650000000072756E2D7A6574616693" &
  "1315DCB6D3B3B43EEFC0D9C0CA02F19A16343D42E239B82576F5E1861BB3"

# `GoldenV4Pinned`: address "v4-pinned", attrsJson {"value":"pin","size":1},
# dependsOn @[], identity "stub:v4-pinned",
# digest digestString("digest-seed-v4-pinned"), present = true, holders {},
# keepHolders @["pin-a","pin-b"], keepHoldersKnown = true,
# effectiveDeadline NONE, lastRenewed 1_700_000_050. A keep-pinned record, so
# it also pins that v4's keep-holder fields survive the v5 lift unchanged —
# `keepHoldersKnown` must stay TRUE here rather than being re-derived by the
# pre-v4 rule, which would have made a named pin "unknown" again.
const GoldenV4Pinned =
  "5253535404000100A80000005700000060000000030000006800000070000000" &
  "88000000880000004C9122B3524A0CD7ACE6F57EF1567671275AA341396F1473" &
  "47E82FF03A585ED80196000000960000000100000000000000000032F1536500" &
  "00000076342D70696E6E65647273732E737475627273732E737475627B227661" &
  "6C7565223A2270696E222C2273697A65223A317D737475623A76342D70696E6E" &
  "6564080000000D00000070696E2D6170696E2D625CBED08893CE274193179787" &
  "022AB1CF70A737B995C74EC5CEDF5CF70C3B33D0"

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
    # version half-word (5 — the provider artifact named), NOT the legacy u32
    # version (2) and NOT the v3 / v4 envelopes that could not name it.
    let raw = readFile(store.root / "cluster.rec")
    check raw.len > 8
    check raw[0 .. 3] == "RSST"
    check byte(raw[4]) == 5'u8            # StateRecordSszVersion low byte
    check byte(raw[5]) == 0'u8

  test "back-compat: a legacy (u32 v2 LE) record still reads as the same record":
    let store = scratchStore("legacy")
    let rec = legacyShaped(sampleRecord("legacy-res"), known = true)  # dated
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
    rec = legacyShaped(rec, known = false)    # renewed, `none`: may hide a pin
    writeRawRecord(store, "pinned", encodeLegacyV2(rec))
    let back = readStateRecord(store, "pinned")
    check back.effectiveDeadline.isNone
    # The legacy format never recorded keep holders, so this `none` may be an
    # anonymous keep pin: the reader must say it does not know.
    check not back.keepHoldersKnown
    checkEqual(back, rec)

  test "garbage / truncated record fails cleanly (a cache miss, not a wrong record)":
    let store = scratchStore("garbage")
    writeRawRecord(store, "bad", @[byte(ord('R')), byte(ord('S')),
                                   byte(ord('S')), byte(ord('T')), 3'u8, 0'u8])
    expect CatchableError:
      discard readStateRecord(store, "bad")

  test "v4: keep holders are written canonically (sorted, de-duplicated)":
    let store = scratchStore("canon")
    var rec = sampleRecord("canon")
    rec.keepHolders = @["pin-z", "pin-a", "pin-z", "pin-m"]
    writeStateRecord(store, rec)
    let back = readStateRecord(store, "canon")
    check back.keepHolders == @["pin-a", "pin-m", "pin-z"]

    # Canonical bytes: the same holder SET in another order is the same file.
    let store2 = scratchStore("canon2")
    rec.keepHolders = @["pin-m", "pin-z", "pin-a"]
    writeStateRecord(store2, rec)
    check readFile(store.root / "canon.rec") == readFile(store2.root / "canon.rec")

  test "v4: an UNKNOWN keep-holder set survives a v4 write":
    # A record decoded from v3 that is still unknown must stay unknown when
    # re-written — otherwise one renewal would launder the doubt away.
    let store = scratchStore("unknown")
    var rec = sampleRecord("unknown")
    rec.keepHolders = @[]
    rec.keepHoldersKnown = false
    rec.effectiveDeadline = none(Time)
    writeStateRecord(store, rec)
    let back = readStateRecord(store, "unknown")
    check not back.keepHoldersKnown
    checkEqual(back, rec)

  test "v4: a consumer in BOTH holder sets is refused (invariant)":
    let store = scratchStore("both")
    var rec = sampleRecord("both")
    rec.keepHolders = @["run-alpha"]              # also a dated holder
    expect StateStoreCodecError:
      writeStateRecord(store, rec)

  test "v4: holders + keepHolders together are bounded":
    let store = scratchStore("bound")
    var rec = sampleRecord("bound")
    rec.keepHolders = @[]
    for i in 0 ..< 4095:                          # 2 dated + 4095 > 4096
      rec.keepHolders.add("k" & $i)
    expect StateStoreCodecError:
      writeStateRecord(store, rec)

  test "back-compat: a GOLDEN v3 SSZ record still decodes (keep holders unknown unless dated)":
    let store = scratchStore("v3")
    writeRawRecord(store, "v3-res", hexBytes(GoldenV3Dated))
    let back = readStateRecord(store, "v3-res")
    checkEqual(back, legacyShaped(sampleRecord("v3-res"), known = true))
    check back.keepHolders.len == 0
    check back.keepHoldersKnown            # a dated deadline proves no keep pin

    writeRawRecord(store, "v3-pinned", hexBytes(GoldenV3Pinned))
    let pinned = readStateRecord(store, "v3-pinned")
    check pinned.address == "v3-pinned"
    check pinned.holders.len == 1
    check pinned.holders["slow"] == fromUnix(1_700_000_900)
    check pinned.effectiveDeadline.isNone
    check pinned.keepHolders.len == 0
    check not pinned.keepHoldersKnown
    check listStateRecords(store).len == 2

  test "renewing an UNKNOWN pinned v3 record with a dated holder stays pinned":
    let store = scratchStore("v3-renew")
    writeRawRecord(store, "v3-pinned", hexBytes(GoldenV3Pinned))
    let old = readStateRecord(store, "v3-pinned")
    let now = fromUnix(1_700_100_000)
    let ttl = initDuration(minutes = 30)

    # Only the dated consumer renews. The record cannot say whether its
    # `none` was an anonymous keep pin, so it must not re-arm a deadline.
    let merged = mergeHolderDeadlines(some(old),
      @[leased("v3-pinned", "slow", delayed(ttl))], now)
    check merged.effective.isNone
    check not merged.keepHoldersKnown
    check merged.holders["slow"] == now + ttl     # still recorded by name
    check merged.keepHolders.len == 0

    # A keep consumer renewing it is recorded by name too, and the set is
    # STILL unknown: naming one keep holder does not prove there is no other.
    let merged2 = mergeHolderDeadlines(some(old),
      @[leased("v3-pinned", "pinner", keep())], now)
    check merged2.keepHolders == @["pinner"]
    check not merged2.keepHoldersKnown
    check merged2.effective.isNone

  test "renewing a DATED v3 record follows the normal rule (it decodes as known)":
    let store = scratchStore("v3-dated-renew")
    writeRawRecord(store, "v3-res", hexBytes(GoldenV3Dated))
    let old = readStateRecord(store, "v3-res")
    check old.keepHoldersKnown
    let now = fromUnix(1_700_100_000)
    let ttl = initDuration(minutes = 30)

    # `some(deadline)` was only ever written with no keep holder renewing, so
    # the record already proves there is none: the merge may follow the
    # normal rule, and the result is known.
    let merged = mergeHolderDeadlines(some(old),
      @[leased("v3-res", "run-alpha", delayed(ttl))], now)
    check merged.keepHoldersKnown
    check merged.keepHolders.len == 0
    check merged.holders["run-alpha"] == now + ttl
    check merged.holders["run-zeta"] == fromUnix(1_700_000_900)
    check merged.effective == some(now + ttl)

  test "back-compat: a v3 record never renewed (lastRenewed 0) decodes as known":
    let store = scratchStore("v3-unleased")
    writeRawRecord(store, "v3-unleased", hexBytes(GoldenV3Unleased))
    let rec = readStateRecord(store, "v3-unleased")
    check rec.address == "v3-unleased"
    check rec.lastRenewed == fromUnix(0)
    check rec.holders.len == 0
    check rec.effectiveDeadline.isNone
    check rec.keepHolders.len == 0
    # No renewal ever touched it, so no keep holder can be hiding behind its
    # `none`: the empty keep-holder set is the complete one.
    check rec.keepHoldersKnown

    # Hence the first dated lease on it arms a real deadline, instead of the
    # state being pinned forever by a keep holder that never existed.
    let now = fromUnix(1_700_100_000)
    let ttl = initDuration(minutes = 30)
    let merged = mergeHolderDeadlines(some(rec),
      @[leased("v3-unleased", "slow", delayed(ttl))], now)
    check merged.keepHoldersKnown
    check merged.effective == some(now + ttl)

  test "v5: a record with NO provider artifact round-trips as none":
    # The in-tree case, and the common one: a resource whose driver was linked
    # in the materializing process has no provider binary to record. `none`
    # must survive the write, because it is what routes the record's reap to
    # the in-process arm (Ephemeral-State-Leases.md §4.2).
    let store = scratchStore("v5-none")
    var rec = sampleRecord("v5-none")
    rec.providerArtifact = none(ResourceProviderArtifactRef)
    writeStateRecord(store, rec)
    let back = readStateRecord(store, "v5-none")
    check back.providerArtifact.isNone
    checkEqual(back, rec)

  test "v5: a present provider artifact with an EMPTY binaryPath is refused":
    # A ref that names no binary cannot launch anything, so persisting it as
    # PRESENT would make the record's reap try to spawn the empty string on
    # every tick — while `none` would correctly route it in-process. The two
    # must stay distinguishable, so the codec refuses the contradiction at the
    # write rather than leaving it for the reaper.
    let store = scratchStore("v5-empty")
    var rec = sampleRecord("v5-empty")
    rec.providerArtifact = some(ResourceProviderArtifactRef(
      binaryPath: "", providerArtifactId: "x", workingDir: "/w"))
    expect StateStoreCodecError:
      writeStateRecord(store, rec)

  test "back-compat: a GOLDEN v4 SSZ record still decodes, with no artifact":
    ## The read-old half of the v5 bump. A v4 writer recorded no route to the
    ## provider, so the record has none — and `providerArtifact == none` is the
    ## correct answer rather than an unknown that must be treated
    ## conservatively: nothing is pinned by it, and a type the reaper cannot
    ## reach is reported by the §4.5 finding rather than silently retried.
    let store = scratchStore("v4-golden")
    writeRawRecord(store, "v4-res", hexBytes(GoldenV4Dated))
    let back = readStateRecord(store, "v4-res")
    check back.providerArtifact.isNone
    check back.address == "v4-res"
    check back.typeId == "rss.stub"
    check back.attrsTypeId == "rss.stub"
    check back.attrsJson == "{\"value\":\"hello\",\"size\":7}"
    check back.determinism == rdVolatile
    check back.dependsOn == @["base", "net"]
    check back.identity == "stub:v4-res"
    check back.digest == digestString("digest-seed-v4-res")
    check back.present
    check back.holders.len == 2
    check back.holders["run-alpha"] == fromUnix(1_700_000_100)
    check back.holders["run-zeta"] == fromUnix(1_700_000_900)
    check back.keepHolders.len == 0
    check back.keepHoldersKnown
    check back.effectiveDeadline == some(fromUnix(1_700_000_900))
    check back.lastRenewed == fromUnix(1_700_000_050)

    # And it is LISTED too (the sweep shares the decoder) — a v4 store must not
    # read as a store full of foreign or quarantined records, which would park
    # every record on the host out of the reaper's reach.
    let all = listStateRecords(store)
    check all.len == 1
    check all[0].address == "v4-res"

  test "back-compat: a GOLDEN v4 keep-PINNED record keeps its named holders":
    ## v4 is the first format that named keep holders, so the v5 lift must copy
    ## them through AS KNOWN. Routing a v4 payload through the pre-v4 rule
    ## instead (`pre4KeepHoldersKnown`, which sees a `none` deadline and answers
    ## "unknown") would re-introduce the anonymous-pin doubt for records that
    ## state their pins by name.
    let store = scratchStore("v4-pinned")
    writeRawRecord(store, "v4-pinned", hexBytes(GoldenV4Pinned))
    let back = readStateRecord(store, "v4-pinned")
    check back.providerArtifact.isNone
    check back.address == "v4-pinned"
    check back.keepHolders == @["pin-a", "pin-b"]
    check back.keepHoldersKnown          # NAMED, not re-derived as unknown
    check back.holders.len == 0
    check back.effectiveDeadline.isNone
    check back.lastRenewed == fromUnix(1_700_000_050)
    check back.digest == digestString("digest-seed-v4-pinned")

  test "v5: a v4 record UPGRADES to v5 on its next write":
    # Read-old / write-new. The upgrade is what lets a record acquire a
    # provider artifact at all: a store written by the previous repro is
    # readable, and the first write by this one moves it onto the format that
    # can carry the route.
    let store = scratchStore("v4-upgrade")
    writeRawRecord(store, "v4-res", hexBytes(GoldenV4Dated))
    check byte(readFile(store.root / "v4-res.rec")[4]) == 4'u8
    var rec = readStateRecord(store, "v4-res")
    rec.providerArtifact = some(ResourceProviderArtifactRef(
      binaryPath: "/nix/store/upgraded/bin/prov",
      providerArtifactId: "cafe", workingDir: "/w"))
    writeStateRecord(store, rec)
    check byte(readFile(store.root / "v4-res.rec")[4]) == 5'u8
    let back = readStateRecord(store, "v4-res")
    check back.providerArtifact.isSome
    check back.providerArtifact.get.binaryPath == "/nix/store/upgraded/bin/prov"
    check back.providerArtifact.get.providerArtifactId == "cafe"
    checkEqual(back, rec)

  test "v5: a record one version NEWER than v5 is foreign, not corrupt":
    # The version sniff must keep treating anything above the current version
    # as a newer repro's record — left untouched, never quarantined out from
    # under the writer that owns it. A v5 bump that forgot this would
    # quarantine every v6 record on a shared per-user store.
    let store = scratchStore("v6-foreign")
    let rec = sampleRecord("future")
    writeStateRecord(store, rec)
    var bytes = readFile(store.root / "future.rec")
    bytes[4] = char(StateRecordSszVersion + 1)
    writeFile(store.root / "future.rec", bytes)
    expect ForeignStateRecordError:
      discard readStateRecord(store, "future")
    let scan = scanStateRecords(store)
    check scan.records.len == 0
    check scan.foreign.len == 1
    check scan.foreign[0].version == StateRecordSszVersion + 1
    check scan.quarantined.len == 0
    check fileExists(store.root / "future.rec")
