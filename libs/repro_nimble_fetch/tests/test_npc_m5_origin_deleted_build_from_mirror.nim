## Threat model G13 (NPC-AREQ13): a locked build never fails only because
## the origin is gone while a mirror holds the digest.
##
## The generator indexes three packages and publishes their canonical
## archives to an HTTPS mirror (the publish step refuses unless they are
## there). The lock is written from the index's records. Then every origin
## is made unreachable: its repositories are deleted from the forge, and
## its name no longer resolves. The lock's fetch edges fetch every source
## from the mirror, verify it and install it; the forge sees no request.
##
## No mock: real repositories and a real index generation over the shared
## HTTPS fixture, a real mirror directory served over HTTPS, the production
## fetch edges run by the build engine.

import std/[net, os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_index

import ./fetch_fixtures

suite "NPC-M5: a locked build fetches every source from a mirror":
  test "with the origin made unreachable, every source comes from the mirror":
    let mirrorDir = createTempDir("npc-m5-mirror-", "")
    let f = newFixture("origin-deleted",
      @[Route(prefix: "/mirror/", serveDir: mirrorDir)])
    let work = createTempDir("npc-m5-origin-deleted-", "")
    var entries: seq[(string, string)]
    for name in ["alpha", "beta", "gamma"]:
      discard f.package("owner/" & name & ".git", @[
        nimbleFile(name), file("src/" & name & ".nim", "# " & name & "\n")])
      entries.add (name, f.url("owner/" & name & ".git"))
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = commit(reg, @[packagesJson(entries)])
    publish(reg)
    let ss = parseSourceSet(sourceSetText(f.url("nim-lang/packages.git"),
      regCommit, mirror = mirrorDir), "s.toml")
    var cfg = f.genConfig(ss, 1_790_000_000, work / "gen-state",
      outputDir = work / "index")
    let g = generate(cfg)
    # The lock: one row per package, from the index's records.
    var rows: seq[NimbleLockRow]
    var idx = openIndex(memorySource(g.built.objectTable()), g.built.rootId)
    for name in ["alpha", "beta", "gamma"]:
      let l = idx.lookupPackage(name)
      check l.found
      let v = l.package.versions[0]
      let origin = l.package.origins[v.origin]
      rows.add NimbleLockRow(name: name, origin: origin.url, commit: v.commit,
        tree: $v.tree, archiveSha256: $v.archiveSha256, size: int64(v.size))
    check rows.len == 3
    # Positive control: while the origins exist, they are reachable.
    let s = f.sourceOf("owner/alpha.git", rows[0].commit)
    check s.tree == rows[0].tree

    # The origins disappear.
    for name in ["alpha", "beta", "gamma"]:
      f.deleteServed("owner/" & name & ".git")
    let before = f.requests().len
    var fc = f.fetchConfig(work / "project", @[f.httpsMirror("/mirror/")])
    fc.originPolicy.resolver = proc(host: string): seq[IpAddress] {.gcsafe.} =
      @[]  # the origin's name no longer resolves
    var attempted: seq[string]
    fc.observer = proc(t: Transport; url: string) {.gcsafe.} =
      {.cast(gcsafe).}: attempted.add $t & " " & url
    let r = fetchLocked(rows, fc)
    checkpoint attempted.join("\n")
    check r.ok
    check r.packages.len == 3
    for p in r.packages:
      check p.state == psFetched
      check p.transport == tMirror
      check treeDigestOf(p.storePath) == p.row.tree
      check fileExists(p.storePath / "src" / p.row.name & ".nim")
    for a in attempted:
      check a.startsWith("mirror ")
    # Nothing reached the forge's origins: only the mirror was asked.
    for l in f.requests()[before .. ^1]:
      check l.startsWith("GET /mirror/")
    check not hasGitDir(work / "project")
