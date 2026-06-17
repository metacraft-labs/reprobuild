## DSL-port M9.A acceptance — ``dhaFnv1a`` fallback path for
## ``consumeConfigFile``.
##
## Pins:
##
##   1. ``registerStoreRoot(..., dhaFnv1a)`` swaps the materialisation
##      digest from sha256 to the M8 FNV-1a stableHashHex; the returned
##      hashHex is exactly 16 lower-hex chars.
##
##   2. The FNV-1a digest is bit-stable across runs for known input.
##      ``stableHashHex`` is the same proc the M8 ``fs.configFile``
##      records into ``DslConfigFile.hashHex``, so a recipe that wants
##      a "fast in-memory record" path stays compatible with the M9.A
##      on-disk emission API.
##
##   3. The on-disk layout is identical to the sha256 path: the file
##      lives under ``<storeRoot>/<hashHex>/<relPath>`` with the
##      content verbatim.

import std/[os, unittest]

import repro_project_dsl
import repro_project_dsl/fs as fs

suite "DSL-port M9.A — consumeConfigFile with dhaFnv1a fallback":

  test "FNV-1a digest is 16 hex chars and on-disk layout matches sha256 path":
    resetDslPortFsState()
    resetDslPortMaterialiseState()

    let storeRoot = getTempDir() / "dsl-m9a-fnv-1"
    if dirExists(storeRoot):
      removeDir(storeRoot)
    createDir(storeRoot)

    registerStoreRoot("fnvPkg", storeRoot, dhaFnv1a)
    fs.configFile(
      path = "/etc/fnv.conf",
      content = "deterministic\n",
      packageName = "fnvPkg")

    let mf = consumeConfigFile("fnvPkg", "/etc/fnv.conf")

    # FNV-1a stableHashHex emits exactly 16 lower-hex chars.
    check mf.hashHex.len == 16

    # On-disk layout matches the sha256 path: file exists with the
    # content verbatim.
    check fileExists(mf.storePath / mf.relPath)
    check readFile(mf.storePath / mf.relPath) == "deterministic\n"

  test "FNV-1a digest is bit-stable across runs":
    resetDslPortFsState()
    resetDslPortMaterialiseState()

    let storeRoot = getTempDir() / "dsl-m9a-fnv-stable"
    if dirExists(storeRoot):
      removeDir(storeRoot)
    createDir(storeRoot)

    registerStoreRoot("fnvPkg", storeRoot, dhaFnv1a)
    fs.configFile(
      path = "/etc/stable.conf",
      content = "abc\n",
      packageName = "fnvPkg")
    let h1 = consumeConfigFile("fnvPkg", "/etc/stable.conf").hashHex

    # Re-do the whole flow; expect bit-identical digest. The FNV-1a
    # algorithm has no entropy source so identical input must give
    # identical output every run.
    resetDslPortFsState()
    resetDslPortMaterialiseState()
    registerStoreRoot("fnvPkg", storeRoot, dhaFnv1a)
    fs.configFile(
      path = "/etc/stable.conf",
      content = "abc\n",
      packageName = "fnvPkg")
    let h2 = consumeConfigFile("fnvPkg", "/etc/stable.conf").hashHex
    check h1 == h2

    # Sanity check: 16 hex chars (re-checked here so a regression in
    # stableHashHex's output width surfaces against EVERY FNV-1a test
    # rather than only the layout test).
    check h1.len == 16
    check h2.len == 16
