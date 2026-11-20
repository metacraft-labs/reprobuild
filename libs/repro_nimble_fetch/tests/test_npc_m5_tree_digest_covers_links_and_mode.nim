## NPC-M5 deliverable (from NPC-M4's review): what a lock pins covers a
## source tree's symbolic links and executable bits, as the canonical
## archive does.
##
## Three tags of one fixture package differ only in a link's target (two
## in-tree files, same bytes in every tag) and in one script's mode. Each is
## a different tree digest -- in the generator's record and in the client's
## re-hash of what it extracted -- so a lock that pins one tag refuses the
## archive of another, served under the pinned digest by a mirror. A tree of
## plain, non-executable files still hashes exactly as the lock's plain
## `narStyleTreeMultihash` did, so no recorded digest of such a tree moves.
##
## No mock: real git repositories served over HTTPS by the shared fixture, a
## real directory mirror, the production fetch path.

import std/[os, tables, tempfiles, unittest]

import repro_multihash
import repro_nimble_fetch
import repro_nimble_generator

import ./fetch_fixtures

suite "NPC-M5: the tree digest covers links and the executable bit":
  test "a retargeted link or a flipped mode is another tree, and a lock refuses it":
    let f = newFixture("tree-digest")
    let work = createTempDir("npc-m5-tree-digest-", "")
    let repo = f.newRepo("owner/pkg.git")
    let base = @[file("pkg.nimble", "version = \"1.0.0\"\n"),
                 file("src/safe.nim", "proc f*(): int = 1\n"),
                 file("src/other.nim", "proc f*(): int = 2\n")]
    let c1 = commit(repo, base & @[symlink("src/pkg.nim", "safe.nim"),
                                   file("run.sh", "#!/bin/sh\necho ok\n")])
    discard git(repo, "update-index", "--chmod=+x", "run.sh")
    discard gitAt(1_700_000_001, repo, "commit", "-q", "--amend", "-m", "v1")
    let v1 = git(repo, "rev-parse", "HEAD")
    discard c1
    tag(repo, "v1")
    # v2: the link names the other in-tree module; every file's bytes equal.
    discard git(repo, "rm", "-q", "--cached", "src/pkg.nim")
    removeFile(repo / "src/pkg.nim")
    createSymlink("other.nim", repo / "src/pkg.nim")
    discard git(repo, "add", "src/pkg.nim")
    discard gitAt(1_700_000_002, repo, "commit", "-q", "-m", "v2")
    let v2 = git(repo, "rev-parse", "HEAD")
    tag(repo, "v2")
    # v3: v1's link, run.sh no longer executable.
    discard git(repo, "rm", "-q", "--cached", "src/pkg.nim")
    removeFile(repo / "src/pkg.nim")
    createSymlink("safe.nim", repo / "src/pkg.nim")
    discard git(repo, "add", "src/pkg.nim")
    discard git(repo, "update-index", "--chmod=-x", "run.sh")
    discard gitAt(1_700_000_003, repo, "commit", "-q", "-m", "v3")
    let v3 = git(repo, "rev-parse", "HEAD")
    tag(repo, "v3")
    publish(repo)

    let s1 = f.sourceOf("owner/pkg.git", v1)
    let s2 = f.sourceOf("owner/pkg.git", v2)
    let s3 = f.sourceOf("owner/pkg.git", v3)
    # Positive control: the three trees hold the same regular-file bytes.
    let g = OriginGit(gitBin: f.gitBin)
    proc regularFiles(c: string): seq[(string, string)] =
      let t = readTree(g, f.root / "owner/pkg.git", c, "", DefaultLimits)
      for e in t.entries:
        if e.kind in {teFile, teExecutable}:
          result.add (e.path, t.blobs[e.oid])
    check regularFiles(v1) == regularFiles(v2)
    check regularFiles(v1) == regularFiles(v3)
    # The claim: three different digests.
    check s1.tree != s2.tree
    check s1.tree != s3.tree
    check s2.tree != s3.tree

    # The client reproduces each digest from what it extracts.
    let mirrorDir = work / "mirror"
    let m = parseMirror(mirrorDir)
    for s in [s1, s2, s3]:
      m.putSource(s)
    for (name, s) in [("p1", s1), ("p2", s2), ("p3", s3)]:
      let r = fetchLocked(@[f.rowOf(name, s, withArchive = false)],
        f.fetchConfig(work / name, @[m]))
      check r.ok
      check treeDigestOf(work / name / "store" / s.tree) == s.tree
      let st = work / name / "store" / s.tree
      check symlinkExists(st / "src/pkg.nim")
      check (fpUserExec in getFilePermissions(st / "run.sh")) ==
        (s.tree != s3.tree)

    # A lock pinning v1 refuses v2's archive filed under v1's digest.
    let forged = parseMirror(work / "forged-mirror")
    forged.putObject(sourceObjectPath(s1.tree), s2.archive)
    let refused = fetchLocked(@[f.rowOf("pkg", s1, withArchive = false)],
      f.fetchConfig(work / "forged", @[forged]).withNoOrigin())
    check not refused.ok
    check refused.packages[0].attempts[0].outcome == aoMismatch
    check not dirExists(work / "forged" / "store" / s1.tree)
    check stagingLeft(work / "forged" / "store").len == 0

  test "a tree of plain files hashes as the lock's plain tree hash did":
    let plain = @[(path: "a.nim", content: "x"), (path: "src/b.nim", content: "y")]
    var typed: seq[CanonicalTreeEntry]
    for e in plain:
      typed.add CanonicalTreeEntry(path: e.path, kind: cekRegular,
        content: e.content)
    check canonicalTreeMultihash(typed) == narStyleTreeMultihash(plain)
    var exec = typed
    exec[0].kind = cekExecutable
    check canonicalTreeMultihash(exec) != narStyleTreeMultihash(plain)
