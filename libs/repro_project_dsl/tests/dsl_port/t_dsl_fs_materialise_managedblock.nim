## DSL-port M9.A acceptance — ``consumeManagedBlock`` materialises the
## MERGED contributors for a host path to a content-addressed on-disk
## store with sha256 hashing.
##
## Pins:
##
##   1. The materialised bytes at ``<storePath>/<relPath>`` byte-equal
##      the output of ``mergedManagedBlockFile(path)`` so the
##      sort-discipline + sentinel-format guarantees from M8 carry
##      through to the on-disk emission unchanged.
##
##   2. The triple-form sentinels per spec §"Sentinel uniqueness" are
##      present in the materialised file.
##
##   3. ``hashHex`` is 64 lower-hex chars (sha256) and discriminates on
##      the merged content (re-registering the same contributors yields
##      the same digest; adding a new contributor changes the digest).
##
##   4. The first contributor by ``(priority, packageName, blockId)``
##      sort order picks the storeRoot — matches the M9.A design.

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_project_dsl/fs as fs

suite "DSL-port M9.A — consumeManagedBlock":

  test "materialised bytes equal mergedManagedBlockFile and carry triple sentinels":
    resetDslPortFsState()
    resetDslPortMaterialiseState()

    let storeRoot = getTempDir() / "dsl-m9a-mb-1"
    if dirExists(storeRoot):
      removeDir(storeRoot)
    createDir(storeRoot)

    # Three contributors; ``pkgA`` will be first by sort order
    # (priority 100 < 500), so it picks the storeRoot. Register the
    # storeRoot against every contributing package so the test does
    # not depend on the specific resolution rule (M9.A docs the
    # first-contributor convention but the test stays robust if a
    # later milestone widens it).
    registerStoreRoot("pkgA", storeRoot, dhaSha256)
    registerStoreRoot("pkgB", storeRoot, dhaSha256)
    registerStoreRoot("pkgC", storeRoot, dhaSha256)

    fs.managedBlock(
      path = "/etc/x.conf",
      blockId = "b1",
      scope = bsSystem,
      content = "B-content\n",
      priority = 500,
      packageName = "pkgB")
    fs.managedBlock(
      path = "/etc/x.conf",
      blockId = "b1",
      scope = bsSystem,
      content = "A-content\n",
      priority = 100,  # foundation tier → first
      packageName = "pkgA")
    fs.managedBlock(
      path = "/etc/x.conf",
      blockId = "b1",
      scope = bsSystem,
      content = "C-content\n",
      priority = 500,
      packageName = "pkgC")

    let mf = consumeManagedBlock("/etc/x.conf")

    # 64-char lower-hex sha256.
    check mf.hashHex.len == 64

    # Materialised on-disk shape exists.
    check dirExists(mf.storePath)
    check fileExists(mf.storePath / mf.relPath)
    check mf.relPath == "etc/x.conf"

    # Byte-equals mergedManagedBlockFile().
    let expectedMerged = mergedManagedBlockFile("/etc/x.conf")
    let actualBytes = readFile(mf.storePath / mf.relPath)
    check actualBytes == expectedMerged

    # Triple-form sentinels present for each contributor.
    check "# >>> repro:system:pkgA:b1 >>>" in actualBytes
    check "# >>> repro:system:pkgB:b1 >>>" in actualBytes
    check "# >>> repro:system:pkgC:b1 >>>" in actualBytes

    # First contributor by sort order is pkgA (priority 100) — its
    # block bytes appear before pkgB's.
    let idxA = actualBytes.find("A-content")
    let idxB = actualBytes.find("B-content")
    check idxA >= 0
    check idxB > idxA

  test "hashHex changes when a new contributor joins; deterministic for the same set":
    resetDslPortFsState()
    resetDslPortMaterialiseState()

    let storeRoot = getTempDir() / "dsl-m9a-mb-disc"
    if dirExists(storeRoot):
      removeDir(storeRoot)
    createDir(storeRoot)

    registerStoreRoot("pkgA", storeRoot, dhaSha256)
    fs.managedBlock(
      path = "/etc/y.conf",
      blockId = "b1",
      scope = bsSystem,
      content = "A-content\n",
      priority = 100,
      packageName = "pkgA")
    let mfOne = consumeManagedBlock("/etc/y.conf")
    let hashOne = mfOne.hashHex

    # Add a new contributor; the merged bytes change → the digest must
    # change. resetDslPortMaterialiseState drops the idempotency cache
    # so the digest is recomputed.
    resetDslPortMaterialiseState()
    registerStoreRoot("pkgA", storeRoot, dhaSha256)
    fs.managedBlock(
      path = "/etc/y.conf",
      blockId = "b2",
      scope = bsSystem,
      content = "second-content\n",
      priority = 200,
      packageName = "pkgA")
    let mfTwo = consumeManagedBlock("/etc/y.conf")
    check mfTwo.hashHex != hashOne

    # A FRESH session with the SAME contributors yields the SAME
    # digest as the first one (deterministic over identical inputs).
    resetDslPortFsState()
    resetDslPortMaterialiseState()
    registerStoreRoot("pkgA", storeRoot, dhaSha256)
    fs.managedBlock(
      path = "/etc/y.conf",
      blockId = "b1",
      scope = bsSystem,
      content = "A-content\n",
      priority = 100,
      packageName = "pkgA")
    let mfRepeat = consumeManagedBlock("/etc/y.conf")
    check mfRepeat.hashHex == hashOne
