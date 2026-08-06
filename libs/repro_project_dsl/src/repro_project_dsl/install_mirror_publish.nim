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
## ``repro_shm_index`` -> ``shm_queue`` sibling dependency, so importing
## ``repro_local_store`` from the resolver broke every profile compile
## with ``cannot open file: repro_local_store``. Keeping the publisher in
## its own module — imported only by ``repro-install-mirror-publish`` and
## its tests — restores that boundary.

import std/[algorithm, os, strutils]

import blake3
import repro_local_store

import ./install_mirror_resolver

proc installMirrorTreeDigest(sourceDir: string): string =
  if not dirExists(sourceDir):
    return ""
  var entries: seq[tuple[path: string; size: int64; digest: PrefixIdBytes]] =
    @[]
  for entry in walkDirRec(sourceDir, yieldFilter = {pcFile, pcLinkToFile},
                          relative = true):
    let abs = sourceDir / entry
    let raw = readFile(abs)
    let digest = blake3.digest(raw)
    entries.add((path: entry.replace("\\", "/"),
      size: getFileSize(abs), digest: digest))
  entries.sort(proc (a, b: tuple[path: string; size: int64;
                                 digest: PrefixIdBytes]): int =
    cmp(a.path, b.path))
  var manifest = "reprobuild.install-mirror-tree.v1\n"
  for e in entries:
    manifest.add(e.path)
    manifest.add("\t")
    manifest.add($e.size)
    manifest.add("\t")
    manifest.add(prefixIdHex(e.digest))
    manifest.add("\n")
  prefixIdHex(blake3.digest(manifest))

type
  InstallMirrorPublishResult* = object
    realizationHashHex*: string
    storeRelativePath*: string
    absolutePath*: string

const InstallMirrorWritePermissions = {
  fpUserWrite, fpGroupWrite, fpOthersWrite
}

proc stripWritePermissions(path: string) =
  var permissions = getFilePermissions(path)
  let original = permissions
  for permission in InstallMirrorWritePermissions:
    permissions.excl(permission)
  if permissions != original:
    setFilePermissions(path, permissions)

proc enforceInstallMirrorStoreReadOnly(prefixRoot: string) =
  if prefixRoot.len == 0 or not dirExists(prefixRoot):
    raise newException(ValueError,
      "install mirror store prefix is missing: " & prefixRoot)
  var dirs = @[prefixRoot]
  for entry in walkDirRec(prefixRoot,
                          yieldFilter = {pcFile, pcLinkToFile, pcDir},
                          relative = true):
    let path = prefixRoot / entry
    if dirExists(path):
      dirs.add(path)
    else:
      stripWritePermissions(path)
  dirs.sort(proc (a, b: string): int = cmp(b.len, a.len))
  for dir in dirs:
    stripWritePermissions(dir)

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
  let treeDigest = installMirrorTreeDigest(sourceDir)
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
    extra = ["tree:" & treeDigest])
  result.realizationHashHex = prefixIdHex(realized.prefixId)
  result.storeRelativePath = realized.relativePath.replace("\\", "/")
  result.absolutePath = realized.absolutePath.replace("\\", "/")
  enforceInstallMirrorStoreReadOnly(result.absolutePath)
  writeRealizationInfoFile(recipesRoot, depName, version,
    result.realizationHashHex, result.storeRelativePath)
