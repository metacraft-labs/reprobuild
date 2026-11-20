## Install-mirror publishing into the content-addressed local store.
##
## Split out of ``install_mirror_resolver`` because this half needs the
## STORE RUNTIME (``openStore`` / ``realizeDirectoryAsPrefix``), while the
## resolver half is pure path arithmetic + shell emission.
##
## ``repro_project_dsl`` re-exports the resolver, so the resolver sits in
## the import closure of every *profile* compile
## (``repro_profile_compile``). A profile compile's ``--path`` set
## deliberately excludes the store runtime's SQLite binding and its
## ``shm_gset`` sibling dependency, so importing
## ``repro_local_store`` from the resolver broke every profile compile
## with ``cannot open file: repro_local_store``. Keeping the publisher in
## its own module — imported only by ``repro-install-mirror-publish`` and
## its tests — restores that boundary.

import std/[os, strutils]

import repro_local_store

import ./install_mirror_resolver

type
  InstallMirrorPublishResult* = object
    realizationHashHex*: string
    storeRelativePath*: string
    absolutePath*: string

proc enforceInstallMirrorStoreReadOnly(prefixRoot: string) =
  ## Strip every write bit from a prefix the store already held when this
  ## publish ran (one an older build published writable, before
  ## ``realizeDirectoryAsPrefix`` learned ``readOnly``). A prefix this publish
  ## realised is already read-only: the store stripped it in staging, so it
  ## was never indexed writable (Local-Content-Addressed-Store.md
  ## §"Read-Only Prefixes"). No symbolic link is followed: a link in a
  ## prefix may point into another prefix or out of the store, and its
  ## target's mode is not this prefix's to change.
  if prefixRoot.len == 0 or not dirExists(prefixRoot):
    raise newException(ValueError,
      "install mirror store prefix is missing: " & prefixRoot)
  stripTreeWriteBits(prefixRoot)

proc publishInstallMirrorToStore*(recipesRoot, depName, version,
                                  sourceDir: string;
                                  storeRoot = resolveCasStoreRoot()):
    InstallMirrorPublishResult =
  if recipesRoot.len == 0 or depName.len == 0:
    raise newException(ValueError, "recipes root and package name are required")
  if version.len == 0:
    raise newException(ValueError, "package version is required")
  if sourceDir.len == 0 or not dirExists(sourceDir):
    raise newException(ValueError, "install mirror source directory is missing")
  # The realization id is keyed on the store's canonical tree digest
  # (``storeTreeDigest``, ``tree-v2:``): every file by content AND
  # executable bit, every symlink by its target text, every directory by
  # its presence. A digest of regular-file bytes alone gave two mirrors of
  # one package+version that differed only in a mode, a link target (a
  # ``libfoo.so`` re-pointed, or a link into a different runtime
  # dependency's prefix whose file is byte-identical) or a directory ONE
  # id, and the store's pre-flight then served the first tree for the
  # second (reprobuild-pm issue 2026-11-12, "the realization-hash envelope
  # omits the recipe itself, runtimeDeps, and environment values"). The
  # value carries its own ``tree-v2:`` scheme tag, so the ``tree:`` frame
  # below stays self-describing.
  let treeDigest = storeTreeDigest(sourceDir)
  var store = openStore(storeRoot)
  defer: store.close()
  let hint = StoreReceiptHint(
    adapter: "install-mirror",
    packageName: depName,
    version: version,
    declaredExecutablePath: "",
    exportedExecutables: @[],
    lockIdentity: "install-mirror:" & depName & ":" & version,
    provenanceUrl: "",
    provenanceChecksum: "",
    materializationMechanism: "")
  let realized = store.realizeDirectoryAsPrefix(sourceDir, hint,
    extra = ["tree:" & treeDigest], readOnly = true)
  result.realizationHashHex = prefixIdHex(realized.prefixId)
  result.storeRelativePath = realized.relativePath.replace("\\", "/")
  result.absolutePath = realized.absolutePath.replace("\\", "/")
  enforceInstallMirrorStoreReadOnly(result.absolutePath)
  writeRealizationInfoFile(recipesRoot, depName, version,
    result.realizationHashHex, result.storeRelativePath)
