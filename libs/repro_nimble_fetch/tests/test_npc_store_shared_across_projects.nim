## NPC-AREQ29 claim 4: a second project on the same host that locks a
## package already in the store fetches nothing for it.
##
## Project A fetches two packages from an HTTPS mirror into the user's store.
## Project B -- its own directory, state and engine cache -- locks one of
## them and a third: it asks the mirror for the third only, and finds the
## shared one in the store, verified by re-hashing it. A project with a
## different store root fetches again (positive control: the saving comes
## from the shared store, not from anything else).
##
## No mock: a real directory served as an HTTPS mirror by the shared
## fixture, the production fetch edges run by the build engine.

import std/[os, strutils, tempfiles, unittest]

import ./fetch_fixtures

suite "NPC-M5: the source store is shared across projects":
  test "a second project fetches nothing for a package already in the store":
    let mirrorDir = createTempDir("npc-m5-shared-mirror-", "")
    let f = newFixture("shared-store",
      @[Route(prefix: "/mirror/", serveDir: mirrorDir)])
    let work = createTempDir("npc-m5-shared-", "")
    let local = parseMirror(mirrorDir)
    var src: seq[PublishedSource]
    for name in ["alpha", "beta", "gamma"]:
      let s = f.package("owner/" & name & ".git", @[nimbleFile(name),
        file("src/" & name & ".nim", "# " & name & "\n")])
      local.putSource(s)
      src.add s
    let served = f.httpsMirror("/mirror/")
    let store = work / "user-store"
    var cfgA = f.fetchConfig(work / "project-a", @[served], store = store)
    cfgA.useClosureIndex = false
    let a = fetchLocked(@[f.rowOf("alpha", src[0]), f.rowOf("beta", src[1])],
      cfgA)
    check a.ok

    let before = f.requests().len
    var cfgB = f.fetchConfig(work / "project-b", @[served], store = store)
    cfgB.useClosureIndex = false
    let b = fetchLocked(@[f.rowOf("beta", src[1]), f.rowOf("gamma", src[2])],
      cfgB)
    check b.ok
    let made = f.requests()[before .. ^1]
    checkpoint made.join("\n")
    check made.len == 1
    check src[2].tree in made[0]
    for p in b.packages:
      if p.row.name == "beta":
        check p.state == psPresent
        check p.transport == tStore
      else:
        check p.state == psFetched

    # Positive control: another store fetches the shared package again.
    let before2 = f.requests().len
    var cfgC = f.fetchConfig(work / "project-c", @[served],
      store = work / "other-store")
    cfgC.useClosureIndex = false
    let c = fetchLocked(@[f.rowOf("beta", src[1])], cfgC)
    check c.ok
    check f.requests().len == before2 + 1
