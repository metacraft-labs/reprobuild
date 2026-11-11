## `zstd-dev`'s Windows realization supplies BOTH halves of its contract.
##
## The defect: the Windows arm realized the facebook/zstd win64 zip, whose
## header is at `include/zstd.h` but whose libraries are at
## `static/libzstd_static.lib` and `dll/libzstd.dll.a`. A tarball prefix
## threads only `<prefix>/include` onto `CPATH` and `<prefix>/lib` onto
## `LIBRARY_PATH`, and drops a missing directory without a diagnostic, so a
## consumer that declared `uses: "zstd-dev"` got the header and silently no
## library: `-lzstd` had nothing to bind.
##
## The assertions follow the chain from the declaration to the linker:
##
##   * the Windows arm is pinned to one archive and hashed, and its lock
##     identity carries the same digest;
##   * realizing an archive in that upstream's layout (MSYS2's: pacman
##     metadata beside one `ucrt64/` tree) with the arm's own strip and prune
##     declaration yields a prefix whose `include/` is on `CPATH`, whose
##     `lib/` is on `LIBRARY_PATH`, and whose `bin/` is gone;
##   * in that `lib/`, the only file GNU `ld` accepts for `-lzstd` is the
##     static `libzstd.a`. With the import library left in, `ld` would take
##     `libzstd.dll.a` first and every consumer would need `libzstd.dll` at
##     run time.
##
## The realization is the real one (`resolveTarballTool`: the provisioning
## edge, the digest check, host `tar`, the store). The archive is a local
## fixture rather than the pinned URL so the test needs no network and stays
## deterministic. It is a `tar.gz`, not the arm's `tar.zst`, because the
## `tar.zst` arm needs a provisioned `zstd` extractor edge, and what is under
## test is the layout the arm's `stripComponents` / `prunePaths` produce, which
## the compression does not change. The arm's own layout fields are copied
## from the registered declaration, so a change to them is what this tests.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_project_dsl
import repro_tool_profiles
import repro_dsl_stdlib/openssl_layout
# Imported for its REGISTRATION side effect: `package `zstd-dev`:` is what puts
# the catalog entry into the DSL registry that `zstdDevPackage()` reads back.
{.push warning[UnusedImport]: off.}
import repro_dsl_stdlib/packages/zstd_dev
{.pop.}

const
  PinnedUrl = "https://repo.msys2.org/mingw/ucrt64/" &
    "mingw-w64-ucrt-x86_64-zstd-1.5.7-2-any.pkg.tar.zst"
  PinnedSha256 =
    "dbdb8427280046a2b41697780aa4c52983b708082b0da4755951dc3bea96ca89"
    ## Measured 2026-11-11 by downloading `PinnedUrl`.

proc zstdDevPackage(): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == "zstd-dev":
      return pkg
  raise newException(ValueError,
    "the zstd-dev catalog entry did not register a package")

proc windowsArms(): seq[TarballProvisioningDef] =
  for entry in zstdDevPackage().tarballProvisioning:
    if entry.os.toLowerAscii == "windows":
      result.add(entry)

proc writeFixtureFile(path, content: string) =
  createDir(path.parentDir)
  writeFile(path, content)

proc buildMsys2ShapedArchive(root: string): string =
  ## A `tar.gz` with the member layout of
  ## `mingw-w64-ucrt-x86_64-zstd-1.5.7-2-any.pkg.tar.zst` (listed 2026-11-11):
  ## pacman's metadata files at the top level beside one `ucrt64/` tree.
  let source = root / "source"
  for name in [".BUILDINFO", ".MTREE", ".PKGINFO"]:
    writeFixtureFile(source / name, "pacman metadata")
  let tree = source / "ucrt64"
  for name in ["bin/libzstd.dll", "bin/zstd.exe", "bin/pzstd.exe",
               "include/zstd.h", "include/zdict.h", "include/zstd_errors.h",
               "lib/libzstd.a", "lib/libzstd.dll.a",
               "lib/cmake/zstd/zstdConfig.cmake",
               "lib/cmake/zstd/zstdTargets-release.cmake",
               "lib/pkgconfig/libzstd.pc",
               "share/licenses/zstd/LICENSE"]:
    writeFixtureFile(tree / name, "fixture " & name)
  result = root / "zstd-dev-fixture.tar.gz"
  let tar = findExe("tar")
  doAssert tar.len > 0, "tar is required to build the fixture archive"
  # Members listed explicitly: `.` would add a leading `./` component and
  # change what `--strip-components=1` removes.
  let packed = execCmdEx(quoteShell(tar) & " -czf " & quoteShell(result) &
    " -C " & quoteShell(source) & " .BUILDINFO .MTREE .PKGINFO ucrt64")
  doAssert packed.exitCode == 0, packed.output

