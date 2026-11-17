## A prefix an older build named at the 64-bit width is found where it lies;
## every new prefix is named at 160 bits.
##
## Issue: reprobuild-pm
## issues/2026-11-12-the-realization-hash-envelope-omits-the-recipe-itself-runtimedeps-and-environment-values.md
## (§"Blocked": widening the directory name is a migration of every existing
## store). Governing spec: Local-Content-Addressed-Store.md §"Realization
## Hash (normative)", "The directory name: the one truncation".
##
## The store names a prefix ``<version>-<first 40 hex of its id>``. A store
## an older build wrote holds prefixes named with the first 16, indexed,
## sealed with receipts recording that path, and possibly bound by running
## units. The migration keeps each where it lies, so: recovery must keep it;
## ``realizePrefix`` for its id must return it rather than realize a second
## copy at the 40-hex name; the index-free resolver must name the same path;
## and an id whose 16-hex name is held by ANOTHER id's prefix must neither
## take that prefix nor displace it.
##
## The legacy prefix is made the way an older build left one
## (``repro_test_support/legacy_store_prefixes``: realize, then move it to
## the 16-hex leaf, re-seal its receipt with that path and update its row).
##
## MOCK POLICY: none. A real ``Store`` on a real temporary directory.

import std/[os, tempfiles, unittest]

from repro_core/paths import extendedPath

import repro_local_store
import repro_local_store/sqlite3_binding
import repro_test_support/legacy_store_prefixes

proc hintFor(pkg = "pkg"): StoreReceiptHint =
  StoreReceiptHint(adapter: "legacy-test", packageName: pkg,
    version: "1.0", lockIdentity: "legacy-test")

proc writer(content: string; calls: ref int = nil): proc (
    stagingDir: string; mechanism: var string) =
  result = proc (stagingDir: string; mechanism: var string) =
    if calls != nil: inc calls[]
    writeFile(stagingDir / "payload", content)
    mechanism = "copy"

proc dirsUnder(dir: string): seq[string] =
  for kind, path in walkDir(dir, relative = true):
    if kind == pcDir: result.add(path)

proc idSharing(base: PrefixIdBytes; shared: int): PrefixIdBytes =
  result = base
  for i in shared ..< result.len:
    result[i] = base[i] xor 0x5A'u8

