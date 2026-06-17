## DSL-port M9.A acceptance — ``consumeConfigFile`` materialises a
## recorded ``fs.configFile`` declaration to a content-addressed on-disk
## store with sha256 hashing and returns a ``DslManagedFiles`` handle
## downstream NDE-shim-style consumers can read bytes off of.
##
## Pins:
##
##   1. ``registerStoreRoot(packageName, rootPath, dhaSha256)`` opens
##      the materialisation channel; ``consumeConfigFile(packageName,
##      path)`` then writes ``content`` verbatim to
##      ``<rootPath>/<hashHex>/<relPath>`` and returns the handle.
##
##   2. The returned ``hashHex`` is exactly 64 lower-case hex characters
##      (sha256) so downstream cache-key invariants hold.
##
##   3. The returned ``relPath`` is the original path with the leading
##      ``/`` stripped — matches the shim modules' POSIX-relative
##      in-store layout convention.
##
##   4. ``consumeConfigFile`` is IDEMPOTENT: a second call with the
##      same arguments returns a byte-identical handle and does not
##      re-write the file.
##
##   5. The hashHex is DETERMINISTIC and content-discriminating:
##      identical content → identical hashHex; differing content →
##      differing hashHex; differing path with the same content →
##      differing hashHex (the path is mixed into the cache key).

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_project_dsl/fs as fs

suite "DSL-port M9.A — consumeConfigFile":

  test "materialise records bytes under <storeRoot>/<hashHex>/<relPath>":
    resetDslPortFsState()
    resetDslPortMaterialiseState()

    let storeRoot = getTempDir() / "dsl-m9a-cf-1"
    if dirExists(storeRoot):
      removeDir(storeRoot)
    createDir(storeRoot)

    registerStoreRoot("fooPkg", storeRoot, dhaSha256)
    fs.configFile(
      path = "/etc/foo.conf",
      content = "hello\n",
      packageName = "fooPkg")

    let mf = consumeConfigFile("fooPkg", "/etc/foo.conf")

    # sha256 produces exactly 64 lower-hex chars.
    check mf.hashHex.len == 64

    # relPath is the original with leading "/" stripped.
    check mf.relPath == "etc/foo.conf"

    # storePath is <storeRoot>/<hashHex>.
    check mf.storePath.endsWith(mf.hashHex)
    check mf.storePath == storeRoot / mf.hashHex

    # Materialised on-disk shape: directory exists, file exists, content
    # matches verbatim.
    check dirExists(mf.storePath)
    check fileExists(mf.storePath / mf.relPath)
    check readFile(mf.storePath / mf.relPath) == "hello\n"

  test "consumeConfigFile is idempotent — second call returns identical handle":
    resetDslPortFsState()
    resetDslPortMaterialiseState()

    let storeRoot = getTempDir() / "dsl-m9a-cf-idem"
    if dirExists(storeRoot):
      removeDir(storeRoot)
    createDir(storeRoot)

    registerStoreRoot("fooPkg", storeRoot, dhaSha256)
    fs.configFile(
      path = "/etc/foo.conf",
      content = "hello\n",
      packageName = "fooPkg")

    let mf1 = consumeConfigFile("fooPkg", "/etc/foo.conf")
    let mf2 = consumeConfigFile("fooPkg", "/etc/foo.conf")

    # Handles compare byte-identical on every field.
    check mf1.storePath == mf2.storePath
    check mf1.relPath == mf2.relPath
    check mf1.hashHex == mf2.hashHex
    check mf1.packageName == mf2.packageName
    check mf1.artifactName == mf2.artifactName

  test "hashHex discriminates on content and on path":
    resetDslPortFsState()
    resetDslPortMaterialiseState()

    let storeRoot = getTempDir() / "dsl-m9a-cf-disc"
    if dirExists(storeRoot):
      removeDir(storeRoot)
    createDir(storeRoot)

    registerStoreRoot("pkgA", storeRoot, dhaSha256)
    registerStoreRoot("pkgB", storeRoot, dhaSha256)
    registerStoreRoot("pkgC", storeRoot, dhaSha256)
    registerStoreRoot("pkgD", storeRoot, dhaSha256)

    # Two packages with IDENTICAL path + content but DIFFERENT
    # packageName → differing hashHex (the M9.A cache-key composition
    # mixes packageName). The reproducibility pin requires that
    # re-registering with the same args yields the same digest.
    fs.configFile(path = "/etc/x.conf", content = "same\n", packageName = "pkgA")
    fs.configFile(path = "/etc/x.conf", content = "same\n", packageName = "pkgB")
    let mfA = consumeConfigFile("pkgA", "/etc/x.conf")
    let mfB = consumeConfigFile("pkgB", "/etc/x.conf")
    # Different packageName → different digest.
    check mfA.hashHex != mfB.hashHex

    # Same package + same content + different PATH → different digest.
    fs.configFile(path = "/etc/y.conf", content = "z\n", packageName = "pkgC")
    fs.configFile(path = "/etc/q.conf", content = "z\n", packageName = "pkgC")
    let mfY = consumeConfigFile("pkgC", "/etc/y.conf")
    let mfQ = consumeConfigFile("pkgC", "/etc/q.conf")
    check mfY.hashHex != mfQ.hashHex

    # Same package + same path + different CONTENT → different digest.
    fs.configFile(path = "/etc/w.conf", content = "alpha\n", packageName = "pkgD")
    let mfW1 = consumeConfigFile("pkgD", "/etc/w.conf")
    let w1Hash = mfW1.hashHex

    # Reset materialisation cache but keep the M8 record table, then
    # rewrite the M8 record with NEW content under the same package +
    # path. resetDslPortFsState clears the M8 table; we re-register
    # both entries to keep the test self-contained.
    resetDslPortFsState()
    resetDslPortMaterialiseState()
    registerStoreRoot("pkgD", storeRoot, dhaSha256)
    fs.configFile(path = "/etc/w.conf", content = "alpha\n",
                  packageName = "pkgD")
    let mfW2 = consumeConfigFile("pkgD", "/etc/w.conf")
    # Same content → same digest (deterministic).
    check mfW2.hashHex == w1Hash

    resetDslPortFsState()
    resetDslPortMaterialiseState()
    registerStoreRoot("pkgD", storeRoot, dhaSha256)
    fs.configFile(path = "/etc/w.conf", content = "DIFFERENT\n",
                  packageName = "pkgD")
    let mfW3 = consumeConfigFile("pkgD", "/etc/w.conf")
    # Different content → different digest.
    check mfW3.hashHex != w1Hash
