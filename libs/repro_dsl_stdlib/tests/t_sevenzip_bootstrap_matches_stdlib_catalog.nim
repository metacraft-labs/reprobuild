## The extractor bootstrap realizes the same 7-Zip the stdlib catalogs.
##
## `resolveSevenZipExe` realizes 7-Zip into the tool store before it extracts
## a `.7z` / `.7z.exe` archive, instead of taking whatever `7z` is on `PATH`
## (reprobuild-specs/issues/2026-09-24-tarball-realizer-takes-7z-from-path.md:
## on a cold store with no host 7-Zip, git for Windows and the bootstrap gcc
## could not be realized). It does so from `bootstrapSevenZipToolUse`, a
## hand-kept copy of the Windows x86_64 entry of `sevenzipCatalog`, because the
## engine's bootstrap cannot depend on the stdlib. This pins the copy to the
## catalog, so re-harvesting 7-Zip without updating the bootstrap fails here
## rather than leaving two 7-Zips in the store.

import std/[strutils, unittest]

import repro_dsl_stdlib/packages/sevenzip
import repro_tool_profiles

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
