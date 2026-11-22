## NPC-M13 verification `test_npc_m13_client_git_fallback_composes_submodules`
## (spec § 6.1, "Client fetch"; threat model T37).
##
## No mirror holds the object. A lock of the fixture version (nested
## submodules, one through a relative URL) is fetched by the git transport
## alone: the forge serves commit archives (which, as a real forge's do,
## leave submodule directories empty), but for a record that lists
## submodules the forge-archive transport is not attempted. The git
## transport fetches the superproject commit, reads its `.gitmodules`,
## fetches each submodule commit, composes, and installs a tree equal to the
## lock's digest; the store holds no `.git`.
##
## Positive control: the same row without the record's `submodules` flag (a
## hand-made row) does try the forge archive, whose tree lacks the
## submodules and is refused as a mismatch, and then installs from git.
##
## Falsifying mutation: fetching the superproject commit only installs
## nothing (digest mismatch).

import std/[options, os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index

import ./fetch_fixtures
import ../../repro_nimble_generator/tests/submodule_fixtures

suite "NPC-M13: the client's git fallback composes submodules":
  test "no mirror: git alone, no forge archive, the composed tree installed":
    let f = newFixture("m13-client-git", @[Route(prefix: "/",
      forgeArchives: true)])
    let work = createTempDir("npc-m13-client-git-", "")
    let (_, innerCommit) = f.served("nim/inner.git",
      @[file("inner.h", "int inner;\n")])
    let (_, subCommit) = f.served("nim/sub.git", @[file("sub.c",
      "int sub;\n"), gitmodules(@[("deep", "../inner.git")]),
      gitlinkTo("deep", innerCommit)])
    discard f.served("nim/withsub.git", @[nimbleFile("withsub"),
      file("src/withsub.nim", "discard\n"),
      gitmodules(@[("vendor/sub", "../sub.git")]),
      gitlinkTo("vendor/sub", subCommit)], tags = @["v1.0.0"])
    let reg = f.registryOf(@[("withsub", f.url("nim/withsub.git"))])
    let g = f.generation(reg, 1_790_000_000, work / "state")
    let rec = g.built.recordOf("withsub", "v1.0.0")
    require rec.isSome
    let r = rec.get
    check r.submodules.len == 2

    let before = f.requests().len
    let row = NimbleLockRow(name: "withsub", origin: f.url("nim/withsub.git"),
      commit: r.commit, tree: $r.tree,
      archiveSha256: toHexLower(r.archiveSha256), size: int64(r.size),
      submodules: r.submodules.len > 0)
    let fr = fetchLocked(@[row], f.fetchConfig(work / "client", @[]))
    check fr.ok
    require fr.packages.len == 1
    let p = fr.packages[0]
    checkpoint "attempts: " & $p.attempts
    check p.state == psFetched
    check p.transport == tGit
    for a in p.attempts:
      check a.transport != tForgeArchive
    check treeDigestOf(p.storePath) == $r.tree
    check readFile(p.storePath / "vendor/sub/deep/inner.h") == "int inner;\n"
    check readFile(p.storePath / "vendor/sub/sub.c") == "int sub;\n"
    check not hasGitDir(p.storePath)
    for line in f.requests()[before .. ^1]:
      check "/archive/" notin line

    # Positive control: a hand-made row (no record consulted) tries the
    # forge archive, which lacks the submodule trees, then git.
    var hand = row
    hand.submodules = false
    hand.archiveSha256 = ""
    hand.size = -1
    let fr2 = fetchLocked(@[hand], f.fetchConfig(work / "client-hand", @[]))
    check fr2.ok
    require fr2.packages.len == 1
    let p2 = fr2.packages[0]
    checkpoint "hand-made attempts: " & $p2.attempts
    require p2.attempts.len == 2
    check p2.attempts[0].transport == tForgeArchive
    check p2.attempts[0].outcome == aoMismatch
    check p2.attempts[1].transport == tGit
    check p2.attempts[1].outcome == aoFetched
    check treeDigestOf(p2.storePath) == $r.tree
