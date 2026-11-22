## NPC-M7 verification `test_npc_m7_configured_mirror_tried_before_catalog`
## (operator ruling M5-P4; NPC-AREQ13, NPC-AREQ20).
##
## A lock whose source object is on both a configured mirror (`[nimble]
## mirrors` of the user's Reprobuild configuration, in a private root) and
## the catalog's mirror (`[[mirror]]` of the index repository's
## `nimble-sources.toml` at the pinned revision) -- two HTTPS test mirrors
## on one listener that logs every request -- is fetched from the
## configured one, and the catalog's receives no request. With the object
## removed from the configured mirror, the catalog's serves it; with it
## removed from both, the origin does (its forge archive). Each step starts
## from an empty store, and each installed tree is verified against the
## lock's digest.
##
## The build's own preparation (``prepareLockedNimbleSources``) builds the
## order; the test supplies only how the mirrors are reached (its resolver
## and trust anchor, ``fetchTemplate``) and where the configuration files
## are (``mirrorConfig``).
##
## Falsifying mutation (recorded in the plan): appending the configured
## mirrors after the catalog's sends the first request to the catalog's
## mirror and fails the test.

import std/[os, strutils, unittest]

import ./nimble_m7_fixtures

suite "NPC-M7: configured mirrors come before the catalog's":
  test "configured, then catalog, then origin":
    var w = newWorld("m7-order")
    let configuredDir = w.root / "configured"
    let catalogDir = w.root / "catalog"
    createDir(configuredDir)
    createDir(catalogDir)
    let f = newFixture("m7-order", @[
      Route(prefix: "/configured/", serveDir: configuredDir),
      Route(prefix: "/catalog/", serveDir: catalogDir)])
    let src = f.package("owner/alpha.git", @[nimbleFile("alpha"),
      file("src/alpha.nim", "proc alpha*() = discard\n")])
    parseMirror(configuredDir).putSource(src)
    parseMirror(catalogDir).putSource(src)
    let catalogUrl = f.httpsMirror("/catalog/").location
    let configuredUrl = f.httpsMirror("/configured/").location
    discard w.publish(@[f.envelope("alpha",
      @[f.recordOf("alpha", src, "v1.0.0")], src)], daysAgo(1), "gen 1",
      extraFiles = @[("nimble-sources.toml", sourceSetText(@[catalogUrl]))])
    let dir = w.newProject(@[("alpha", "")])
    check refreshProvisioning(dir).rc == 0
    let userConfig = w.root / "config" / "reprobuild" / "config.toml"
    createDir(parentDir(userConfig))
    writeFile(userConfig, "schema = \"reprobuild.config.v1\"\n\n[nimble]\n" &
      "mirrors = [\"" & configuredUrl & "\"]\n")
    let paths = MirrorConfigPaths(user: userConfig,
      system: w.root / "etc" / "repro" / "config.toml")

    proc prepare(step: string): NimbleSourcesReport =
      var tmpl = f.fetchConfig(w.root / ("fetch-" & step), @[],
        store = w.root / ("store-" & step))
      tmpl.useClosureIndex = false
      prepareLockedNimbleSources(dir, dir / "repro.lock",
        NimbleSourcesOptions(mirrorConfig: some(paths),
          fetchTemplate: some(tmpl)))

    proc hits(prefix: string): int = f.requestsMatching(prefix & sourceObjectPath(src.tree))

    # 1. Both mirrors hold it: the configured one serves it.
    let first = prepare("1")
    var order: seq[string]
    for m in first.mirrors: order.add m.location
    check order == @[configuredUrl, catalogUrl]
    check first.configuredMirrors.len == 1
    check first.configuredMirrors[0].source == userConfig
    check first.fetched == @["alpha"]
    check hits("/configured/") >= 1
    check hits("/catalog/") == 0
    check entryVerified(w.root / "store-1", src.tree)

    # 2. Not on the configured mirror: the catalog's serves it.
    removeFile(configuredDir / sourceObjectPath(src.tree))
    let configuredBefore = hits("/configured/")
    let second = prepare("2")
    check second.fetched == @["alpha"]
    check hits("/configured/") > configuredBefore
    check hits("/catalog/") >= 1
    check entryVerified(w.root / "store-2", src.tree)

    # 3. On neither: the origin's forge archive serves it.
    removeFile(catalogDir / sourceObjectPath(src.tree))
    let archivesBefore = f.requestsMatching("/archive/" & src.commit)
    let third = prepare("3")
    check third.fetched == @["alpha"]
    check f.requestsMatching("/archive/" & src.commit) > archivesBefore
    check entryVerified(w.root / "store-3", src.tree)
    check third.storePaths["alpha"] == entryPath(w.root / "store-3", src.tree)
