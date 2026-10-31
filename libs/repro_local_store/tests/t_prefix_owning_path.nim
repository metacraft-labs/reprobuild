## ReproOS-Agent-Harbor-Integration M3 deliverable 1, first step: an
## installed file resolves to the realized prefix that owns it.
##
## A real store, real realized prefixes and real symlinks; nothing mocked.

import std/[os, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_local_store

proc stage(dir, name, body: string) =
  createDir(dir / "bin")
  writeFile(dir / "bin" / name, body)
  setFilePermissions(dir / "bin" / name, {fpUserRead, fpUserWrite, fpUserExec})

suite "M3 — an installed path resolves to its owning prefix":
  let tmp = createTempDir("repro-owning-", "")
  var store = openStore(tmp / "store")
  stage(tmp / "stage-a", "hello", "#!/bin/sh\necho a\n")
  stage(tmp / "stage-b", "hello", "#!/bin/sh\necho b\n")
  let a = store.realizeDirectoryAsPrefix(tmp / "stage-a", StoreReceiptHint(
    adapter: "install-mirror", packageName: "hello", version: "1.0",
    lockIdentity: "install-mirror:hello:1.0",
    declaredExecutablePath: "bin/hello"))
  let b = store.realizeDirectoryAsPrefix(tmp / "stage-b", StoreReceiptHint(
    adapter: "install-mirror", packageName: "hello", version: "1.1",
    lockIdentity: "install-mirror:hello:1.1",
    declaredExecutablePath: "bin/hello"))

  test "a file inside a prefix names that prefix and its receipt":
    let hit = store.prefixOwningPath(a.absolutePath / "bin" / "hello")
    check hit.found
    check hit.row.prefixId == a.prefixId
    check hit.row.version == "1.0"
    let rec = readReceiptFile(a.absolutePath / ReceiptFileName)
    check rec.packageName == "hello"
    check receiptDigest(rec) == hit.row.receiptDigest
    check store.prefixOwningPath(b.absolutePath / "bin" / "hello").row.prefixId ==
      b.prefixId

  test "the prefix directory itself is owned by the prefix":
    check store.prefixOwningPath(a.absolutePath).row.prefixId == a.prefixId

  test "a launcher symlink outside the store resolves to its target's prefix":
    createDir(tmp / "profile" / "bin")
    createSymlink(b.absolutePath / "bin" / "hello", tmp / "profile" / "bin" / "hello")
    let hit = store.prefixOwningPath(tmp / "profile" / "bin" / "hello")
    check hit.found
    check hit.row.prefixId == b.prefixId

  test "paths outside every prefix are not owned":
    check not store.prefixOwningPath(tmp / "stage-a" / "bin" / "hello").found
    check not store.prefixOwningPath(tmp / "store").found
    check not store.prefixOwningPath(tmp / "does-not-exist").found
    # A directory under the store root that the index does not know.
    createDir(tmp / "store" / "prefixes" / "hello" / "9.9-forged")
    writeFile(tmp / "store" / "prefixes" / "hello" / "9.9-forged" / "x", "")
    check not store.prefixOwningPath(
      tmp / "store" / "prefixes" / "hello" / "9.9-forged" / "x").found

  store.close()
  try: removeDir(extendedPath(tmp)) except OSError: discard
