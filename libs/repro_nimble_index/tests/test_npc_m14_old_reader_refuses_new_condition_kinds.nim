## NPC-M14 verification `test_npc_m14_old_reader_refuses_new_condition_kinds`
## (A3; NPC-AREQ7; spec § 4.4, the NPC-M14 amendment).
##
## A shard holding a record with a Nim-version condition is given to the
## decoder of the schemas before this milestone, and refused as an unknown
## schema or kind. It is never decoded as an unconditional requirement, nor
## as `defined(...)` of some name.
##
## "The decoder before this milestone" is ``preM14Decode`` below: the shard
## acceptance of reprobuild `9b2f56adc0` (NPC-M13), restated over the wire
## types it used, which this build still has -- the frame checks, the
## schemas it accepts (1 and 2, ``acceptsSchema``), the SSZ decode of
## ``ShardW`` / ``ShardW2``, and its closed vocabulary of seven condition
## node kinds (``enumFrom`` against `cnDefinedOs..cnNot`). The shard is
## checked twice: as this build encodes it now, and as the committed bytes
## `fixtures/npc_m14_nim_condition_shard.hex` (written by this build's
## encoder; the implementer also ran the real `9b2f56adc0` decoder on them,
## recorded in the plan).
##
## Falsifying mutation (recorded in the plan): reusing a platform term's
## node kind for the Nim-version term lets the old decoder read the
## requirement as `defined(...)` of a bogus name, and fails the test.

import std/[strutils, unittest]

import repro_nimble_index
import repro_domain_types/nimble_index/wire

import ./index_fixtures
import ./m14_fixtures

const FixtureHex = staticRead("fixtures/npc_m14_nim_condition_shard.hex")

type PreM14Answer = object
  refused: bool
  reason: string               ## `unknown-schema`, `unknown-record-kind`, ...
  conditions: seq[string]      ## when decoded: every requirement's condition

proc u16(b: openArray[byte]; at: int): int = int(b[at]) or (int(b[at + 1]) shl 8)

proc u32(b: openArray[byte]; at: int): int =
  for i in 0 ..< 4: result = result or (int(b[at + i]) shl (8 * i))

proc render(kind: uint8; name: string): string =
  case kind
  of 0, 1: "defined(" & name & ")"
  of 2: "hostOS == " & name.escape()
  of 3: "hostCPU == " & name.escape()
  of 4: "and"
  of 5: "or"
  else: "not"

proc collect(w: auto; into: var seq[string]; badKind: var bool) =
  for p in w.packages:
    for v in p.versions:
      for r in v.requires:
        var parts: seq[string]
        for n in r.condition:
          if n.kind > 6'u8:
            badKind = true
          var name = ""
          for c in n.name: name.add char(c)
          parts.add render(n.kind, name)
        into.add (if parts.len == 0: "" else: parts.join(" "))

proc preM14Decode(bytes: openArray[byte]): PreM14Answer =
  ## The shard acceptance of the NPC-M13 decoder (see the header).
  if bytes.len < 14 or bytes[0] != byte('R') or bytes[1] != byte('B') or
      bytes[2] != byte('S') or bytes[3] != byte('Z'):
    return PreM14Answer(refused: true, reason: "bad-magic")
  if u16(bytes, 4) != 1:
    return PreM14Answer(refused: true, reason: "unknown-frame-version")
  if u16(bytes, 6) != 0x1202:
    return PreM14Answer(refused: true, reason: "unknown-record-kind")
  if 12 + u32(bytes, 8) != bytes.len:
    return PreM14Answer(refused: true, reason: "length-mismatch")
  let schema = u16(bytes, 12)
  if schema notin [1, 2]:
    return PreM14Answer(refused: true, reason: "unknown-schema")
  var badKind = false
  try:
    if schema == 2:
      collect(SSZ.decode(bytes.toOpenArray(12, bytes.len - 1), ShardW2),
        result.conditions, badKind)
    else:
      collect(SSZ.decode(bytes.toOpenArray(12, bytes.len - 1), ShardW),
        result.conditions, badKind)
  except SerializationError:
    return PreM14Answer(refused: true, reason: "malformed")
  if badKind:
    return PreM14Answer(refused: true, reason: "unknown-vocabulary")

proc fromHex(hex: string): seq[byte] =
  let h = hex.strip()
  for i in countup(0, h.len - 2, 2):
    result.add byte(parseHexInt(h[i .. i + 1]))

