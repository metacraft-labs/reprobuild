## NPC-M10 verification `test_npc_m10_force_pushed_head_snapshot_is_an_event`
## (threat model T38, G40; operator ruling A5).
##
## `untagged`'s history is rewritten and force-pushed, so the commit of its
## snapshot no longer has a branch. The next generation records
## `history-rewritten` naming that commit and keeps the old record
## byte-identical. Under `cooldown_days = 7` it offers no snapshot of the
## new `HEAD` before seven days have passed. Once it does, `repro lock
## refresh` moves the project's row to the new snapshot and says so, and
## `repro lock diff` of the old lock against the refreshed one shows the
## move as `snapshot superseded` beside the event.
##
## The generations are the real generator's, run against the HTTPS fixture's
## origins; each is published, with its events, as a commit of a real index
## repository, which the lock verbs read through the shared clone.
##
## Falsifying mutation (recorded in the plan): evaluating
## `history-rewritten` for tag records only leaves the event out, and fails
## the test.

import std/[os, strutils, tempfiles, unittest]

import repro_nimble_generator

import ./nimble_m7_fixtures

const Day = 86_400'u64

proc snapshotsOf(b: BuiltIndex): seq[VersionRecord] =
  for r in b.envelopeOf("untagged").versions:
    if r.version.kind == rvkSnapshot: result.add r

suite "NPC-M10: a force-pushed HEAD of an untagged package is an origin event":

  test "history-rewritten names the snapshot's commit; the cooldown holds the new HEAD; the diff shows both":
    var w = newWorld("m10-force-push")
    let f = newFixture("m10-force-push")
    let repo = f.newRepo("nim/untagged.git")
    let c1 = repo.commit(@[nimbleFile("untagged"),
      file("src/untagged.nim", "proc v*(): int = 1\n")])
    repo.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = reg.commit(@[packagesJson(@[
      ("untagged", f.url("nim/untagged.git"))])])
    reg.publish()
    let ss = parseSourceSet(sourceSetText(f.url("nim-lang/packages.git"),
      regCommit, "\n[policy]\ncooldown_days = 7\n"), "s.toml")
    let work = createTempDir("npc-m10-force-push-", "")
    let t0 = uint64(daysAgo(30))

    proc generation(at: uint64; name, previous: string): GenerationResult =
      result = generate(f.genConfig(ss, at, work / "state",
        previous = (if previous.len > 0: work / previous else: ""),
        outputDir = work / name))
      checkpoint name & ": " & result.diagnostics.join("\n  ")

    proc publishGeneration(g: GenerationResult; message: string) =
      discard w.publish(@[g.built.envelopeOf("untagged")],
        int64(g.built.root.generatedAt), message, events = g.events)

    # First sighting, held for seven days, then the snapshot of c1.
    let g0 = generation(t0, "g0", "")
    check not g0.built.hasPackage("untagged")
    let g1 = generation(t0 + 8 * Day, "g1", "g0")
    let first = g1.built.snapshotsOf()
    check first.len == 1
    check first[0].commit == c1
    check first[0].firstSeen == t0
    let firstBytes = recordBytes(first[0])
    let s1 = snapshotVersionText(first[0].version, c1)
    publishGeneration(g1, "g1")

    let dir = w.newProject(@[("untagged", "")])
    let locked = refreshProvisioning(dir)
    checkpoint locked.output
    check locked.rc == 0
    check nimbleRows(dir)["nimble:untagged"].version == s1
    let oldLock = work / "old.lock"
    copyFile(dir / "repro.lock", oldLock)

    # The history is rewritten: an unrelated root commit force-pushed as
    # `main`, so c1 is on no branch any more.
    discard git(repo, "checkout", "-q", "--orphan", "rewritten")
    let c2 = repo.commit(@[nimbleFile("untagged"),
      file("src/untagged.nim", "proc v*(): int = 2\n")], "rewritten")
    discard git(repo, "branch", "-M", "main")
    repo.publish()

    let g2 = generation(t0 + 9 * Day, "g2", "g1")
    var rewritten = 0
    for e in g2.events:
      checkpoint $e.kind & " " & e.version & " " & e.before & " -> " & e.after
      if e.kind == oeHistoryRewritten and e.package == "untagged":
        inc rewritten
        check e.before == c1
        check e.version == c1
    check rewritten == 1
    let kept = g2.built.snapshotsOf()
    check kept.len == 1
    check recordBytes(kept[0]) == firstBytes
    let waiting = g2.built.observationOf("untagged").held
    check waiting.len == 1
    check waiting[0].commit == c2
    check waiting[0].version.kind == rvkSnapshot
    publishGeneration(g2, "g2")

    # Six days after its first sighting the new HEAD is still held.
    let g2b = generation(t0 + 15 * Day, "g2b", "g2")
    check g2b.built.snapshotsOf().len == 1
    publishGeneration(g2b, "g2b")
    # Seven days after: its snapshot, dated by that first sighting.
    let g3 = generation(t0 + 16 * Day, "g3", "g2b")
    let both = g3.built.snapshotsOf()
    check both.len == 2
    var second: VersionRecord
    for r in both:
      if r.commit == c2: second = r
    check second.firstSeen == t0 + 9 * Day
    let s2 = snapshotVersionText(second.version, c2)
    publishGeneration(g3, "g3")

    let moved = refreshProvisioning(dir)
    checkpoint moved.output
    check moved.rc == 0
    check nimbleRows(dir)["nimble:untagged"].version == s2
    check ("nimble:untagged " & s1 & " -> " & s2 & " (snapshot superseded)") in
      moved.output

    let diff = lockDiff(oldLock, dir / "repro.lock")
    checkpoint diff.output
    check (s1 & " -> " & s2 & " (snapshot superseded)") in diff.output
    var eventLines = 0
    for l in diff.output.splitLines():
      if "history-rewritten nimble:untagged" in l and c1 in l:
        inc eventLines
    check eventLines == 1
