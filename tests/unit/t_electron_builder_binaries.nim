## The three ``electron-builder-binaries`` packages, and why each is shaped
## as it is.
##
## electron-builder resolves four archives from its own cache rather than
## from ``PATH``, so a build whose network is denied needs them provisioned
## and materialised into that cache. Measured on a Windows host: with
## ``ELECTRON_BUILDER_CACHE`` pointed at an empty directory, an MSI build
## downloads ``winCodeSign-2.6.0``, ``wix-4.0.0.5512.2``, ``nsis-3.0.4.1``
## and ``nsis-resources-3.4.1`` — 9.8 MB — and with the directory
## pre-populated it downloads nothing.
##
## ``wix`` was already packaged. These three are the rest, and each carries a
## decision worth pinning down:
##
##   * the NSIS one is NOT the ``nsis`` package. Different publisher,
##     different version, different plugin set;
##   * the resources one has no program in it at all, so it anchors on a
##     DLL — which is why ``.dll`` belongs in the realizer's
##     data-declaration extensions beside ``.so``;
##   * the code-signing one bundles Microsoft's ``signtool`` and must never
##     reach a shared cache, which is a property the package declares rather
##     than a sentence in a comment.

import std/[sequtils, strutils, unittest]

import repro_project_dsl

import repro_dsl_stdlib/packages/wix
import repro_dsl_stdlib/packages/nsis
import repro_dsl_stdlib/packages/electron_builder_nsis
import repro_dsl_stdlib/packages/electron_builder_nsis_resources
import repro_dsl_stdlib/packages/electron_builder_win_code_sign

proc slices(name: string): seq[TarballProvisioningDef] =
  let hits = registeredPackages().filterIt(it.packageName == name)
  doAssert hits.len == 1, "expected one package named " & name
  hits[0].tarballProvisioning

suite "the electron-builder cache entries":
  test "each names the archive electron-builder asks for":
    # The directory name electron-builder looks for is
    # ``<name>-<version>``, and it builds the URL from the same pair, so the
    # tag in the URL is the thing that has to match its constant.
    for (pkg, fragment) in {
      "wix": "wix-4.0.0.5512.2/wix-4.0.0.5512.2.7z",
      "electron-builder-nsis": "nsis-3.0.4.1/nsis-3.0.4.1.7z",
      "electron-builder-nsis-resources":
        "nsis-resources-3.4.1/nsis-resources-3.4.1.7z",
      "electron-builder-win-code-sign":
        "winCodeSign-2.6.0/winCodeSign-2.6.0.7z",
    }:
      let entries = slices(pkg)
      check entries.len == 1
      checkpoint(pkg & " -> " & entries[0].url)
      check entries[0].url.contains(fragment)
      check entries[0].url.startsWith(
        "https://github.com/electron-userland/electron-builder-binaries/")
      check entries[0].archiveType == "7z"
      # Flat archives, all four: the payload sits at the root, so a strip
      # would eat the first real directory.
      check entries[0].stripComponents == 0
      check entries[0].sha256.len == 64

  test "the electron-builder NSIS is not the NSIS package":
    # Both provide makensis and they are not interchangeable: `nsis` pins
    # upstream's own 3.12 from SourceForge, electron-builder wants its
    # repackaged 3.0.4.1 with its own plugins. A recipe that reached for the
    # wrong one would build with a toolchain electron-builder's scripts were
    # not written against.
    let upstream = slices("nsis")
    let vendored = slices("electron-builder-nsis")
    check upstream.len == 1
    check vendored.len == 1
    check upstream[0].url != vendored[0].url
    check upstream[0].sha256 != vendored[0].sha256
    check upstream[0].url.contains("sourceforge")
    check vendored[0].url.contains("electron-builder-binaries")

  test "the resources package anchors on a file, having no program":
    # It is a flat tree of plugin DLLs that makensis LOADS. There is nothing
    # to spawn, so `executablePath` names a file whose presence proves the
    # realization completed — the idiom the header and data packages use.
    let entries = slices("electron-builder-nsis-resources")
    check entries[0].executablePath.endsWith(".dll")
    check entries[0].executablePath.startsWith("plugins/")

  test "the code-signing bundle refuses republication, and only it does":
    # It carries Microsoft's signtool. The other three are redistributable
    # and should be published, because that is what makes a shared cache
    # worth having.
    check slices("electron-builder-win-code-sign")[0].nonRedistributable
    for pkg in ["wix", "electron-builder-nsis",
                "electron-builder-nsis-resources"]:
      checkpoint(pkg)
      check not slices(pkg)[0].nonRedistributable

  test "every entry is Windows x86_64":
    # Each of these exists to satisfy a cache entry on the platform that
    # consumes it. Two of the archives carry darwin and linux payloads for
    # electron-builder's cross-building paths; declaring those platforms
    # would assert coverage nothing here has seen work.
    for pkg in ["wix", "electron-builder-nsis",
                "electron-builder-nsis-resources",
                "electron-builder-win-code-sign"]:
      checkpoint(pkg)
      check slices(pkg)[0].os == "windows"
      check slices(pkg)[0].cpu == "x86_64"