proc conditionShard(): NimbleShard =
  let pkgs = chroniclesIdiomPackages()
  NimbleShard(shardBits: 0, bucket: 0, packages: @[pkgs[0]])

suite "NPC-M14: a reader from before the new condition kinds refuses them":
  test "this build writes the shard in schema 3 and reads it back":
    let s = conditionShard()
    let bytes = encodeShard(s)
    check shardSchemaOf(s) == NimbleShardConditionsSchema
    check u16(bytes, 12) == int(NimbleShardConditionsSchema)
    let back = decodeShard(bytes)
    check back == s
    var nimNodes = 0
    for r in back.packages[0].versions[0].requires:
      for n in r.condition:
        if n.kind == cnNimVersion:
          inc nimNodes
          check n.term == nvMajor
          check n.op == opGe
          check n.ints == @[2'u64]
    check nimNodes == 1

  test "the decoder before NPC-M14 refuses it, never reading the condition":
    for (label, bytes) in [("encoded now", encodeShard(conditionShard())),
                           ("committed fixture", fromHex(FixtureHex))]:
      checkpoint label
      let old = preM14Decode(bytes)
      check old.refused
      check old.reason in ["unknown-schema", "unknown-vocabulary"]
      # Never an unconditional requirement, never `defined(<bogus>)`.
      check old.conditions.len == 0

  test "the committed bytes are what this build writes":
    let fixture = fromHex(FixtureHex)
    check fixture == encodeShard(conditionShard())
    check decodeShard(fixture) == conditionShard()

  test "a shard without the new kinds keeps its pre-NPC-M14 schema":
    var s = conditionShard()
    s.packages[0].versions[0] = record("chronicles", "v0.10.3",
      @[req("json_serialization", condition = @[ConditionNode(
        kind: cnDefinedOs, name: "linux")])])
    let bytes = encodeShard(s)
    check u16(bytes, 12) == int(NimbleIndexSchemaVersion)
    let old = preM14Decode(bytes)
    check not old.refused
    check old.conditions == @["defined(linux)"]

  test "this build refuses a new kind in a schema-1 or schema-2 shard":
    # A schema-2 frame whose node kind is `nim-version` (8): the kinds of
    # schema 3 exist in schema 3 alone.
    var s = conditionShard()
    s.packages[0].versions[0] = record("chronicles", "v0.10.3",
      @[req("json_serialization", condition = @[ConditionNode(
        kind: cnDefinedOs, name: "linux")])])
    s.packages[0].versions[0].flags.incl flGitlinks
    s.packages[0].versions[0].submodules = @[RecordSubmodule(path: "vendor/x",
      url: "https://example.invalid/x", commit: "a".repeat(40))]
    var w = toW2(s)
    w.packages[0].versions[0].requires[0].condition[0].kind =
      uint8(ord(cnNimVersion))
    let payload = SSZ.encode(w)
    var bytes = @[byte('R'), byte('B'), byte('S'), byte('Z'), 1, 0, 0x02, 0x12]
    for i in 0 ..< 4: bytes.add byte((payload.len shr (8 * i)) and 0xff)
    bytes.add payload
    var reason = ""
    try:
      discard decodeShard(bytes)
    except NimbleIndexError as e:
      reason = $e.reason
    check reason == $nrUnknownVocabulary

  test "this build refuses a schema-3 shard with no new kind":
    # The schema is chosen by the value (spec § 4.4): a shard with no
    # Nim-version or OS-family node framed as schema 3 is non-canonical, so
    # one value never has two encodings.
    var s = conditionShard()
    s.packages[0].versions[0] = record("chronicles", "v0.10.3",
      @[req("json_serialization", condition = @[ConditionNode(
        kind: cnDefinedOs, name: "linux")])])
    let payload = SSZ.encode(toW3(s))
    var bytes = @[byte('R'), byte('B'), byte('S'), byte('Z'), 1, 0, 0x02, 0x12]
    for i in 0 ..< 4: bytes.add byte((payload.len shr (8 * i)) and 0xff)
    bytes.add payload
    check u16(bytes, 12) == int(NimbleShardConditionsSchema)
    var reason = ""
    try:
      discard decodeShard(bytes)
    except NimbleIndexError as e:
      reason = $e.reason
    check reason == $nrNonCanonical
