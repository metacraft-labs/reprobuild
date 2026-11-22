## NPC-M10 verification `test_npc_m10_head_move_supersedes_snapshot`
## (operator ruling A5; NPC-AREQ31 item 5, NPC-AREQ5; threat model G40).
##
## After `untagged`'s `HEAD` moves and the next generation runs, the index
## holds both snapshot records. The older record is byte-identical to
## before, a fresh solve chooses the newer one, and the older one is
## excluded as `snapshot-superseded`, naming the newer one. With
## `cooldown_days = 7` the new commit is held back and the older snapshot
## stays offered (the positive control for the hold); once the seven days
## have passed it is admitted, dated by its first sighting, not by the
## generation that admits it.
##
## Falsifying mutation (recorded in the plan): replacing the snapshot
## record in place, instead of adding one, changes the old record's bytes
## and fails the test.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator
import repro_nimble_index

import ./generator_fixtures
import ./snapshot_fixtures

const
  Day = 86_400'u64
  T1 = 1_790_000_000'u64
  T2 = T1 + 2 * Day

proc snapshotsOf(b: BuiltIndex; name: string): seq[VersionRecord] =
  for r in b.envelopeOf(name).versions:
    if r.version.kind == rvkSnapshot: result.add r

suite "NPC-M10: a moved HEAD adds a snapshot and supersedes the old one":

  test "both records kept, the old one unchanged and superseded; a cooldown holds the new one":
    let f = newFixture("m10-head-move")
    let repo = f.newRepo("nim/untagged.git")
    let c1 = repo.commit(@[nimbleFile("untagged"),
      file("src/untagged.nim", "proc v*(): int = 1\n")])
    repo.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = reg.commit(@[packagesJson(@[
      ("untagged", f.url("nim/untagged.git"))])])
    reg.publish()
    let regUrl = f.url("nim-lang/packages.git")
    let plain = parseSourceSet(sourceSetText(regUrl, regCommit), "s.toml")
    let held = parseSourceSet(sourceSetText(regUrl, regCommit,
      "\n[policy]\ncooldown_days = 7\n"), "s.toml")
    let work = createTempDir("npc-m10-head-move-", "")

    let g1 = generate(f.genConfig(plain, T1, work / "state",
      outputDir = work / "g1"))
    let first = g1.built.snapshotsOf("untagged")
    check first.len == 1
    check first[0].commit == c1
    let firstBytes = recordBytes(first[0])
    let s1 = snapshotVersionText(first[0].version, c1)

    # HEAD moves.
    let c2 = repo.commit(@[nimbleFile("untagged"),
      file("src/untagged.nim", "proc v*(): int = 2\n")])
    repo.publish()

    let g2 = generate(f.genConfig(plain, T2, work / "state",
      previous = work / "g1", outputDir = work / "g2"))
    checkpoint g2.diagnostics.join("\n")
    let both = g2.built.snapshotsOf("untagged")
    check both.len == 2
    var older, newer: VersionRecord
    for r in both:
      if r.commit == c1: older = r
      if r.commit == c2: newer = r
    check older.commit == c1
    check newer.commit == c2
    check recordBytes(older) == firstBytes
    check newer.firstSeen == T2
    check snapshotDateText(newer.version) == utcDateText(T2)
    let s2 = snapshotVersionText(newer.version, c2)

    let fresh = solveOver(g2.built.objectTable(), g2.built.rootId,
      @["untagged"])
    checkpoint fresh.failure
    check fresh.failure == ""
    check fresh.chosen.getOrDefault("nimble:untagged") == s2
    let old = fresh.candidateOf("untagged", s1)
    check old.exclusions.len == 1
    check old.exclusions[0].kind == exSnapshotSuperseded
    check s2 in old.exclusions[0].detail
    check fresh.candidateOf("untagged", s2).offered

    # Positive control for the hold: with cooldown_days = 7 the moved HEAD
    # is held from its first sighting, and the older snapshot stays the one
    # offered.
    let g2held = generate(f.genConfig(held, T2, work / "state-held",
      previous = work / "g1", outputDir = work / "g2held"))
    let kept = g2held.built.snapshotsOf("untagged")
    check kept.len == 1
    check kept[0].commit == c1
    check recordBytes(kept[0]) == firstBytes
    let waiting = g2held.built.observationOf("untagged").held
    check waiting.len == 1
    check waiting[0].version.kind == rvkSnapshot
    check waiting[0].commit == c2
    check waiting[0].firstSeen == T2
    let during = solveOver(g2held.built.objectTable(), g2held.built.rootId,
      @["untagged"])
    checkpoint during.failure
    check during.failure == ""
    check during.chosen.getOrDefault("nimble:untagged") == s1

    # Eight days later the held snapshot has waited out the cooldown: it is
    # admitted with the first sighting it was held under (T2), so its date
    # is T2's, not the admitting generation's, and it supersedes the older
    # one. A held snapshot whose sighting were not matched to its held copy
    # would be re-sighted at every generation and never admitted.
    let t3 = T2 + 8 * Day
    check utcDateText(T2) != utcDateText(t3)
    let g3held = generate(f.genConfig(held, t3, work / "state-held",
      previous = work / "g2held", outputDir = work / "g3held"))
    checkpoint g3held.diagnostics.join("\n")
    let admitted = g3held.built.snapshotsOf("untagged")
    check admitted.len == 2
    var late: VersionRecord
    for r in admitted:
      if r.commit == c2: late = r
    check late.commit == c2
    check late.firstSeen == T2
    check snapshotDateText(late.version) == utcDateText(T2)
    check g3held.built.observationOf("untagged").held.len == 0
    let after = solveOver(g3held.built.objectTable(), g3held.built.rootId,
      @["untagged"])
    checkpoint after.failure
    check after.failure == ""
    check after.chosen.getOrDefault("nimble:untagged") == s2
