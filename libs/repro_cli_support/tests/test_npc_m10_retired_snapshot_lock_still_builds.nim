## NPC-M10 verification `test_npc_m10_retired_snapshot_lock_still_builds`
## (operator ruling A5; NPC-AREQ31 item 5, NPC-AREQ19).
##
## A project is locked on `untagged`'s snapshot. Then the origin tags
## `v0.1.0` and a generation runs: the package's snapshots are retired, and
## the record stays. Pinned to the new index revision (as a refresh of
## another package would pin it), the lock's `repro build` passes the
## record check, fetches the snapshot's tree by its digest from the
## directory mirror the index declares -- with the origin gone -- and
## compiles a program that imports it. `repro lock diff` against a refresh
## shows `#snapshot/<date>/<commit> -> 0.1.0 (snapshot retired)`, and a
## fresh solve excludes the snapshot as `snapshot-retired` and chooses
## `0.1.0`.
##
## The generations are the real generator's (it writes the archives to the
## directory mirror); the build is the built `build/bin/repro`.
##
## Falsifying mutation (recorded in the plan): dropping retired snapshot
## records from the next generation makes the build's record check refuse
## the locked row, and fails the test.

import std/[os, strutils, tempfiles, unittest]

import repro_nimble_generator

import ./nimble_m7_fixtures

const Day = 86_400'u64

suite "NPC-M10: a lock on a retired snapshot still builds":

  test "the retired row builds from the mirror; refresh moves it to 0.1.0 and says why":
    var w = newWorld("m10-retired")
    let f = newFixture("m10-retired")
    let mirrorDir = w.root / "mirror"
    createDir(mirrorDir)
    let repo = f.newRepo("nim/untagged.git")
    let c1 = repo.commit(@[nimbleFile("untagged"),
      file("src/untagged.nim", "proc untagged*(): string = \"SNAPSHOT-M10\"\n")])
    repo.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = reg.commit(@[packagesJson(@[
      ("untagged", f.url("nim/untagged.git"))])])
    reg.publish()
    let ss = parseSourceSet(sourceSetText(f.url("nim-lang/packages.git"),
      regCommit, mirror = mirrorDir), "s.toml")
    let work = createTempDir("npc-m10-retired-", "")
    let t0 = uint64(daysAgo(10))
    let indexSources = @[("nimble-sources.toml",
      nimble_m7_fixtures.sourceSetText(@[mirrorDir]))]

    let g1 = generate(f.genConfig(ss, t0, work / "state",
      outputDir = work / "g1"))
    checkpoint g1.diagnostics.join("\n")
    let snap = g1.built.envelopeOf("untagged").versions
    check snap.len == 1
    check snap[0].version.kind == rvkSnapshot
    let s1 = snapshotVersionText(snap[0].version, c1)
    discard w.publish(@[g1.built.envelopeOf("untagged")], int64(t0), "g1",
      extraFiles = indexSources)

    let dir = w.writeCliProject("app", @[("untagged", "")],
      "import untagged\nwriteFile(\"build/app-out.txt\", untagged())\n")
    let env = cliEnv(w, f)
    let locked = runRepro(env, dir, @["lock", "refresh", dir, "--inputs",
      dir / "repro.solver", "--provisioning"])
    checkpoint locked.output
    check locked.rc == 0
    let row = nimbleRows(dir)["nimble:untagged"]
    check row.version == s1
    check row.coordinates.revision == c1

    # The origin adopts versioning: v0.1.0 at a new commit.
    let c2 = repo.commit(@[nimbleFile("untagged"),
      file("src/untagged.nim", "proc untagged*(): string = \"TAGGED-M10\"\n")])
    repo.tag("v0.1.0")
    repo.publish()
    let g2 = generate(f.genConfig(ss, t0 + Day, work / "state",
      previous = work / "g1", outputDir = work / "g2"))
    checkpoint g2.diagnostics.join("\n")
    let p2 = w.publish(@[g2.built.envelopeOf("untagged")], int64(t0 + Day),
      "g2", events = g2.events, extraFiles = indexSources)

    # The lock pinned to the new revision, its row unchanged.
    let oldPin = indexPin(dir)
    var text = readFile(dir / "repro.lock")
    check oldPin.revision in text and oldPin.interfaceArtifact in text
    text = text.replace(oldPin.revision, p2.commit)
    text = text.replace(oldPin.interfaceArtifact, $p2.built.rootId)
    writeFile(dir / "repro.lock", text)
    check indexPin(dir).revision == p2.commit
    check nimbleRows(dir)["nimble:untagged"].version == s1
    let pinnedLock = work / "pinned.lock"
    copyFile(dir / "repro.lock", pinnedLock)

    # The origin is gone; the store is empty; the mirror has the tree.
    f.deleteServed("nim/untagged.git")
    check not dirExists(entryPath(w.storeRootOf(), row.integrity["blake3:".len .. ^1]))
    let built = runRepro(env, dir, BuildArgs)
    checkpoint built.output
    check built.rc == 0
    check readFile(dir / "build" / "app-out.txt") == "SNAPSHOT-M10"

    # A refresh moves the row to the tag version, and says why.
    let refreshed = runRepro(env, dir, @["lock", "refresh", dir, "--inputs",
      dir / "repro.solver", "--provisioning"])
    checkpoint refreshed.output
    check refreshed.rc == 0
    let now = nimbleRows(dir)["nimble:untagged"]
    check now.version == "0.1.0"
    check now.coordinates.revision == c2
    check ("nimble:untagged " & s1 & " -> 0.1.0 (snapshot retired)") in
      refreshed.output
    let diff = lockDiff(pinnedLock, dir / "repro.lock")
    checkpoint diff.output
    check (s1 & " -> 0.1.0 (snapshot retired)") in diff.output

    # A fresh solve over the new revision: the snapshot is retired.
    var idx = openIndex(memorySource(p2.built.objectTable()), p2.built.rootId)
    let input = solverInput(idx, @["untagged"],
      nimblePlatformOf("amd64-linux"))
    let pi = input.packageOf("untagged")
    check pi >= 0
    var retired = 0
    for c in input.packages[pi].candidates:
      if c.version == s1:
        check c.exclusions.len == 1
        check c.exclusions[0].kind == exSnapshotRetired
        check "v0.1.0" in c.exclusions[0].detail
        inc retired
      elif c.version == "0.1.0":
        check c.offered
    check retired == 1
