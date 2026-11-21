## NPC-M6 verification `test_npc_m6_pin_survives_repoint` (NPC-AREQ16,
## threat model G7): a lock written before a name was repointed keeps its
## source. After the index records the repoint -- the registry now names a
## fork, whose records are a separate candidate under the same name -- a
## refreshed solve still takes the package from the origin the lock
## records (even though the fork offers a higher version), the committed
## lock's row is unchanged, a build's preparation accepts it against the
## new pin and fetches the OLD source from the mirror, and `repro lock diff`
## against the refreshed lock shows the `repointed` event.
##
## Falsifying mutation (recorded in the plan): taking the fork's records as
## candidates of the name (no `repointed-origin` exclusion in
## ``candidatesOf``) makes the refreshed solve pick the new origin, and the
## test fails.
##
## No mock: a real index repository and shared clone, the production verbs,
## the production fetch edges and the shared HTTPS fixture as the mirror.

import std/[options, os, strutils, tables, unittest]

import ./nimble_m6_fixtures
import ../../repro_nimble_fetch/tests/fetch_fixtures

const Fork = "https://example.invalid/fork/widget"

proc hexBytes(hex: string): seq[byte] =
  for i in countup(0, hex.len - 2, 2):
    result.add byte(parseHexInt(hex[i .. i + 1]))

suite "NPC-M6: a pin survives a repoint":
  test "the old source stays locked, and the diff shows the event":
    var w = newWorld("repoint")
    let mirrorDir = w.root / "mirror"
    createDir(mirrorDir)
    let f = newFixture("m6-repoint",
      @[Route(prefix: "/mirror/", serveDir: mirrorDir)])
    let src = f.package("nim/widget.git", @[nimbleFile("widget"),
      file("src/widget.nim", "proc widget*() = discard\n")])
    parseMirror(mirrorDir).putSource(src)
    let upstream = f.url(src.path)
    var v1 = record("widget", "1.0.0")
    v1.commit = src.commit
    let t = hexBytes(src.tree)
    for i in 0 ..< 32: v1.tree[i] = t[i]
    let a = hexBytes(src.archiveSha256)
    for i in 0 ..< 32: v1.archiveSha256[i] = a[i]
    v1.size = uint64(src.archive.len)
    var env1 = package("widget", @[v1])
    env1.origins = @[PackageOrigin(url: upstream, vcs: ovGit)]
    discard w.publish(@[env1], daysAgo(20), "generation 1")
    let dir = w.newProject(@[("widget", "")])
    let first = refreshProvisioning(dir)
    checkpoint first.output
    check first.rc == 0
    let row = nimbleRows(dir)["nimble:widget"]
    check row.coordinates.url == upstream
    check row.coordinates.revision == v1.commit
    check row.catalog == IndexRepo
    let before = dir / "before.lock"
    copyFile(dir / "repro.lock", before)

    # Generation 2: the registry repoints `widget` to the fork. The old
    # record keeps its origin (0); the fork's versions are records of the
    # new origin (1), which the registry now names.
    var forkV2 = record("widget", "2.0.0")
    forkV2.origin = 1
    var env2 = package("widget", @[v1, forkV2])
    env2.origins = @[PackageOrigin(url: upstream, vcs: ovGit),
      PackageOrigin(url: Fork, vcs: ovGit)]
    env2.registryOrigin = 1
    let at2 = daysAgo(1)
    let g2 = w.publish(@[env2], at2, "generation 2", events = @[
      OriginEvent(kind: oeRepointed, package: "widget", before: upstream,
        after: Fork, observedAt: uint64(at2))])

    let again = refreshProvisioning(dir)
    checkpoint again.output
    check again.rc == 0
    check indexPin(dir).revision == g2.commit
    let kept = nimbleRows(dir)["nimble:widget"]
    check kept.coordinates.url == upstream
    check kept.coordinates.revision == v1.commit
    check kept.version == "1.0.0"
    check kept.integrity == row.integrity

    # A build's preparation anchors the row to a record of the NEW pin and
    # fetches the OLD source, by its locked digest, from the mirror.
    let store = w.root / "store"
    var cfg = f.fetchConfig(w.root / "fetch", @[f.httpsMirror("/mirror/")],
      store = store)
    cfg.useClosureIndex = false
    var prep: NimbleSourcesReport
    var refusal = ""
    try:
      prep = prepareLockedNimbleSources(dir, dir / "repro.lock",
        NimbleSourcesOptions(fetchConfig: some(cfg)))
    except CatchableError as e:
      refusal = e.msg
    checkpoint refusal
    check refusal.len == 0
    check prep.fetched == @["widget"]
    check entryVerified(store, src.tree)
    check prep.storePaths["widget"] == entryPath(store, src.tree)

    let diff = lockDiff(before, dir / "repro.lock")
    checkpoint diff.output
    check "origin events since " in diff.output
    check "repointed nimble:widget: " & upstream & " -> " & Fork in diff.output
    check "nimble:widget: version" notin diff.output
