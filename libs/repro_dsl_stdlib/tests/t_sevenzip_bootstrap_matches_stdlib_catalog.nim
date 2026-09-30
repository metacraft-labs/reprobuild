## The extractor dependency edges realize the same 7-Zip and zstd the stdlib
## catalogs.
##
## A tarball provisioning edge whose archive is a `.7z` / `.7z.exe` depends on
## a 7-Zip provisioning edge, and one whose archive is a `.tar.zst` / `.conda`
## on a zstd provisioning edge (Dependency-Provisioning-In-Build-Graph.md
## section 4), instead of taking whatever `7z` / `zstd` is on `PATH`
## (reprobuild-specs/issues/2026-09-24-tarball-realizer-takes-7z-from-path.md).
## Those edges realize `bootstrapSevenZipToolUse` and `bootstrapZstdToolUse`,
## hand-kept copies of the stdlib entries, because `repro_tool_profiles`
## cannot depend on the stdlib. This pins the copies to the catalog, so
## re-harvesting either package without updating the bootstrap fails here
## rather than leaving two versions of an extractor in the store.

import std/[strutils, unittest]

import repro_project_dsl
import repro_interface_artifacts
import repro_dsl_stdlib/packages/sevenzip
import repro_dsl_stdlib/packages/zstd
import repro_tool_profiles

proc stdlibToolUse(packageName, executableName: string): InterfaceToolUse =
  let iface = toProjectInterface(PackageDef(
    packageName: "extractorPinConsumer",
    nativeBuildDeps: @[PackageUseDef(
      rawConstraint: packageName, packageSelector: packageName,
      executableName: executableName, depKind: "native")]),
    registeredPackages())
  doAssert iface.toolUses.len == 1, "expected one tool use for " & packageName
  iface.toolUses[0]

suite "7-Zip extractor bootstrap":
  test "the bootstrap pins the catalog's Windows x86_64 MSI":
    var catalogUrl, catalogSha256, catalogVersion: string
    for entry in sevenzipCatalog:
      for platform in entry.platforms:
        if platform.os == poWindows and platform.cpu == pcX86_64:
          catalogUrl = platform.url
          catalogSha256 = platform.sha256
          catalogVersion = entry.version
      if catalogUrl.len > 0:
        break
    check catalogUrl.endsWith(".msi")

    let use = bootstrapSevenZipToolUse()
    check use.packageSelector == "7zip@" & catalogVersion
    when defined(windows):
      check use.tarballProvisioning.len == 1
      let arm = use.tarballProvisioning[0]
      check arm.url == catalogUrl
      check arm.sha256 == catalogSha256
      # `msiexec /a` unpacks it with the OS alone; a 7z-format bootstrap
      # would need the extractor it is meant to provide.
      check arm.archiveType == "msi"
      check arm.executablePath == "Files/7-Zip/7z.exe"
    else:
      check use.tarballProvisioning.len == 0

  test "the zstd bootstrap pins the stdlib zstd package":
    let catalog = stdlibToolUse("zstd", "zstd")
    let use = bootstrapZstdToolUse()
    when defined(windows):
      var catalogArm: InterfaceTarballProvisioning
      for arm in catalog.tarballProvisioning:
        if arm.os == "windows" and arm.cpu == "x86_64":
          catalogArm = arm
      check catalogArm.url.len > 0
      check use.tarballProvisioning.len == 1
      let arm = use.tarballProvisioning[0]
      check arm.url == catalogArm.url
      check arm.sha256 == catalogArm.sha256
      check arm.archiveType == catalogArm.archiveType
      check arm.executablePath == catalogArm.executablePath
      check arm.stripComponents == catalogArm.stripComponents
      check use.packageSelector == catalogArm.packageId
      # A zip, which the OS extracts: the extractor needs no extractor.
      check arm.archiveType == "zip"
    else:
      check catalog.nixProvisioning.len > 0
      check use.nixProvisioning.len == 1
      check use.nixProvisioning[0].selector ==
        catalog.nixProvisioning[0].selector
      check use.nixProvisioning[0].executablePath ==
        catalog.nixProvisioning[0].executablePath
