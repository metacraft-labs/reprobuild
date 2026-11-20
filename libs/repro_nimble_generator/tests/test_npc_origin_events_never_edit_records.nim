## NPC-M4 verification `test_npc_origin_events_never_edit_records` (spec
## § 18, NPC-AREQ4, threat model G7): after a name is repointed, a tag is
## moved and a repository is deleted, the old version records are
## byte-identical and three events exist.

import std/[options, os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator
import repro_nimble_index

import ./generator_fixtures

proc byTag(e: PackageEnvelope; tag, commit: string): VersionRecord =
  for v in e.versions:
    if v.version.tag == tag and v.commit == commit: return v
  doAssert false, "no record " & tag & "@" & commit & " of " & e.name

suite "NPC-M4: origin events never edit a record":

  test "a repoint, a moved tag and a deleted repository: three events, old records unchanged":
    let f = newFixture("events")
    # Three packages, each with a recorded version.
    let moved = f.newRepo("nim/moved.git")
    let movedV1 = moved.commit(@[nimbleFile("moved"),
      file("src/moved.nim", "discard\n")])
    moved.tag("v1.0.0")
    moved.publish()
    let repointed = f.newRepo("nim/repointed.git")
    let repointedV1 = repointed.commit(@[nimbleFile("repointed"),
      file("src/repointed.nim", "discard\n")])
    repointed.tag("v1.0.0")
    repointed.publish()
    let doomed = f.newRepo("nim/doomed.git")
    let doomedV1 = doomed.commit(@[nimbleFile("doomed", @["moved >= 1.0.0"]),
      file("src/doomed.nim", "discard\n")])
    doomed.tag("0.5.0")
    doomed.publish()
    let fork = f.newRepo("fork/repointed.git")
    discard fork.commit(@[nimbleFile("repointed", @["doomed"]),
      file("src/repointed.nim", "echo \"fork\"\n")])
    fork.tag("v1.0.0")
    fork.tag("v2.0.0")
    fork.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let reg1 = reg.commit(@[packagesJson(@[
      ("moved", f.url("nim/moved.git")),
      ("repointed", f.url("nim/repointed.git")),
      ("doomed", f.url("nim/doomed.git"))])])
    let reg2 = reg.commit(@[packagesJson(@[
      ("moved", f.url("nim/moved.git")),
      ("repointed", f.url("fork/repointed.git")),
      ("doomed", f.url("nim/doomed.git"))])])
    reg.publish()
    let regUrl = f.url("nim-lang/packages.git")
    let work = createTempDir("npc-m4-events-run-", "")

    let first = generate(f.genConfig(parseSourceSet(
      sourceSetText(regUrl, reg1), "s.toml"), 1_790_000_000, work / "state",
      outputDir = work / "gen1"))
    check first.events.len == 0
    let before = @[
      first.built.envelopeOf("moved").byTag("v1.0.0", movedV1),
      first.built.envelopeOf("repointed").byTag("v1.0.0", repointedV1),
      first.built.envelopeOf("doomed").byTag("0.5.0", doomedV1)]

    # Upstream changes: the registry repoints `repointed` to the fork, the
    # `moved` tag is moved to a new commit, and `doomed` is deleted.
    let movedV2 = moved.commit(@[nimbleFile("moved", @["doomed"]),
      file("src/moved.nim", "echo 2\n")], date = 1_700_500_000)
    moved.tag("v1.0.0")
    moved.publish()
    f.deleteServed("nim/doomed.git")

    let second = generate(f.genConfig(parseSourceSet(
      sourceSetText(regUrl, reg2), "s.toml"), 1_790_086_400, work / "state",
      previous = work / "gen1", outputDir = work / "gen2"))
    let after = @[
      second.built.envelopeOf("moved").byTag("v1.0.0", movedV1),
      second.built.envelopeOf("repointed").byTag("v1.0.0", repointedV1),
      second.built.envelopeOf("doomed").byTag("0.5.0", doomedV1)]
    for i in 0 ..< before.len:
      check recordBytes(after[i]) == recordBytes(before[i])
      check after[i] == before[i]

    var kinds: seq[string]
    for e in second.events: kinds.add $e.kind & " " & e.package
    checkpoint kinds.join("; ")
    check second.events.len == 3
    check "repointed repointed" in kinds
    check "tag-moved moved" in kinds
    check "gone doomed" in kinds
    for e in second.events:
      case e.kind
      of oeTagMoved:
        check e.version == "v1.0.0"
        check e.before == movedV1
        check e.after == movedV2
      of oeRepointed:
        check e.before == f.url("nim/repointed.git")
        check e.after == f.url("fork/repointed.git")
      else: discard
      check e.observedAt == 1_790_086_400'u64
    # The events are part of the index.
    var idx = openIndex(memorySource(second.built.objectTable()),
      second.built.rootId)
    check idx.loadEvents().events == second.events
    check second.built.root.previousRoot.get == first.built.rootId

    # The moved tag's new commit is a new record beside the old one, the
    # repointed package keeps its old origin for its old record, and the
    # fork's versions are records of the new origin.
    let m = second.built.envelopeOf("moved")
    check m.versions.len == 2
    check m.byTag("v1.0.0", movedV2).firstSeen == 1_790_086_400'u64
    let r = second.built.envelopeOf("repointed")
    check r.origins.len == 2
    check r.origins[r.registryOrigin].url == f.url("fork/repointed.git")
    check r.byTag("v1.0.0", repointedV1).origin == 0
    var forkRecords = 0
    for v in r.versions:
      if v.origin == r.registryOrigin: inc forkRecords
    check forkRecords == 2
    check second.built.observationOf("doomed").state == osGone

    # A third generation with nothing changed upstream: no new event, and
    # every record still byte-identical.
    let third = generate(f.genConfig(parseSourceSet(
      sourceSetText(regUrl, reg2), "s.toml"), 1_790_172_800, work / "state",
      previous = work / "gen2"))
    check third.events.len == 0
    for name in ["moved", "repointed", "doomed"]:
      check third.built.envelopeOf(name).versions ==
        second.built.envelopeOf(name).versions
