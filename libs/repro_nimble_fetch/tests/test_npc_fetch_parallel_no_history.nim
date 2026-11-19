## NPC-AREQ29 claim 2 and NPC-AREQ14: a cold fetch of a locked closure is
## one closure-index request plus one request per source object, in
## parallel, and writes no history.
##
## A mirror publishes the lock's closure index (lockfile-keyed, derived by
## `buildClosureIndex`) beside four source objects. A cold fetch of the lock
## asks the mirror exactly once for the closure index and exactly once for
## each object -- no probing, no HEAD, no git -- and the store and the
## project's state hold no `.git` directory. A closure index that is not
## anchored by the lock (one digest differs) is rejected, and the fetch
## falls back to the lock's own rows and still succeeds.
##
## "In parallel" is observed, not inferred: the mirror is a concurrent
## HTTPS server (`newConcurrentMirror`) that holds every object answer until
## all four object requests are in flight together, and records the most it
## held at once. A fetch that downloads one object at a time shows 1 (and
## waits out the hold for each object); this one must show 4.
##
## No mock: a real directory served as an HTTPS mirror, the production fetch
## edges run by the build engine.

import std/[os, strutils, tables, tempfiles, unittest]

import ./fetch_fixtures

suite "NPC-M5: a cold fetch is one closure-index request plus one per object":
  test "one request for the index, one per object, in parallel, no history":
    let mirrorDir = createTempDir("npc-m5-closure-mirror-", "")
    let f = newFixture("closure-index")
    let server = f.newConcurrentMirror(mirrorDir, holdFor = 4, holdMs = 5000)
    let work = createTempDir("npc-m5-closure-", "")
    var rows: seq[NimbleLockRow]
    var sizes = initTable[string, int64]()
    let local = parseMirror(mirrorDir)
    for name in ["alpha", "beta", "gamma", "delta"]:
      let s = f.package("owner/" & name & ".git", @[nimbleFile(name),
        file("src/" & name & ".nim", "# " & name & "\n")])
      local.putSource(s)
      rows.add f.rowOf(name, s)
      sizes[s.tree] = int64(s.archive.len)
    let served = server.mirrorOn()
    let ci = buildClosureIndex(rows, sizes, @[served], 1_790_000_000)
    let key = lockClosureKey(rows)
    local.putObject(closureIndexPath(key), encodeClosureIndex(ci))

    let r = fetchLocked(rows, f.fetchConfig(work / "cold", @[served]))
    check r.ok
    check r.closure.state == csAnchored
    let made = server.requests()
    checkpoint made.join("\n")
    check made.len == 1 + rows.len
    var indexHits, objectHits = 0
    for l in made:
      check l.startsWith("GET /mirror/")
      if l == "GET /mirror/" & closureIndexPath(key): inc indexHits
      if "/mirror/nimble/sources/" in l: inc objectHits
    check indexHits == 1
    check objectHits == rows.len
    # The four object downloads overlapped: all four were in flight at once.
    check server.maxInFlight() == rows.len
    # Each edge still decided its own row, in the lock's order.
    check r.packages.len == rows.len
    for i, p in r.packages:
      check p.row.name == rows[i].name
      check p.state == psFetched
      check p.transport == tMirror
      check treeDigestOf(p.storePath) == p.row.tree
    check not hasGitDir(work / "cold")

  test "an unanchored closure index is rejected and the rows are used":
    let mirrorDir = createTempDir("npc-m5-closure-forged-", "")
    let f = newFixture("closure-forged",
      @[Route(prefix: "/mirror/", serveDir: mirrorDir)])
    let work = createTempDir("npc-m5-closure-forged-work-", "")
    var rows: seq[NimbleLockRow]
    var sizes = initTable[string, int64]()
    let local = parseMirror(mirrorDir)
    for name in ["alpha", "beta"]:
      let s = f.package("owner/" & name & ".git", @[nimbleFile(name),
        file("src/" & name & ".nim", "# " & name & "\n")])
      local.putSource(s)
      rows.add f.rowOf(name, s)
      sizes[s.tree] = int64(s.archive.len)
    let served = f.httpsMirror("/mirror/")
    var ci = buildClosureIndex(rows, sizes, @[served], 1_790_000_000)
    ci.rows[1].tree = rows[0].tree # beta's digest replaced by alpha's
    local.putObject(closureIndexPath(lockClosureKey(rows)),
      encodeClosureIndex(ci))
    let r = fetchLocked(rows, f.fetchConfig(work, @[served]))
    check r.closure.state == csRejected
    checkpoint r.closure.detail
    check "beta" in r.closure.detail
    check r.ok
    for p in r.packages:
      check p.state == psFetched
      check treeDigestOf(p.storePath) == p.row.tree
