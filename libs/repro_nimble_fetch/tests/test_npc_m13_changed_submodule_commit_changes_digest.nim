## NPC-M13 verification `test_npc_m13_changed_submodule_commit_changes_digest`
## (threat model G39, T37).
##
## Two tags of one package differ ONLY in the commit one gitlink pins; the
## two submodule commits differ in one file's content. The tags get
## different `tree` and `archive_sha256`, and a lock of the first refuses the
## second's object when a mirror serves it under the first's digest: with
## the index's `archive_sha256` (refused before extraction) and without it
## (refused by the tree digest after extraction).
##
## Falsifying mutation: hashing the superproject's entries only gives both
## tags the same `tree`.

import std/[options, os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index

import ./fetch_fixtures
import ../../repro_nimble_generator/tests/submodule_fixtures

suite "NPC-M13: the digest covers the submodule content":
  test "two tags differing only in a gitlink's commit: different digests; a swapped object is refused":
    let mirrorDir = createTempDir("npc-m13-digest-mirror-", "")
    let f = newFixture("m13-digest")
    let work = createTempDir("npc-m13-digest-", "")
    let sub = f.newRepo("nim/sub.git")
    let s1 = sub.commit(@[file("data.txt", "one\n")])
    let s2 = sub.commit(@[file("data.txt", "two\n")])
    sub.publish()
    let w = f.newRepo("nim/pinned.git")
    let gm = gitmodules(@[("vendor/sub", f.url("nim/sub.git"))])
    discard w.commit(@[nimbleFile("pinned"), file("src/pinned.nim",
      "discard\n"), gm, gitlinkTo("vendor/sub", s1)])
    w.tag("v1.0.0")
    discard w.commit(@[nimbleFile("pinned"), file("src/pinned.nim",
      "discard\n"), gm, gitlinkTo("vendor/sub", s2)])
    w.tag("v2.0.0")
    w.publish()
    let reg = f.registryOf(@[("pinned", f.url("nim/pinned.git"))])
    # The digests first, from a generation that publishes nothing: no
    # mirror write can refuse the two objects before they are compared.
    let g0 = f.generation(reg, 1_790_000_000, work / "state")
    checkpoint "diagnostics (unpublished): " & g0.diagnostics.join("\n")
    let u1 = g0.built.recordOf("pinned", "v1.0.0")
    let u2 = g0.built.recordOf("pinned", "v2.0.0")
    require u1.isSome and u2.isSome
    check u1.get.submodules[0].commit == s1
    check u2.get.submodules[0].commit == s2
    check u1.get.tree != u2.get.tree
    check u1.get.archiveSha256 != u2.get.archiveSha256

    # The same generation, published to a directory mirror.
    let g = f.generation(reg, 1_790_000_000, work / "state",
      outputDir = work / "index", mirror = mirrorDir)
    checkpoint "diagnostics: " & g.diagnostics.join("\n")
    let r1 = g.built.recordOf("pinned", "v1.0.0")
    let r2 = g.built.recordOf("pinned", "v2.0.0")
    require r1.isSome and r2.isSome
    check r1.get == u1.get
    check r2.get == u2.get

    # A mirror serving the second tag's object under the first's digest.
    let bad = createTempDir("npc-m13-digest-swapped-", "")
    let second = readFile(mirrorDir / sourceObjectPath($r2.get.tree))
    parseMirror(bad).putObject(sourceObjectPath($r1.get.tree), second)
    for withArchive in [true, false]:
      let row = NimbleLockRow(name: "pinned", origin: f.url("nim/pinned.git"),
        commit: r1.get.commit, tree: $r1.get.tree,
        archiveSha256: (if withArchive: toHexLower(r1.get.archiveSha256)
                        else: ""),
        size: (if withArchive: int64(r1.get.size) else: -1'i64),
        submodules: true)
      let fr = fetchLocked(@[row], f.fetchConfig(work / ("client-" &
        $withArchive), @[parseMirror(bad)]).withNoOrigin())
      check not fr.ok
      require fr.packages.len == 1
      let p = fr.packages[0]
      checkpoint "attempts (archive known: " & $withArchive & "): " &
        $p.attempts
      check p.state == psFailed
      check p.attempts.len >= 1
      check p.attempts[0].transport == tMirror
      check p.attempts[0].outcome == aoMismatch
      if withArchive:
        check p.attempts[0].rule == "archive_sha256"
      check not hasEntry(work / ("client-" & $withArchive) / "store",
        $r1.get.tree)
