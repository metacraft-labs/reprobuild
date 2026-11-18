## Every reader that names a store prefix without the store's writer finds a
## prefix an older build named at 16 hex where it lies, and agrees with the
## store's own ``realizePrefix`` about it.
##
## Issue: reprobuild-pm
## issues/2026-11-12-the-realization-hash-envelope-omits-the-recipe-itself-runtimedeps-and-environment-values.md
## (§"Blocked": the directory-name widening is a migration of every existing
## store). Governing spec: Local-Content-Addressed-Store.md §"Realization
## Hash (normative)".
##
## The store now names a prefix with 40 hex of its id. One id must have one
## path on a store, so every caller that computes a prefix path for itself
## must return the 16-hex path when an older build's prefix of that id lies
## there, and the 40-hex path for everything else:
##
## * the self-host pin (``selfPrefixAbsolutePath``, which the resolving
##   launcher and the bootstrap's hand-over exec from);
## * the tool profiles' adapters (``unifiedPrefixPath``, and
##   ``registerInUnifiedStore``, whose ``INSERT OR IGNORE`` must not leave the
##   row at one name and the tree at the other);
## * the add-on's planned prefixes (``filesPrefixPath``, ``staticTreePath``,
##   and the files-prefix recovery's shape check);
## * the install-mirror sidecar, which records the path the store answered.
##
## Each legacy prefix is made the way an older build left one
## (``repro_test_support/legacy_store_prefixes``).
##
## MOCK POLICY: none. Real stores on real temporary directories, through the
## production entry points.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_core
import repro_local_store
import repro_lock
import repro_test_support/legacy_store_prefixes

import repro_selfhost
import repro_selfhost/handover
import repro_selfhost/install
import repro_core/cli_images

import repro_tool_profiles

import repro_addon/store_root
import repro_addon/static_tree
import repro_addon/fingerprint

import repro_project_dsl/install_mirror_resolver
import repro_project_dsl/install_mirror_publish

const Platform = "amd64-linux"

proc lockPinning(version: string): string =
  var sol = UnifiedSolution(variants: initTable[string, string](),
    packages: initTable[string, string](), optimal: true)
  sol.packages["reprobuild"] = version
  var ld = lockedDepsFromSolved(solutionToLock(sol, Platform, ""))
  for i in 0 ..< ld.packages.len:
    ld.packages[i].source = "store"
  ld.deps = lockedDepsFromPackages(ld.packages, Platform)
  serializeLockedDependencies(ld)

proc makeWritable(root: string) =
  if not dirExists(root): return
  for p in walkDirRec(root, yieldFilter = {pcFile, pcDir}):
    try: setFilePermissions(p, getFilePermissions(p) + {fpUserWrite})
    except OSError: discard
  setFilePermissions(root, getFilePermissions(root) + {fpUserWrite})