suite "a prefix an older build named at 16 hex is found where it lies":

  test "recovery, realizePrefix and the resolver all keep the legacy path":
    let root = createTempDir("repro-legacy-prefix-", "")
    defer:
      try: removeDir(extendedPath(root)) except OSError: discard
    var store = openStore(root / "store")
    defer: store.close()
    let x = computeRealizationHash("pkg", "1.0", "legacy-test",
      "legacy-test", "", extra = ["old"])
    discard store.realizePrefix(x, hintFor(), writer("old bytes"))
    let legacyRel = store.renameToLegacyWidth(x)
    let legacyAbs = store.absolutePrefixPath(legacyRel)
    checkpoint "legacy prefix at " & legacyRel
    check legacyRel == "prefixes/pkg/1.0-" & prefixIdHex(x)[0 ..< 16]

    # Recovery keeps it: nothing quarantined, row and tree unchanged.
    let report = store.recover()
    check report.quarantinedPrefixes.len == 0
    check readFile(legacyAbs / "payload") == "old bytes"
    check store.lookupPrefix(x).row.realizedPath == legacyRel

    # realizePrefix for the same id returns it, and makes no second copy.
    forgetVerifiedPrefixes()
    let calls = new int
    let again = store.realizePrefix(x, hintFor(), writer("old bytes", calls))
    checkpoint "again at " & again.relativePath & " (" & $again.outcome & ")"
    check again.outcome == roAlreadyPresent
    check not again.replacedUntrusted
    check again.relativePath == legacyRel
    check again.absolutePath == legacyAbs
    check calls[] == 0
    check dirsUnder(root / "store" / "prefixes" / "pkg") ==
      @["1.0-" & prefixIdHex(x)[0 ..< 16]]

    # The index-free resolver names the same path.
    check resolvePrefixRelativePath(root / "store", "pkg", "1.0", x) ==
      legacyRel

    # A NEW id is named at 40 hex.
    let n = computeRealizationHash("pkg", "1.0", "legacy-test",
      "legacy-test", "", extra = ["new"])
    let fresh = store.realizePrefix(n, hintFor(), writer("new bytes"))
    check fresh.relativePath == "prefixes/pkg/1.0-" & prefixIdHex(n)[0 ..< 40]
    check resolvePrefixRelativePath(root / "store", "pkg", "1.0", n) ==
      fresh.relativePath

  test "an id sharing 64 bits with a legacy prefix is realized apart from it":
    let root = createTempDir("repro-legacy-collide-", "")
    defer:
      try: removeDir(extendedPath(root)) except OSError: discard
    var store = openStore(root / "store")
    defer: store.close()
    let x = computeRealizationHash("pkg", "1.0", "legacy-test",
      "legacy-test", "", extra = ["x"])
    discard store.realizePrefix(x, hintFor(), writer("bytes of X"))
    let legacyRel = store.renameToLegacyWidth(x)
    let y = idSharing(x, 8)
    # Y's 16-hex name is X's prefix; the resolver must not take it for Y.
    check resolvePrefixRelativePath(root / "store", "pkg", "1.0", y) ==
      prefixRelativePath("pkg", "1.0", y)
    let b = store.realizePrefix(y, hintFor(), writer("bytes of Y"))
    check b.relativePath == prefixRelativePath("pkg", "1.0", y)
    check not b.replacedUntrusted
    check readFile(b.absolutePath / "payload") == "bytes of Y"
    check readFile(store.absolutePrefixPath(legacyRel) / "payload") ==
      "bytes of X"
    check store.lookupPrefix(x).row.realizedPath == legacyRel
    forgetVerifiedPrefixes()
    let a = store.realizePrefix(x, hintFor(), writer("bytes of X"))
    check a.outcome == roAlreadyPresent
    check a.relativePath == legacyRel
    check store.recover().quarantinedPrefixes.len == 0

  test "a 16-hex name an older build gave to another id is left to that id":
    # What the 64-bit name did to a store before the widening (the issue's
    # measured failure): Y, sharing X's first 64 bits, was published into
    # X's directory -- X's row still names it, the tree and receipt there
    # are Y's, and Y has no row. Using X must not take Y's tree for X, nor
    # displace it: X is realized at its 40-hex name and its row moves there.
    let root = createTempDir("repro-legacy-collided-", "")
    defer:
      try: removeDir(extendedPath(root)) except OSError: discard
    var store = openStore(root / "store")
    defer: store.close()
    let x = computeRealizationHash("pkg", "1.0", "legacy-test",
      "legacy-test", "", extra = ["collided"])
    let y = idSharing(x, 8)
    discard store.realizePrefix(x, hintFor(), writer("bytes of X"))
    let legacyRel = store.renameToLegacyWidth(x)
    let legacyAbs = store.absolutePrefixPath(legacyRel)
    moveDir(legacyAbs, root / "x-aside")
    let yAt = store.realizePrefix(y, hintFor(), writer("bytes of Y"))
    moveDir(yAt.absolutePath, legacyAbs)
    var yReceipt = readReceiptFile(legacyAbs / ReceiptFileName)
    yReceipt.realizedPath = legacyRel
    writeReceiptFile(legacyAbs / ReceiptFileName, yReceipt)
    var d = store.db.prepare("DELETE FROM prefixes WHERE prefix_id = ?")
    d.bindBlob(1, y)
    discard d.step()
    d.finalize()
    check store.lookupPrefix(x).row.realizedPath == legacyRel
    check resolvePrefixRelativePath(root / "store", "pkg", "1.0", x) ==
      prefixRelativePath("pkg", "1.0", x)
    forgetVerifiedPrefixes()
    let a = store.realizePrefix(x, hintFor(), writer("bytes of X"))
    checkpoint "X now at " & a.relativePath & " (" & $a.outcome & ")"
    check a.relativePath == prefixRelativePath("pkg", "1.0", x)
    check not a.replacedUntrusted
    check readFile(a.absolutePath / "payload") == "bytes of X"
    check store.lookupPrefix(x).row.realizedPath == a.relativePath
    check readFile(legacyAbs / "payload") == "bytes of Y"
    check readReceiptFile(legacyAbs / ReceiptFileName).realizationHash == y
    check store.recover().quarantinedPrefixes.len == 0
    check readFile(legacyAbs / "payload") == "bytes of Y"

  test "a legacy prefix removed from under its row is restored at its path":
    # A unit or a generation names the legacy path; the store realizes the
    # id again THERE, so what binds it finds it.
    let root = createTempDir("repro-legacy-restore-", "")
    defer:
      try: removeDir(extendedPath(root)) except OSError: discard
    var store = openStore(root / "store")
    defer: store.close()
    let x = computeRealizationHash("pkg", "1.0", "legacy-test",
      "legacy-test", "", extra = ["restore"])
    discard store.realizePrefix(x, hintFor(), writer("bytes"))
    let legacyRel = store.renameToLegacyWidth(x)
    removeDir(store.absolutePrefixPath(legacyRel))
    check resolvePrefixRelativePath(root / "store", "pkg", "1.0", x) ==
      prefixRelativePath("pkg", "1.0", x)
    let back = store.realizePrefix(x, hintFor(), writer("bytes"))
    check back.relativePath == legacyRel
    check readFile(back.absolutePath / "payload") == "bytes"
    check readReceiptFile(back.absolutePath / ReceiptFileName).realizedPath ==
      legacyRel
    check resolvePrefixRelativePath(root / "store", "pkg", "1.0", x) ==
      legacyRel
    check not dirExists(store.absolutePrefixPath(
      prefixRelativePath("pkg", "1.0", x)))

  test "a legacy directory the index does not vouch for is not adopted":
    let root = createTempDir("repro-legacy-planted-", "")
    defer:
      try: removeDir(extendedPath(root)) except OSError: discard
    var store = openStore(root / "store")
    defer: store.close()
    let x = computeRealizationHash("pkg", "1.0", "legacy-test",
      "legacy-test", "", extra = ["planted"])
    discard store.realizePrefix(x, hintFor(), writer("bytes"))
    let legacyRel = store.renameToLegacyWidth(x)
    # Drop the row: a directory with a receipt naming x, and no row.
    var d = store.db.prepare("DELETE FROM prefixes WHERE prefix_id = ?")
    d.bindBlob(1, x)
    discard d.step()
    d.finalize()
    let res = store.realizePrefix(x, hintFor(), writer("bytes"))
    check res.replacedUntrusted
    check res.relativePath == prefixRelativePath("pkg", "1.0", x)
    check not dirExists(store.absolutePrefixPath(legacyRel))
    check resolvePrefixRelativePath(root / "store", "pkg", "1.0", x) ==
      res.relativePath

  test "store copy and the receipt check accept the recorded legacy path only":
    let x = computeRealizationHash("pkg", "1.0", "legacy-test",
      "legacy-test", "", extra = ["shape"])
    let legacyRel = legacyPrefixRelativePath("pkg", "1.0", x)
    var rec = RealizationReceipt(version: "1.0", realizationHash: x,
      packageName: "pkg", realizedPath: legacyRel)
    check prefixDirMatchesReceipt(legacyRel, rec)
    check prefixDirMatchesReceipt(prefixRelativePath("pkg", "1.0", x), rec)
    rec.realizedPath = prefixRelativePath("pkg", "1.0", x)
    check not prefixDirMatchesReceipt(legacyRel, rec)
    check not prefixDirMatchesReceipt("prefixes/pkg/1.0-0123456789abcdef", rec)
