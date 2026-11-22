## NPC-M13 verification `test_npc_m13_closure_index_one_row_per_package`
## (spec § 6.1, "Mirrors and the closure index"; NPC-AREQ14).
##
## A lock holds the fixture version with a submodule and a plain package.
## The closure index a mirror serves for it has one row per `nimble:` row,
## each with the source object's digest and size (for the fixture version
## the COMPOSED object: the record's `tree` and `size`), and no row for the
## submodule; a fetch anchors it and installs both from the mirror. The lock
## row is unchanged by submodules: it records name, origin, commit and tree,
## no submodule URL, and the Nimble closure key computed from the lock's
## rows is the key the index is filed under.

import std/[options, os, strutils, tables, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_lock

import ./fetch_fixtures
import ../../repro_nimble_generator/tests/submodule_fixtures

suite "NPC-M13: the closure index has one row per package":
  test "a lock with a submodule version: one row per nimble: row, the composed object, no submodule row":
    let mirrorDir = createTempDir("npc-m13-closure-mirror-", "")
    let f = newFixture("m13-closure")
    let work = createTempDir("npc-m13-closure-", "")
    let (_, subCommit) = f.served("nim/sub.git", @[file("sub.c", "int s;\n")])
    discard f.served("nim/withsub.git", @[nimbleFile("withsub"),
      file("src/withsub.nim", "discard\n"),
      gitmodules(@[("vendor/sub", "../sub.git")]),
      gitlinkTo("vendor/sub", subCommit)], tags = @["v1.0.0"])
    discard f.served("nim/plain.git", @[nimbleFile("plain"),
      file("src/plain.nim", "discard\n")], tags = @["v1.0.0"])
    let reg = f.registryOf(@[("withsub", f.url("nim/withsub.git")),
      ("plain", f.url("nim/plain.git"))])
    let g = f.generation(reg, 1_790_000_000, work / "state",
      outputDir = work / "index", mirror = mirrorDir)
    var rows: seq[NimbleLockRow]
    var sizes = initTable[string, int64]()
    for name in ["plain", "withsub"]:
      let r = g.built.recordOf(name, "v1.0.0")
      require r.isSome
      rows.add NimbleLockRow(name: name, origin: f.url("nim/" & name & ".git"),
        commit: r.get.commit, tree: $r.get.tree,
        archiveSha256: toHexLower(r.get.archiveSha256),
        size: int64(r.get.size), submodules: r.get.submodules.len > 0)
      sizes[$r.get.tree] = int64(r.get.size)
    let withsub = g.built.recordOf("withsub", "v1.0.0").get
    check withsub.submodules.len == 1

    # The lock rows as a lock records them: no submodule URL anywhere.
    var deps: seq[LockedDep]
    for r in rows: deps.add lockedDepOf(r)
    for d in deps:
      check "/nim/sub.git" notin d.coordinates.url
      check d.coordinates.url == f.url("nim/" & d.name["nimble:".len .. ^1] &
        ".git")
      check d.integrity == "blake3:" & (if d.name == "nimble:withsub":
        $withsub.tree else: $g.built.recordOf("plain", "v1.0.0").get.tree)
    let reread = nimbleRowsOf(LockedDependencies(deps: deps))
    check reread.len == 2
    let key = lockClosureKey(rows)
    check lockClosureKey(reread) == key

    # The closure index: one row per nimble: row, the composed object.
    let local = parseMirror(mirrorDir)
    let ci = buildClosureIndex(rows, sizes, @[local], 1_790_000_000)
    check ci.key == key
    check ci.rows.len == rows.len
    var names: seq[string]
    for cr in ci.rows:
      names.add cr.name
      if cr.name == "withsub":
        check cr.tree == $withsub.tree
        check cr.size == int64(withsub.size)
        check cr.size == int64(getFileSize(mirrorDir /
          sourceObjectPath($withsub.tree)))
    check names == @["plain", "withsub"]
    local.putObject(closureIndexPath(key), encodeClosureIndex(ci))
    # The mirror holds one object per version and none for the submodule.
    var objects = 0
    for p in walkDirRec(mirrorDir / "nimble" / "sources"): inc objects
    check objects == 2

    let fr = fetchLocked(rows, f.fetchConfig(work / "client",
      @[local]).withNoOrigin())
    checkpoint "closure: " & $fr.closure.state & " " & fr.closure.detail
    check fr.ok
    check fr.closure.state == csAnchored
    check fr.closure.index.rows.len == 2
    for p in fr.packages:
      check p.state == psFetched
      check p.transport == tMirror
