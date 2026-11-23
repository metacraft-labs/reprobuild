## NPC-M10 verification `test_npc_m10_mirror_cannot_choose_digest` (threat
## model G10; NPC-AREQ12, NPC-AREQ14).
##
## A hostile mirror serves an internally consistent picture of other
## content than the lock pins: a closure index keyed by the lock's closure
## key whose row names the substitute's tree digest and size, the
## substitute's canonical archive at that digest's path, and the same
## archive at the path of the digest the lock pins. Nothing it serves is
## malformed; it only chose the digest.
##
## A client holding the lock refuses it: the closure index is rejected
## because its digest is not the lock's, and the object at the lock's path
## is refused because its bytes are not the lock's tree (by `archive_sha256`
## before extraction when the row carries it, by the tree digest after
## extraction when it does not). The store holds neither tree. The origin
## is unreachable, so no other transport hides the outcome.
##
## Positive control: an honest mirror with the closure index the lock's own
## rows give, and the true object, is anchored and used.
##
## Falsifying mutation (recorded in the plan): taking the expected digest
## from the mirror's closure index accepts it, and fails the test.

import std/[os, strutils, tables, tempfiles, unittest]

import ./fetch_fixtures

suite "NPC-M10: a mirror cannot choose the digest":

  test "a self-consistent substitute index and tree is refused by the lock":
    let f = newFixture("m10-mirror-digest")
    let real = f.package("owner/real.git", @[nimbleFile("real"),
      file("src/real.nim", "proc answer*(): int = 42\n")])
    let evil = f.package("owner/evil.git", @[nimbleFile("real"),
      file("src/real.nim", "proc answer*(): int = 666\n")])
    check real.tree != evil.tree

    for withArchive in [true, false]:
      let work = createTempDir("npc-m10-mirror-digest-", "")
      let m = parseMirror(work / "mirror")
      let row = f.rowOf("real", real, withArchive)
      # The mirror's own consistent picture: the closure index names the
      # substitute's digest, and both paths hold the substitute's bytes.
      var forged = buildClosureIndex(@[row],
        {evil.tree: int64(evil.archive.len)}.toTable, @[m], 1_790_000_000)
      forged.rows[0].tree = evil.tree
      forged.rows[0].urls = @[m.urlOf(sourceObjectPath(evil.tree))]
      m.putObject(closureIndexPath(lockClosureKey(@[row])),
        encodeClosureIndex(forged))
      m.putObject(sourceObjectPath(evil.tree), evil.archive)
      m.putObject(sourceObjectPath(real.tree), evil.archive)

      let r = fetchLocked(@[row], f.fetchConfig(work, @[m]).withNoOrigin())
      checkpoint $r.closure
      check r.closure.state == csRejected
      check evil.tree in r.closure.detail
      check real.tree in r.closure.detail
      check not r.ok
      check r.packages.len == 1
      let p = r.packages[0]
      check p.state == psFailed
      var mirrorAttempts = 0
      for a in p.attempts:
        checkpoint $a
        if a.transport == tMirror:
          inc mirrorAttempts
          check a.outcome == aoMismatch
          if withArchive:
            check a.rule == "archive_sha256"
            check a.observed == evil.archiveSha256
          else:
            check a.observed == evil.tree
      check mirrorAttempts == 1
      check not dirExists(work / "store" / real.tree)
      check not dirExists(work / "store" / evil.tree)
      check stagingLeft(work / "store").len == 0

    # Positive control: the honest mirror's index is anchored and used.
    let work = createTempDir("npc-m10-mirror-honest-", "")
    let good = parseMirror(work / "mirror")
    let row = f.rowOf("real", real)
    good.putSource(real)
    good.putObject(closureIndexPath(lockClosureKey(@[row])),
      encodeClosureIndex(buildClosureIndex(@[row],
        {real.tree: int64(real.archive.len)}.toTable, @[good],
        1_790_000_000)))
    let ok = fetchLocked(@[row], f.fetchConfig(work, @[good]).withNoOrigin())
    check ok.closure.state == csAnchored
    check ok.ok
    check ok.packages[0].transport == tMirror
    check dirExists(work / "store" / real.tree)
