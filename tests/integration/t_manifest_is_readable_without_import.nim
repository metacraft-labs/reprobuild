## `repro bundle inspect` prints what a machine must provide to restore a
## bundle (the roots to provision, the `repro` that made it and the
## selection) without importing it and without writing anything.
##
## The selection fixture (`bundle_selection_fixture`) is built, and `repro
## bundle create pair` writes a bundle with no Nix half. `inspect --json`
## then reads the whole bundle and, separately, its native half alone.
##
## What it requires: the report's schema is `reprobuild.bundle-inspect.v1`;
## its roots are the store root, action-cache root and workspace root the
## bundle was made with, and the workspace directory; it has no `nixStore`
## (the bundle has no Nix half); its producer is the version `repro
## --version` prints and a source revision that is spelled in the engine
## binary; its selection is the selector, the members `.`, `alpha` and
## `beta`, and the excluded `gamma` checkout. Nothing changes anywhere while
## it runs: the bundle directory, the store, the action cache, the workspace
## and the process's own temporary directory are byte-identical before and
## after (`snapshot`).
##
## Negative control: the same bundle with a byte of its first part flipped is
## refused by `inspect`, naming the part's SHA-256, so the values it prints
## are read through the verification, not from the unverified JSON.
##
## No mocks: the built `repro`, real Git checkouts, GNU tar and zstd.

import std/[json, os, osproc, strutils, unittest]

import bundle_selection_fixture

suite "a bundle's manifest is readable without importing it":
  test "inspect prints the roots to provision, the producer and the selection, and writes nothing":
    var host = newSharedHost("repro-bundle-inspect-")
    defer: cleanup(host)
    let ws = host.scratch / "ws"
    writeWorkspace(ws)
    discard buildRepos(host, ws, ["alpha", "beta"])
    let outDir = host.scratch / "bundles"
    let created = host.repro(["bundle", "create", PairProject, "--no-nix",
      "--out=" & outDir, "--workspace-root=" & ws,
      "--store-root=" & host.storeRoot,
      "--action-cache-root=" & host.actionCacheRoot], ws)
    checkpoint("repro bundle create, exit " & $created.code & ":\n" &
      created.output)
    require created.code == 0
    let bundle = outDir / PairProject
    let native = halfDir(bundle, "native_store")

    # Every place a write could land, including a private temporary
    # directory the command is pointed at.
    let tmp = host.scratch / "tmp"
    createDir(tmp)
    let watched = @[outDir, host.storeRoot, host.actionCacheRoot, ws, tmp]
    let before = snapshot(watched)

    let version = execCmdEx(quoteShell(reproBinary()) & " --version").output.strip()
    let engine = readFile(reproBinary().parentDir / "reprobuild")
    for source in [bundle, native]:
      let res = host.reproStdout(["bundle", "inspect", source, "--json"],
        host.scratch, [("TMPDIR", tmp)])
      checkpoint("repro bundle inspect " & source & ", exit " & $res.code &
        ":\n" & res.stdout & res.stderr)
      require res.code == 0
      let r = parseJson(res.stdout)
      check r["schema"].getStr() == "reprobuild.bundle-inspect.v1"
      check r["kind"].getStr() == (if source == bundle: "workspace"
                                   else: "native-store")
      let pr = r["provision"]
      check pr["storeRoot"].getStr() == host.storeRoot
      check pr["actionCacheRoot"].getStr() == host.actionCacheRoot
      check pr["workspaceRoots"] == %*[ws]
      check not pr.hasKey("nixStore")
      check r["selection"]["exclude"] == %*[ws / "gamma"]
      check r["selection"]["include"] == newJArray()
      check r["bundleId"].getStr() == native.extractFilename
      # The producer: this repro's version, and a revision the engine
      # binary carries (the version alone does not identify a build).
      check version == "repro " & r["producer"]["version"].getStr()
      let revision = r["producer"]["revision"].getStr()
      check revision.len >= 40 and revision in engine
      if source == bundle:
        check pr["workspaceDir"].getStr() == ws
        check r["selector"].getStr() == PairProject
        check r["members"] == %*[".", "alpha", "beta"]
        check r["halves"].hasKey("sources")
        check r["halves"]["native_store"].getStr() == native.extractFilename

    let diff = snapshotDiff(before, snapshot(watched))
    checkpoint("changes while inspecting: " & diff)
    check diff.len == 0

  test "inspect refuses a bundle whose part fails its SHA-256":
    var host = newSharedHost("repro-bundle-inspect-bad-")
    defer: cleanup(host)
    let ws = host.scratch / "ws"
    writeWorkspace(ws)
    discard buildRepos(host, ws, ["alpha"])
    let half = host.scratch / "half"
    let exported = host.repro(["store", "export", "--root=" & ws / "alpha",
      "--out=" & half, "--store-root=" & host.storeRoot,
      "--action-cache-root=" & host.actionCacheRoot], ws)
    require exported.code == 0
    let part = half / parseJson(readFile(half / "native-store.json"))[
      "parts"][0]["file"].getStr()
    var bytes = readFile(part)
    bytes[bytes.len div 2] = char(ord(bytes[bytes.len div 2]) xor 0x5A)
    writeFile(part, bytes)
    let res = host.reproStdout(["bundle", "inspect", half, "--json"],
      host.scratch)
    checkpoint("repro bundle inspect, exit " & $res.code & ":\n" &
      res.stdout & res.stderr)
    check res.code == 1
    check res.stdout.len == 0
    check "SHA-256" in res.stderr
