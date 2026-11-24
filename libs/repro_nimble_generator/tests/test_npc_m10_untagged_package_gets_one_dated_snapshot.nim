## NPC-M10 verification `test_npc_m10_untagged_package_gets_one_dated_snapshot`
## (operator ruling A5; NPC-AREQ31 item 5).
##
## The origins are local bare repositories behind the fixture's TLS
## listener: `untagged` has no tags, `labels` only the tags `latest` and
## `release-x`, and `tagged` has `v1.0.0`. `untagged` and `labels` each get
## exactly one snapshot record of their `HEAD` commit, with its digests,
## `size` and `first_seen`, spelled `#snapshot/<date>/<commit>` with the
## generation's UTC date; `tagged` gets none. A solve of `requires
## "untagged"` chooses the snapshot; the ranged requirements `>= 0.0.0`,
## `< 9.0` and `^= 0.1` each fail, and the failure names the snapshot and
## says that no range admits it. A shard holding a snapshot is schema 4,
## and the same bytes labelled schema 3 are refused.
##
## Falsifying mutation (recorded in the plan): offering the snapshot under a
## semver-ordered solver version such as `0.0.0-snapshot.<date>` lets
## `untagged < 9.0` choose it, and fails the test.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator
import repro_nimble_index

import ./generator_fixtures
import ./snapshot_fixtures

const Now = 1_790_000_000'u64

suite "NPC-M10: a package without version tags gets one dated snapshot":

  test "untagged and label-only origins get one snapshot of HEAD; no range admits it":
    let f = newFixture("m10-snapshot")
    let untagged = f.newRepo("nim/untagged.git")
    discard untagged.commit(@[nimbleFile("untagged"),
      file("src/untagged.nim", "proc untagged*(): int = 1\n")])
    let untaggedHead = untagged.commit(@[nimbleFile("untagged"),
      file("src/untagged.nim", "proc untagged*(): int = 2\n")])
    untagged.publish()
    let labels = f.newRepo("nim/labels.git")
    let labelsHead = labels.commit(@[nimbleFile("labels"),
      file("src/labels.nim", "discard\n")])
    labels.tag("latest")
    labels.tag("release-x")
    labels.publish()
    let tagged = f.newRepo("nim/tagged.git")
    discard tagged.commit(@[nimbleFile("tagged"),
      file("src/tagged.nim", "discard\n")])
    tagged.tag("v1.0.0")
    tagged.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = reg.commit(@[packagesJson(@[
      ("untagged", f.url("nim/untagged.git")),
      ("labels", f.url("nim/labels.git")),
      ("tagged", f.url("nim/tagged.git"))])])
    reg.publish()
    let work = createTempDir("npc-m10-snapshot-", "")
    let g = generate(f.genConfig(parseSourceSet(sourceSetText(
      f.url("nim-lang/packages.git"), regCommit), "s.toml"), Now,
      work / "state", outputDir = work / "index"))
    checkpoint g.diagnostics.join("\n")

    # One snapshot of HEAD each, dated by the generation, with digests.
    for (name, head) in [("untagged", untaggedHead), ("labels", labelsHead)]:
      var snapshots: seq[VersionRecord]
      for r in g.built.envelopeOf(name).versions:
        if r.version.kind == rvkSnapshot: snapshots.add r
      check snapshots.len == 1
      let s = snapshots[0]
      check s.commit == head
      check s.firstSeen == Now
      check s.version.tag == ""
      check snapshotDateText(s.version) == utcDateText(Now)
      check snapshotVersionText(s.version, s.commit) ==
        "#snapshot/" & utcDateText(Now) & "/" & head
      check s.tree != default(IndexObjectId)
      check s.archiveSha256 != default(Sha256Digest)
      check s.size > 0
      check flUnreadable notin s.flags
    var labelRecords = 0
    for r in g.built.envelopeOf("labels").versions:
      if r.version.kind == rvkLabel: inc labelRecords
    check labelRecords == 2
    for r in g.built.envelopeOf("tagged").versions:
      check r.version.kind == rvkTag
    check g.built.envelopeOf("untagged").versions.len == 1

    # The shard that holds a snapshot is schema 4; the same bytes labelled
    # schema 3 (whose layout they share) are refused, never misread.
    var idx = openIndex(memorySource(g.built.objectTable()), g.built.rootId)
    let bucket = shardBucket(nameKey("untagged"), int(idx.root.shardBits))
    var shardBytes: seq[byte]
    for r in idx.root.shards:
      if r.bucket == bucket:
        shardBytes = g.built.objectTable()[r.id]
    check shardBytes.len > 0
    check shardSchemaOf(decodeShard(shardBytes)) == NimbleShardSnapshotsSchema
    var relabelled = shardBytes
    relabelled[FrameHeaderLen] = byte(NimbleShardConditionsSchema)
    relabelled[FrameHeaderLen + 1] = 0
    var reason = ""
    try:
      discard decodeShard(relabelled)
    except NimbleIndexError as e:
      reason = $e.reason
    check reason == $nrUnknownVocabulary

    # "Any version" chooses the snapshot.
    let objects = g.built.objectTable()
    let snapshotText = "#snapshot/" & utcDateText(Now) & "/" & untaggedHead
    let any = solveOver(objects, g.built.rootId, @["untagged"])
    checkpoint any.failure
    check any.failure == ""
    check any.chosen.getOrDefault("nimble:untagged") == snapshotText

    # No range admits it, and the failure says so, naming it.
    for ranged in ["untagged >= 0.0.0", "untagged < 9.0", "untagged ^= 0.1"]:
      let s = solveOver(objects, g.built.rootId, @[ranged])
      checkpoint ranged & ":\n" & s.failure
      check s.failure.len > 0
      check "nimble:untagged" notin s.chosen
      check snapshotText in s.failure
      check "no range admits a snapshot" in s.failure
