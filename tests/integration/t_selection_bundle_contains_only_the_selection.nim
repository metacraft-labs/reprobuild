## A bundle of a selection of a workspace carries that selection's records,
## blobs, outputs and checkouts, and nothing of a repository it did not
## select.
##
## The workspace has three repositories, `alpha`, `beta` and `gamma`, each a
## repro project whose one monitored action copies a source file into an
## output; the package name, the source's name and bytes and the output's
## name and bytes carry a marker unique to the repository
## (`bundle_selection_fixture`). All three are built against one store and
## one action cache. Then `repro bundle create` writes two bundles without a
## Nix half: `all` (the three) and `pair` (alpha and beta).
##
## What it requires: unpacked, the `pair` bundle's native half holds alpha's
## and beta's markers in action-cache records (`hot-records/`), in blobs
## (every other file under the action-cache root: the content-keyed recipe
## compiles, that is the compiled project provider and the extracted
## interface, and the CAS blobs of payload-backed records; a default local
## build keeps no payload of an ordinary edge, so these are the stored bytes
## a bundle carries there) and in outputs under the workspace, and its
## sources half holds their checkouts; gamma's marker is nowhere in either
## half, searched in the raw decompressed tar streams, names and bytes
## alike.
##
## Vacuity guard: the `all` bundle holds all three markers in records, blobs,
## outputs and checkouts, so "gamma is absent" cannot come from a fixture or
## a search that finds nothing.
##
## Falsifying mutation: computing the native half from the whole workspace
## root instead of the selection (dropping the selection `repro bundle
## create` passes to the closure) puts gamma's record, blob and output in the
## `pair` bundle and turns the test red.
##
## The second case is what `repro store closure --selection` reports: the
## selection itself, and a record skipped because its output changed after
## the record was written, with the reason class `output-changed`.
##
## No mocks: the built `repro`, real Git checkouts, the engine's monitor and
## action cache, GNU tar and zstd.

import std/[json, os, strutils, unittest]

import bundle_selection_fixture

proc markersIn(root: string; repo: string): seq[string] =
  filesContaining(root, markerOf(repo))

