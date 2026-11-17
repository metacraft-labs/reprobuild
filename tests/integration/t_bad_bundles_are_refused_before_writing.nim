## A bundle that is corrupted, made at other absolute roots or made by
## another `repro` is refused on import before anything is written, and the
## refusal names the cause.
##
## One repository of the selection fixture (`bundle_selection_fixture`) is
## built and exported with `repro store export`. The exporter's store, action
## cache and workspace are then moved aside, so the importer's roots, at the
## same absolute paths, are empty: a refused import that wrote anything would
## leave something there. Three bad bundles are imported with `repro store
## import`:
##
## - the exported bundle with one byte of its last part flipped (the
##   transport manifest still names the original SHA-256): refused by the
##   part check, naming the part and both digests;
## - the exported bundle imported with a store root and an action-cache root
##   other than the ones it was made at: refused by the root check, naming
##   both values of each;
## - a bundle made, through the same library export, with the producer
##   another `repro` version and revision would record: refused by the
##   producer check, naming both.
##
## After each refusal the importer's roots must be byte-identical to before
## (`snapshot`: every path's kind, mode, size, mtime and bytes).
##
## Positive control: the unmodified bundle then imports into those roots and
## the imported entries match the exporter's, so the importer could write
## there and the snapshot sees what it writes.
##
## Falsifying mutation: skipping the part's SHA-256 check (letting
## `readVerifiedPart` return the bytes unchecked) lets the flipped byte
## through: the unpacker writes into the roots before it fails, or the import
## fails for another reason, and the test turns red.
##
## No mocks: the built `repro`, GNU tar and zstd, real files. The third
## bundle is written by the store-bundle library linked into this test, which
## is the code `repro store export` runs; only its producer value differs.

import std/[json, os, strutils, tables, unittest]

import repro_local_store/store_bundle
import bundle_selection_fixture

proc flipLastPartByte(dir: string) =
  ## Flip one byte near the end of the last part: past the `contents` entry
  ## (which is first), inside the members the unpack writes.
  let manifest = parseJson(readFile(dir / "native-store.json"))
  let parts = manifest["parts"]
  let path = dir / parts[parts.len - 1]["file"].getStr()
  var bytes = readFile(path)
  let at = bytes.len - max(64, bytes.len div 8)
  bytes[at] = char(ord(bytes[at]) xor 0x5A)
  writeFile(path, bytes)

suite "bad bundles are refused before writing":
  test "a corrupted, a foreign-root and an other-repro bundle are refused naming the cause, and the importer is unchanged":
    var host = newSharedHost("repro-bad-bundles-")
    defer: cleanup(host)
    let ws = host.scratch / "ws"
    writeWorkspace(ws)
    discard buildRepos(host, ws, ["alpha"])
    let root = ws / "alpha"

    let good = host.scratch / "bundle-good"
    let exported = host.repro(["store", "export", "--root=" & root,
      "--out=" & good, "--store-root=" & host.storeRoot,
      "--action-cache-root=" & host.actionCacheRoot], root)
    checkpoint("repro store export, exit " & $exported.code & ":\n" &
      exported.output)
    require exported.code == 0

    # The same closure, as another repro would write it.
    let otherRepro = host.scratch / "bundle-other-repro"
    block:
      var closure = computeClosure(BundleRoots(storeRoot: host.storeRoot,
        actionCacheRoot: host.actionCacheRoot, workspaceRoots: @[root]))
      require closure.entries.len > 0
      closure.producer = BundleProducer(version: "0.0.1",
        revision: "0123456789abcdef0123456789abcdef01234567")
      discard exportBundle(closure, defaultExportOptions(otherRepro))

    let corrupted = host.scratch / "bundle-corrupted"
    copyDir(good, corrupted)
    flipLastPartByte(corrupted)

    # The importer: the same absolute roots, empty.
    let aside = host.scratch / "exporter"
    createDir(aside)
    moveDir(host.storeRoot, aside / "store")
    moveDir(host.actionCacheRoot, aside / "action-cache")
    moveDir(root, aside / "alpha")
    let importerRoots = @[host.storeRoot, host.actionCacheRoot, root]
    let before = snapshot(importerRoots)
    for path in importerRoots:
      require before[path] == "absent"

    proc importInto(bundle: string; storeRoot = host.storeRoot;
                    acRoot = host.actionCacheRoot): tuple[code: int,
                    output: string] =
      host.repro(["store", "import", bundle, "--root=" & root,
        "--store-root=" & storeRoot, "--action-cache-root=" & acRoot],
        host.scratch)

    let foreignStore = host.scratch / "elsewhere" / "store"
    let foreignAc = host.scratch / "elsewhere" / "action-cache"
    let partName = parseJson(readFile(corrupted / "native-store.json"))[
      "parts"][^1]["file"].getStr()
    let cases = [
      (name: "a flipped byte", bundle: corrupted, storeRoot: host.storeRoot,
       acRoot: host.actionCacheRoot,
       expect: @["bundle part " & partName, "SHA-256"]),
      (name: "foreign roots", bundle: good, storeRoot: foreignStore,
       acRoot: foreignAc,
       expect: @["store root: bundle " & host.storeRoot & ", local " &
         foreignStore, "action-cache root: bundle " & host.actionCacheRoot &
         ", local " & foreignAc, "nothing was imported"]),
      (name: "another repro", bundle: otherRepro, storeRoot: host.storeRoot,
       acRoot: host.actionCacheRoot,
       expect: @["made by repro 0.0.1 (revision " &
         "0123456789abcdef0123456789abcdef01234567)", "this is repro ",
         "nothing was imported"])]
    for c in cases:
      let res = importInto(c.bundle, c.storeRoot, c.acRoot)
      checkpoint(c.name & ": repro store import, exit " & $res.code & ":\n" &
        res.output)
      check res.code == 1
      for needle in c.expect:
        check needle in res.output
      let after = snapshot(importerRoots &
        @[foreignStore.parentDir])
      var expected = before
      expected[foreignStore.parentDir] = "absent"
      let diff = snapshotDiff(expected, after)
      checkpoint(c.name & ": importer changes: " & diff)
      check diff.len == 0

    # Positive control: the good bundle imports, and writes what it carries.
    let res = importInto(good)
    checkpoint("good bundle: repro store import, exit " & $res.code & ":\n" &
      res.output)
    check res.code == 0
    check snapshotDiff(before, snapshot(importerRoots)).len > 0
    check readFile(root / outputRel("alpha")) ==
      readFile(aside / "alpha" / outputRel("alpha"))