suite "path-only readers find a prefix an older build named":

  test "the self-host pin is executed from its 16-hex prefix":
    let root = createTempDir("repro-legacy-selfhost-", "")
    defer: removeDir(root)
    let storeRoot = root / "store"
    let project = root / "proj"
    createDir(project)
    writeFile(project / "repro.lock", lockPinning("0.1.4-legacy"))
    let tree = root / "img"
    createDir(tree / "bin")
    for name in [selfExecutableName(), reprobuildEngineExeName()]:
      writeFile(tree / "bin" / name, "image " & name & "\n")
    let first = installSelfImage(storeRoot, "0.1.4-legacy", Platform, tree)
    let pin = selfPinForProject(project)
    check pin.state == spsPinned
    var store = openStore(storeRoot)
    let legacyRel = store.renameToLegacyWidth(first.prefixId)
    store.close()
    let legacyAbs = storeRoot / legacyRel
    check selfPrefixAbsolutePath(storeRoot, pin) == legacyAbs
    check selfPrefixRelativePath(storeRoot, pin) == legacyRel
    let d = decideHandOver(pin, storeRoot, root / "boot-engine", "0.2.0", "")
    check d.prefix == legacyAbs
    check d.resident
    # Installing the pin again finds the same prefix: no second copy.
    forgetVerifiedPrefixes()
    let again = installSelfImage(storeRoot, "0.1.4-legacy", Platform, tree)
    check again.alreadyPresent
    check again.relativePath == legacyRel
    check not dirExists(storeRoot / selfPrefixRelativePath(pin))
    # Another version is placed at 40 hex.
    let other = installSelfImage(storeRoot, "0.1.5-new", Platform, tree)
    check other.relativePath.endsWith("-" & prefixIdHex(other.prefixId)[0 ..< 40])

  test "the tool profiles' unified path and registration agree with the row":
    let root = createTempDir("repro-legacy-toolprofile-", "")
    defer: removeDir(root)
    let storeRoot = root / "store"
    let src = root / "src"
    createDir(src / "bin")
    writeFile(src / "bin" / "tool", "#!/bin/sh\n")
    let hint = StoreReceiptHint(adapter: "tarball", packageName: "tool",
      version: "1.2", lockIdentity: "lock-a", declaredExecutablePath: "bin/tool",
      provenanceUrl: "https://example.invalid/tool.tar.gz",
      provenanceChecksum: "sha256:00")
    var store = openStore(storeRoot)
    let realized = store.realizeDirectoryAsPrefix(src, hint, extra = ["x"])
    let legacyRel = store.renameToLegacyWidth(realized.prefixId)
    store.close()
    let unified = unifiedPrefixPath(storeRoot, "tool", "1.2", "tarball",
      "lock-a", "bin/tool", "https://example.invalid/tool.tar.gz",
      "sha256:00", ["x"])
    check unified.prefixId == realized.prefixId
    check unified.relativePath == legacyRel
    check unified.absolutePath == storeRoot / legacyRel.replace('/', DirSep)
    # Re-registering at the unified path keeps one row at one path.
    let reg = registerInUnifiedStore(storeRoot, "tool", "1.2", "tarball",
      "lock-a", "bin/tool", "https://example.invalid/tool.tar.gz",
      "sha256:00", "copy", ["x"], unified.absolutePath)
    check not reg.inserted
    store = openStore(storeRoot)
    check store.lookupPrefix(realized.prefixId).row.realizedPath == legacyRel
    store.close()
    # Registering a second copy at the 40-hex name while the legacy prefix
    # is there is refused.
    let current = storeRoot / prefixRelativePath("tool", "1.2",
      realized.prefixId)
    createDir(current)
    expect StoreError:
      discard registerInUnifiedStore(storeRoot, "tool", "1.2", "tarball",
        "lock-a", "bin/tool", "https://example.invalid/tool.tar.gz",
        "sha256:00", "copy", ["x"], current)
    check not fileExists(current / ReceiptFileName)
    removeDir(current)
    # Once the legacy prefix is gone the unified path is the 40-hex name,
    # and registering there moves the row with the tree.
    removeDir(storeRoot / legacyRel)
    let moved = unifiedPrefixPath(storeRoot, "tool", "1.2", "tarball",
      "lock-a", "bin/tool", "https://example.invalid/tool.tar.gz",
      "sha256:00", ["x"])
    check moved.relativePath == prefixRelativePath("tool", "1.2",
      realized.prefixId)
    createDir(moved.absolutePath / "bin")
    writeFile(moved.absolutePath / "bin" / "tool", "#!/bin/sh\n")
    discard registerInUnifiedStore(storeRoot, "tool", "1.2", "tarball",
      "lock-a", "bin/tool", "https://example.invalid/tool.tar.gz",
      "sha256:00", "copy", ["x"], moved.absolutePath)
    store = openStore(storeRoot)
    check store.lookupPrefix(realized.prefixId).row.realizedPath ==
      moved.relativePath
    check store.recover().quarantinedPrefixes.len == 0
    store.close()

  test "the add-on's planned prefixes name the 16-hex prefix":
    let root = createTempDir("repro-legacy-addon-", "")
    defer: removeDir(root)
    let storeRoot = root / "store"
    let body = "export X=1\n"
    let name = sha256Hex(body)
    let filesDir = root / "files"
    createDir(filesDir)
    writeFile(filesDir / name, body)
    var store = openStore(storeRoot)
    let files = store.realizeDirectoryAsPrefix(filesDir,
      StoreReceiptHint(adapter: "addon-bootstrap", packageName: FilesPackage,
        version: "0.0.1", provenanceChecksum: "manifest:" & name))
    check files.prefixId == filesPrefixId([name], "0.0.1")
    let filesLegacy = storeRoot / store.renameToLegacyWidth(files.prefixId)
    let tree = @[StaticFile(path: "/etc/x.conf", content: "x\n")]
    let staging = root / "tree"
    createDir(parentDir(staging / staticRelPath("/etc/x.conf")))
    writeFile(staging / staticRelPath("/etc/x.conf"), "x\n")
    let st = store.realizeDirectoryAsPrefix(staging,
      StoreReceiptHint(adapter: "addon-switch", packageName: StaticTreePackage,
        version: ReprobuildVersion,
        provenanceChecksum: "tree:" & sha256Hex(treeManifest(tree))))
    let treeLegacy = storeRoot / store.renameToLegacyWidth(st.prefixId)
    store.close()
    check filesPrefixPath([name], "0.0.1", storeRoot) == filesLegacy
    check staticTreePath(tree, storeRoot) == treeLegacy
    check isFilesPrefixPath(filesLegacy, [name], "0.0.1", storeRoot)
    check isFilesPrefixPath(storeRoot / prefixRelativePath(FilesPackage,
      "0.0.1", files.prefixId), [name], "0.0.1", storeRoot)
    check not isFilesPrefixPath(filesLegacy, [name], "0.0.2", storeRoot)
    # A prefix that is not there yet is planned at 40 hex.
    check filesPrefixPath([name], "0.0.2", storeRoot).extractFilename ==
      "0.0.2-" & prefixIdHex(filesPrefixId([name], "0.0.2"))[0 ..< 40]

  test "the install-mirror sidecar records and accepts the 16-hex path":
    let root = createTempDir("repro-legacy-mirror-", "")
    defer:
      makeWritable(root)
      removeDir(root)
    let storeRoot = root / "store"
    let recipes = root / "recipes"
    let mirror = root / "mirror"
    createDir(mirror / "lib")
    writeFile(mirror / "lib" / "libdep.so", "dep\n")
    createDir(recipes / "dep")
    let first = publishInstallMirrorToStore(recipes, "dep", "1.0", mirror,
      storeRoot)
    var store = openStore(storeRoot)
    makeWritable(storeRoot / first.storeRelativePath)
    let legacyRel = store.renameToLegacyWidth(
      parseRealizationHashHex(first.realizationHashHex))
    store.close()
    removeFile(realizationInfoPath(recipes, "dep"))
    forgetVerifiedPrefixes()
    let again = publishInstallMirrorToStore(recipes, "dep", "1.0", mirror,
      storeRoot)
    check again.realizationHashHex == first.realizationHashHex
    check again.storeRelativePath == legacyRel
    let info = readRealizationInfoFile(recipes, "dep")
    check info.storeRelativePath == legacyRel
