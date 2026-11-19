## Threat model G10 (NPC-AREQ12, NPC-AREQ20): every transport is checked
## against the lock's tree digest, so wrong bytes are refused whichever way
## they arrive, and nothing unverified is ever in the store.
##
## * A mirror serves the canonical archive with one changed byte: refused
##   before extraction by `archive_sha256` when the index record is known,
##   and by the tree digest after extraction when it is not.
## * The forge serves a commit archive with one changed byte (the mirror is
##   empty, the origin's git answers 503 to object requests, so the forge
##   archive is the only candidate): refused by the tree digest.
## * Git serves a commit whose tree has one changed file relative to the
##   digest the lock pins: refused by the tree digest.
##
## In every case the package fails, the store holds no entry for the
## digest, and no staging directory is left.
##
## No mock: real repositories, a real forge archive endpoint and a real
## directory mirror over the shared HTTPS fixture; the production fetch.

import std/[os, strutils, tempfiles, unittest]

import ./fetch_fixtures

proc flipByteIn(data, needle: string): string =
  ## ``data`` with the first byte of ``needle``'s first occurrence changed.
  let at = data.find(needle)
  doAssert at >= 0, "needle not found"
  result = data
  result[at] = chr(ord(result[at]) xor 0x01)

suite "NPC-M5: wrong bytes are refused by any transport":
  let archiveDir = createTempDir("npc-m5-forged-archives-", "")
  let flag = createTempDir("npc-m5-flag-", "") / "fail-git"
  let f = newFixture("wrong-bytes", @[
    Route(prefix: "/owner/forged/archive/", serveDir: archiveDir),
    Route(prefix: "/owner/forged.git/", failFetchWhile: flag)])
  let s = f.package("owner/forged.git", @[nimbleFile("forged"),
    file("src/forged.nim", "proc answer*(): int = 42\n")])

  test "a mirror serving one changed byte is refused":
    let work = createTempDir("npc-m5-wrong-mirror-", "")
    let m = parseMirror(work / "mirror")
    m.putObject(sourceObjectPath(s.tree), flipByteIn(s.archive, "answer"))
    for withArchive in [true, false]:
      let w = work / $withArchive
      let r = fetchLocked(@[f.rowOf("forged", s, withArchive)],
        f.fetchConfig(w, @[m]).withNoOrigin())
      check not r.ok
      let a = r.packages[0].attempts[0]
      check a.transport == tMirror
      check a.outcome == aoMismatch
      if withArchive:
        check a.rule == "archive_sha256" # refused before it was parsed
      else:
        check "hashes to" in a.detail     # extracted, re-hashed, refused
      check not dirExists(w / "store" / s.tree)
      check stagingLeft(w / "store").len == 0
    # Positive control: the true archive from the same mirror is accepted.
    let good = parseMirror(work / "good-mirror")
    good.putSource(s)
    let ok = fetchLocked(@[f.rowOf("forged", s)],
      f.fetchConfig(work / "good", @[good]).withNoOrigin())
    check ok.ok
    check ok.packages[0].transport == tMirror

  test "a forge archive with one changed byte is refused":
    let work = createTempDir("npc-m5-wrong-forge-", "")
    let tarBytes = run(["git", "--git-dir=" & f.root / "owner/forged.git",
      "archive", "--format=tar", "--prefix=forged-" & s.commit & "/",
      s.commit])
    writeFile(archiveDir / s.commit & ".tar.gz",
      gzipOf(work, flipByteIn(tarBytes, "answer")))
    writeFile(flag, "")
    defer: removeFile(flag)
    let r = fetchLocked(@[f.rowOf("forged", s, withArchive = false)],
      f.fetchConfig(work, @[]))
    check not r.ok
    var forge, gitAttempt: FetchAttempt
    for a in r.packages[0].attempts:
      if a.transport == tForgeArchive: forge = a
      if a.transport == tGit: gitAttempt = a
    check forge.outcome == aoMismatch
    check "hashes to" in forge.detail
    check gitAttempt.outcome == aoFailed # the origin's git answered 503
    check not dirExists(work / "store" / s.tree)
    check stagingLeft(work / "store").len == 0
    # Positive control: the true archive from the same endpoint is accepted.
    writeFile(archiveDir / s.commit & ".tar.gz", gzipOf(work, tarBytes))
    let ok = fetchLocked(@[f.rowOf("forged", s, withArchive = false)],
      f.fetchConfig(work / "good", @[]))
    check ok.ok
    check ok.packages[0].transport == tForgeArchive

  test "a git commit with a changed file is refused":
    let work = createTempDir("npc-m5-wrong-git-", "")
    let repo = f.newRepo("owner/drift.git")
    let c1 = commit(repo, @[nimbleFile("drift"),
      file("src/drift.nim", "proc answer*(): int = 42\n")])
    let c2 = commit(repo, @[nimbleFile("drift"),
      file("src/drift.nim", "proc answer*(): int = 43\n")])
    publish(repo)
    let pinned = f.sourceOf("owner/drift.git", c1)
    # The lock pins c1's tree; the commit git is asked for is c2.
    var row = f.rowOf("drift", pinned, withArchive = false)
    row.commit = c2
    var cfg = f.fetchConfig(work, @[])
    cfg.forges = @[] # git is the only transport
    let r = fetchLocked(@[row], cfg)
    check not r.ok
    let a = r.packages[0].attempts[^1]
    check a.transport == tGit
    check a.outcome == aoMismatch
    check not dirExists(work / "store" / pinned.tree)
    check stagingLeft(work / "store").len == 0
    # Positive control: the commit the tree belongs to is accepted by git.
    row.commit = c1
    let ok = fetchLocked(@[row], f.fetchConfig(work / "good", @[]))
    check ok.ok
