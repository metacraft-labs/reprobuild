## NPC-AREQ29 claim 3, NPC-M6 verification `test_npc_warm_build_zero_network`,
## and the plan's NPC-M6 item f end to end:
##
## 1. `repro lock refresh --provisioning` writes the `nimble-index`
##    `catalog_imports` record (a `v2` record with `kind`, the index identity
##    in `interface_artifact`) and the NPC-AREQ19 `LockedDep` rows beside it
##    (`nimble:<name>`, the origin and peeled commit, `blake3:<tree>`, the
##    version, the catalog it came from, its `depends`);
## 2. a build's preparation (`prepareLockedNimbleSources`, what `repro
##    build` runs before anything compiles) verifies the pin
##    (`catalogsForBuild`) and the rows against the pinned index's records,
##    and fetches the trees -- `nimble.fetch` edges, from an HTTPS mirror;
## 3. a WARM build from the committed lock with the network disabled
##    (`offline`, and every request the mirror receives logged) evaluates no
##    fetch edge and no index edge and makes no request: every tree is
##    verified in the store in place.
##
## Positive control: with one tree removed from the store, the same offline
## preparation refuses naming it -- so "no request" is not "nothing needed".
## Falsifying mutation (recorded in the plan): skipping the store check (so
## every row is fetched) makes the warm build evaluate fetch edges.
##
## No mock: real index and source repositories, the production verbs, the
## production fetch edges and the shared HTTPS fixture as the mirror.

import std/[options, os, strutils, tables, unittest]

import ./nimble_m6_fixtures
import ../../repro_nimble_fetch/tests/fetch_fixtures

proc hexBytes(hex: string): seq[byte] =
  for i in countup(0, hex.len - 2, 2):
    result.add byte(parseHexInt(hex[i .. i + 1]))

proc recordOf(f: Fixture; name: string; s: PublishedSource; tag: string;
              requires: seq[RequirementEntry] = @[]): VersionRecord =
  ## The index record of a served source, with its real digests.
  result = record(name, tag, requires)
  result.commit = s.commit
  let t = hexBytes(s.tree)
  for i in 0 ..< 32: result.tree[i] = t[i]
  let a = hexBytes(s.archiveSha256)
  for i in 0 ..< 32: result.archiveSha256[i] = a[i]
  result.size = uint64(s.archive.len)

suite "NPC-M6: lock, build preparation, and a warm build with no network":
  test "refresh writes the pin and rows; a warm build opens nothing":
    var w = newWorld("warm")
    let mirrorDir = w.root / "mirror"
    createDir(mirrorDir)
    let f = newFixture("m6-warm",
      @[Route(prefix: "/mirror/", serveDir: mirrorDir)])
    let local = parseMirror(mirrorDir)
    let alphaSrc = f.package("owner/alpha.git", @[nimbleFile("alpha"),
      file("src/alpha.nim", "proc alpha*() = discard\n")])
    let betaSrc = f.package("owner/beta.git", @[nimbleFile("beta"),
      file("src/beta.nim", "proc beta*() = discard\n")])
    local.putSource(alphaSrc)
    local.putSource(betaSrc)
    var alpha = package("alpha", @[f.recordOf("alpha", alphaSrc, "v1.0.0",
      @[req("beta", ">= 1.0.0")])])
    alpha.origins = @[PackageOrigin(url: f.url(alphaSrc.path), vcs: ovGit)]
    var beta = package("beta", @[f.recordOf("beta", betaSrc, "v1.0.0")])
    beta.origins = @[PackageOrigin(url: f.url(betaSrc.path), vcs: ovGit)]
    let gen = w.publish(@[alpha, beta], daysAgo(3), "generation 1")
    let dir = w.newProject(@[("alpha", ">= 1.0.0")])

    # 1. The refresh writes the v2 record and the rows.
    let refreshed = refreshProvisioning(dir)
    checkpoint refreshed.output
    check refreshed.rc == 0
    let text = readFile(dir / "repro.lock")
    check "record = \"reprobuild.locked-catalog-import.v2\"" in text
    check "kind = \"nimble-index\"" in text
    let pin = indexPin(dir)
    check pin.kind == cikNimbleIndex
    check pin.revision == gen.commit
    check pin.interfaceArtifact == $gen.built.rootId
    let rows = nimbleRows(dir)
    check rows.len == 2
    let a = rows["nimble:alpha"]
    check a.coordinates.kind == ckVcs
    check a.coordinates.url == f.url(alphaSrc.path)
    check a.coordinates.revision == alphaSrc.commit
    check a.integrity == "blake3:" & alphaSrc.tree
    check a.version == "1.0.0"
    check a.catalog == IndexRepo
    check a.depends == @["nimble:beta"]
    check rows["nimble:beta"].integrity == "blake3:" & betaSrc.tree
    check rows["nimble:beta"].depends.len == 0

    # 2. A cold build's preparation verifies and fetches both trees.
    let store = w.root / "store"
    var cfg = f.fetchConfig(w.root / "fetch", @[f.httpsMirror("/mirror/")],
      store = store)
    cfg.useClosureIndex = false
    let cold = prepareLockedNimbleSources(dir, dir / "repro.lock",
      NimbleSourcesOptions(fetchConfig: some(cfg)))
    check cold.active
    check cold.fetched.len == 2
    check cold.fetchEdges >= 2
    check cold.present.len == 0
    check f.requestsMatching(alphaSrc.tree) >= 1
    check entryVerified(store, alphaSrc.tree)
    check entryVerified(store, betaSrc.tree)

    # 3. A warm build, network disabled: no fetch edge, no request.
    let before = f.requests().len
    let warm = prepareLockedNimbleSources(dir, dir / "repro.lock",
      NimbleSourcesOptions(fetchConfig: some(cfg), offline: true))
    check warm.active
    check warm.present.len == 2
    check warm.fetched.len == 0
    check warm.fetchEdges == 0
    check f.requests().len == before
    check warm.storePaths["alpha"] == entryPath(store, alphaSrc.tree)
    check ("at " & gen.commit & ": generated ") in warm.indexLine

    # Positive control: a missing tree is refused offline, by name.
    removeDir(entryPath(store, betaSrc.tree))
    var refusal = ""
    try:
      discard prepareLockedNimbleSources(dir, dir / "repro.lock",
        NimbleSourcesOptions(fetchConfig: some(cfg), offline: true))
    except CatchableError as e:
      refusal = e.msg
    check "does not hold nimble:beta" in refusal
    check f.requests().len == before

  test "a row that is not a record of the pinned index is refused":
    var w = newWorld("warm-anchor")
    discard w.publish(@[package("alpha", @[record("alpha", "1.0.0")])],
      daysAgo(1), "generation 1")
    let dir = w.newProject(@[("alpha", "")])
    check refreshProvisioning(dir).rc == 0
    let lockText = readFile(dir / "repro.lock")
    let row = nimbleRows(dir)["nimble:alpha"]
    let forged = lockText.replace(row.coordinates.revision, repeat('e', 40))
    writeFile(dir / "repro.lock", forged)
    var refusal = ""
    try:
      discard prepareLockedNimbleSources(dir, dir / "repro.lock",
        NimbleSourcesOptions(offline: true, storeRoot: w.root / "store"))
    except CatchableError as e:
      refusal = e.msg
    check "is not a record of the Nimble index" in refusal
