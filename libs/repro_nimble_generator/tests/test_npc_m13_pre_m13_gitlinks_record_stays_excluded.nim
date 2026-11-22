## NPC-M13 verification `test_npc_m13_pre_m13_gitlinks_record_stays_excluded`
## (spec § 6.1, "Digest and record"; § 4.4, the NPC-M13 amendment).
##
## A generator before submodule sources recorded a version with gitlinks
## flagged `gitlinks`, with the superproject's tree alone and no
## `submodules` list. Such a record:
##
## * is refused as the base of a new generation: the generator names it and
##   says to regenerate, before contacting anything (records are never
##   edited, so it cannot be carried forward or repaired);
## * is excluded by the solver input as `gitlinks`, while a record WITH a
##   list is offered (positive control).
##
## And the encoding: a shard with no list is schema 1, byte for byte as
## before; one holding a list is schema 2, which a reader of schema 1 alone
## refuses as an unknown schema, so it can never read the record without
## its list; a schema-2 frame relabelled as schema 1 is refused, not misread.
##
## Falsifying mutation: carrying the old record forward offers a version
## whose tree lacks its submodules (the generation proceeds).

import std/[options, os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator
import repro_nimble_index

import ./generator_fixtures
import ../../repro_nimble_index/tests/index_fixtures

proc staleRecord(): VersionRecord =
  result = record("oldsubs", "v1.0.0")
  result.flags.incl flGitlinks

proc listedRecord(): VersionRecord =
  result = record("oldsubs", "v2.0.0")
  result.flags.incl flGitlinks
  result.submodules = @[RecordSubmodule(path: "vendor/x",
    url: "https://example.invalid/nim/x", commit: repeat('c', 40))]

suite "NPC-M13: a gitlinks record from before submodule sources":
  test "the generator refuses to extend an index holding one, naming it":
    let f = newFixture("m13-pre")
    let work = createTempDir("npc-m13-pre-", "")
    let previous = work / "previous"
    let built = buildIndex(buildInput(@[package("oldsubs", @[staleRecord()]),
      package("plain", @[record("plain", "v1.0.0")])]))
    writeIndexDir(built, previous)
    let ss = parseSourceSet(sourceSetText(f.url("nim-lang/packages.git"),
      repeat('e', 40)), "s.toml")
    var refusal = ""
    try:
      discard generate(f.genConfig(ss, 1_790_000_000, work / "state",
        previous = previous))
    except GeneratorError as e:
      refusal = e.msg
    checkpoint refusal
    check "oldsubs v1.0.0 (" & staleRecord().commit & ")" in refusal
    check "without a submodules list" in refusal
    check "generate it again without a previous generation" in refusal
    # Refused before any edge ran: the forge saw nothing.
    check f.requests().len == 0

  test "the solver input excludes it as gitlinks; a record with its list is offered":
    let p = package("oldsubs", @[staleRecord(), listedRecord()])
    let plat = NimblePlatform(id: "linux-amd64", targetOs: "linux",
      targetCpu: "amd64", hostOs: "linux", hostCpu: "amd64")
    let stale = candidate(p, staleRecord(), plat)
    var kinds: seq[ExclusionKind]
    for x in stale.exclusions: kinds.add x.kind
    check kinds == @[exGitlinks]
    let listed = candidate(p, listedRecord(), plat)
    check listed.offered
    # Through the index, as a solve reads it.
    let both = buildIndex(buildInput(@[p]))
    var idx = openIndex(memorySource(both.objectTable()), both.rootId)
    let input = solverInput(idx, ["oldsubs"], plat)
    var offered: seq[string]
    for pkg in input.packages:
      for c in pkg.candidates:
        if c.offered: offered.add c.record.version.tag
    check offered == @["v2.0.0"]

  test "a shard with a submodules list is schema 2; schema 1 is unchanged":
    let plainShard = NimbleShard(packages: @[package("oldsubs",
      @[staleRecord()])])
    let withList = NimbleShard(packages: @[package("oldsubs",
      @[staleRecord(), listedRecord()])])
    let b1 = encodeShard(plainShard)
    let b2 = encodeShard(withList)
    proc schemaOf(b: seq[byte]): int = int(b[12]) or (int(b[13]) shl 8)
    check schemaOf(b1) == 1
    check schemaOf(b2) == 2
    check shardSchemaOf(withList) == NimbleShardSubmodulesSchema
    check decodeShard(b2).packages[0].versions[1].submodules ==
      listedRecord().submodules
    check decodeShard(b1).packages[0].versions[0].submodules.len == 0
    check acceptsSchema(nokShard, 2)
    check not acceptsSchema(nokRoot, 2)
    # Relabelled as schema 1, the schema-2 bytes are refused, never read as
    # records without their list.
    var relabelled = b2
    relabelled[12] = 1
    var reason = ""
    try:
      discard decodeShard(relabelled)
    except NimbleIndexError as e:
      reason = $e.reason
    check reason.len > 0
    # Schema 2 without any list is not the canonical encoding.
    var upgraded = b1
    upgraded[12] = 2
    reason = ""
    try:
      discard decodeShard(upgraded)
    except NimbleIndexError as e:
      reason = $e.reason
    check reason.len > 0