suite "zstd-dev declares a Windows arm with a library on LIBRARY_PATH":

  test "the Windows arm is pinned to the MSYS2 UCRT64 package and hashed":
    let arms = windowsArms()
    check arms.len == 1
    let arm = arms[0]
    check arm.cpu == "x86_64"
    check arm.url == PinnedUrl
    check arm.sha256 == PinnedSha256
    check arm.sha256 in arm.lockIdentity
    check arm.archiveType == "tar.zst"
    check arm.detail.version == "1.5.7"
    # The header is the declared member, so resolution refuses a realization
    # that cannot supply it (packages/zstd_dev.nim, "Provisioning channel").
    check arm.executablePath == "include/zstd.h"
    check arm.stripComponents == 1
    for pruned in ["bin", "lib/libzstd.dll.a", "lib/cmake"]:
      checkpoint("prune: " & pruned)
      check pruned in arm.prunePaths

suite "the realized Windows prefix exposes the header and a static library":

  setup:
    let savedCache = getEnv("REPRO_CACHE_DISABLE")
    putEnv("REPRO_CACHE_DISABLE", "1")

  teardown:
    if savedCache.len > 0: putEnv("REPRO_CACHE_DISABLE", savedCache)
    else: delEnv("REPRO_CACHE_DISABLE")

  test "CPATH gets include/, LIBRARY_PATH gets lib/, and -lzstd binds libzstd.a":
    let arm = windowsArms()[0]
    let root = createTempDir("repro-zstd-dev-windows-", "")
    defer: removeDir(root)
    let archive = buildMsys2ShapedArchive(root)
    # The arm's own layout declaration, on a local archive of the same shape.
    let record = InterfaceTarballProvisioning(url: "file://" & archive,
      sha256: fileSha256Hex(archive), archiveType: "tar.gz",
      executablePath: arm.executablePath,
      stripComponents: arm.stripComponents, prunePaths: arm.prunePaths,
      cpu: "any", os: "any", packageId: "zstd-dev-fixture@1.5.7")
    let useDef = InterfaceToolUse(rawConstraint: "zstd-dev",
      packageSelector: "zstd-dev", executableName: "zstd-dev",
      tarballProvisioning: @[record])
    let profile = resolveTarballTool(useDef, root / "store")
    let prefix = profile.selectedStorePath
    checkpoint("prefix: " & prefix)

    check fileExists(prefix / "include" / "zstd.h")
    check fileExists(prefix / "lib" / "libzstd.a")
    check fileExists(prefix / "lib" / "pkgconfig" / "libzstd.pc")
    # Stripped: pacman's metadata had one component and is gone with it.
    check not fileExists(prefix / ".PKGINFO")
    check not dirExists(prefix / "ucrt64")
    # Pruned: no DLL, no DLL-importing zstd.exe to shadow the `zstd` package
    # on PATH, no CMake config naming the pruned files.
    check not dirExists(prefix / "bin")
    check not dirExists(prefix / "lib" / "cmake")

    check profile.cpathList == @[absolutePath(prefix / "include")]
    check profile.libraryPathList == @[absolutePath(prefix / "lib")]

    # Of every name `ld` accepts for `-lzstd` on PE, only the static archive
    # is present.
    let present = linkLibraryCandidates("zstd").filterIt(
      fileExists(prefix / "lib" / it))
    check present == @["libzstd.a"]