suite "a bundle of a selection carries only the selection":
  test "the pair bundle holds alpha's and beta's records, blobs, outputs and checkouts, and nothing of gamma":
    var host = newSharedHost("repro-selection-bundle-")
    defer: cleanup(host)
    let ws = host.scratch / "ws"
    writeWorkspace(ws)
    discard buildRepos(host, ws, Repos)

    let outDir = host.scratch / "bundles"
    for project in [AllProject, PairProject]:
      let res = host.repro(["bundle", "create", project, "--no-nix",
        "--out=" & outDir, "--workspace-root=" & ws,
        "--store-root=" & host.storeRoot,
        "--action-cache-root=" & host.actionCacheRoot], ws)
      checkpoint("repro bundle create " & project & ", exit " & $res.code &
        ":\n" & res.output)
      require res.code == 0

    # Where each kind of artefact lands once a half is unpacked at `/`.
    let acRel = host.actionCacheRoot.relativePath("/")
    let wsRel = ws.relativePath("/")
    proc kinds(bundle: string): tuple[records, blobs, outputs,
        checkouts: string] =
      let native = host.scratch / ("unpacked-" & bundle & "-native")
      let sources = host.scratch / ("unpacked-" & bundle & "-sources")
      unpackHalf(halfDir(outDir / bundle, "native_store"),
        "native-store.json", native)
      unpackHalf(halfDir(outDir / bundle, "sources"), "sources.json", sources)
      (native / acRel / "action-cache" / "hot-records",
       native / acRel, native / wsRel, sources)

    let all = kinds(AllProject)
    let pair = kinds(PairProject)
    proc blobsOf(acRoot, repo: string): seq[string] =
      # Under the action-cache root but not a record: the output bytes the
      # engine keeps for shareable records.
      for f in markersIn(acRoot, repo):
        if not f.startsWith("action-cache" / "hot-records"):
          result.add(f)

    # Vacuity guard: the bundle of everything carries every marker in every
    # kind of artefact.
    for repo in Repos:
      checkpoint("all: " & repo & " records " & $markersIn(all.records, repo) &
        ", blobs " & $blobsOf(all.blobs, repo) & ", outputs " &
        $markersIn(all.outputs, repo) & ", checkouts " &
        $markersIn(all.checkouts, repo))
      check markersIn(all.records, repo).len > 0
      check blobsOf(all.blobs, repo).len > 0
      check markersIn(all.outputs, repo).len > 0
      check markersIn(all.checkouts, repo).len > 0

    for repo in ["alpha", "beta"]:
      checkpoint("pair: " & repo & " records " &
        $markersIn(pair.records, repo) & ", blobs " &
        $blobsOf(pair.blobs, repo) & ", outputs " &
        $markersIn(pair.outputs, repo) & ", checkouts " &
        $markersIn(pair.checkouts, repo))
      check markersIn(pair.records, repo).len > 0
      check blobsOf(pair.blobs, repo).len > 0
      check markersIn(pair.outputs, repo).len > 0
      check markersIn(pair.checkouts, repo).len > 0

    let gamma = markerOf("gamma")
    checkpoint("pair: gamma records " & $markersIn(pair.records, "gamma") &
      ", under the action-cache root " & $markersIn(pair.blobs, "gamma") &
      ", outputs " & $markersIn(pair.outputs, "gamma") & ", checkouts " &
      $markersIn(pair.checkouts, "gamma"))
    check markersIn(pair.records, "gamma").len == 0
    check markersIn(pair.blobs, "gamma").len == 0
    check markersIn(pair.outputs, "gamma").len == 0
    check markersIn(pair.checkouts, "gamma").len == 0
    # Names and bytes of every member of both halves. Booleans, so a failure
    # does not print the streams.
    let nativeHasGamma = gamma in halfStreamBytes(halfDir(outDir / PairProject,
      "native_store"), "native-store.json")
    let sourcesHasGamma = gamma in halfStreamBytes(halfDir(outDir /
      PairProject, "sources"), "sources.json")
    check not nativeHasGamma
    check not sourcesHasGamma

    # The selection is recorded in the bundle: gamma's checkout is excluded.
    let manifest = parseJson(readFile(halfDir(outDir / PairProject,
      "native_store") / "native-store.json"))
    check manifest["selection"]["exclude"] == %*[ws / "gamma"]
    check manifest["roots"]["workspaceRoots"] == %*[ws]

  test "store closure reports the selection and a record whose output changed":
    var host = newSharedHost("repro-selection-closure-")
    defer: cleanup(host)
    let ws = host.scratch / "ws"
    writeWorkspace(ws)
    discard buildRepos(host, ws, Repos)
    # alpha's output changes after its record was written: the record no
    # longer vouches for what is on disk, so it cannot travel.
    let changed = ws / "alpha" / outputRel("alpha")
    writeFile(changed, readFile(changed) & "edited after the build\n")

    let res = host.reproStdout(["store", "closure", "--selection=" &
      PairProject, "--workspace-root=" & ws, "--store-root=" & host.storeRoot,
      "--action-cache-root=" & host.actionCacheRoot, "--json"], ws)
    checkpoint("repro store closure, exit " & $res.code & ":\n" & res.stdout &
      res.stderr)
    require res.code == 0
    let report = parseJson(res.stdout)
    check report["selection"]["selector"].getStr() == PairProject
    check report["selection"]["exclude"] == %*[ws / "gamma"]
    var members: seq[string]
    for m in report["selection"]["members"]: members.add(m.getStr())
    check members == @[".", "alpha", "beta"]
    check report["roots"]["workspaceRoots"] == %*[ws]

    var skippedAlpha, carriedBeta, anyGamma = false
    for s in report["skippedRecords"]:
      checkpoint("skipped: " & $s)
      if s["kind"].getStr() == "output-changed" and
          "alpha" in s["reason"].getStr():
        skippedAlpha = true
    for r in report["carriedRecords"]:
      let edge = r["edge"].getStr()
      for path in walkDirRec(edge):
        if markerOf("beta") in readFile(path): carriedBeta = true
        if markerOf("gamma") in readFile(path): anyGamma = true
    check skippedAlpha
    check carriedBeta
    check not anyGamma
