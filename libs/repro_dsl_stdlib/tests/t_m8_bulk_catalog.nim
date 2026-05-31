## M8 bulk-harvest catalog test.
##
## Imports every M8-harvested ``packages/<tool>Catalog`` and asserts:
##
##   * ``nim check`` succeeds (implicit — the import itself fails to
##     compile if the file is malformed);
##   * ``validateCatalog`` returns no errors (every slice is well-
##     formed: at least one platform, one sha256/sha512, non-empty
##     ``bin_relpath`` for ``imExtract`` records, etc.);
##   * the catalog seq is non-empty;
##   * ``selectDefault`` returns a populated entry whose ``version``
##     non-empty;
##   * the operator-facing registry key (``gcc-winlibs`` /
##     ``llvm-mingw``) resolves via ``getCatalog`` and returns the
##     expected non-empty slice (catches a missing arm in
##     ``catalog_registry.nim``).
##
## Scope per the M8 spec section's in-scope table (operator-extended):
##
##   | Tool       | Source                                       | Status |
##   |------------+----------------------------------------------+--------|
##   | ocaml      | msys2:mingw64/ocaml                          | landed in M6 — t_m6_msys2_source.nim covers it |
##   | dune       | (not in MSYS2)                               | PERMANENTLY DEFERRED |
##   | alire      | gh-releases:alire-project/alire              | landed in M7 — t_m7_gh_releases_source.nim covers it |
##   | gcc-winlibs| gh-releases:brechtsanders/winlibs_mingw      | NEW IN M8 |
##   | llvm-mingw | gh-releases:mstorsjo/llvm-mingw              | NEW IN M8 |
##   | sevenzip   | scoop:ScoopInstaller/Main/7zip               | RE-HARVESTED IN M8 (replaced M3 hand-author) |
##
## ``ocaml`` and ``alire`` are NOT walked here — they have their own
## per-source tests in ``tools/catalog-harvester/tests/`` and are
## re-validated transitively when the M71 e2e suite walks the
## ``Phase2GraduatedToBuiltin`` array.
##
## **M8 sevenzip MSI re-harvest** (operator-directed, folded into this
## milestone): the M3 hand-authored ``sevenzip.nim`` (standalone
## 7zr.exe renamed to ``bin/7z.exe``) was REPLACED with the harvested
## Scoop ``7zip`` manifest. The MSI ships the full distribution
## (CLI + GUI + plugins including the zstd codec — closes a follow-up
## from M6). ``discoverSevenZipExe`` was extended to ALSO probe
## ``<prefix>/7z.exe`` at the root (the MSI shape after lessmsi
## flattens ``Files\7-Zip``); the ``<prefix>/bin/7z.exe`` probe stays
## for backwards-compat with the M3 synthetic test seeds.
##
## **gcc coexistence note**: the operator now has TWO gcc catalog
## entries — ``gcc`` (M68, nuwen.net components-20.0 via Scoop, no
## gfortran) and ``gcc-winlibs`` (M8, brechtsanders/winlibs_mingw with
## gfortran). Both registry keys are distinct, both share the same
## packages_schema, and a home.nim listing ``package(gcc)`` +
## ``package(gcc-winlibs)`` realizes both into separate store prefixes
## without conflict. M11 will decide whether ``gcc-winlibs`` becomes the
## default ``gcc`` post-campaign.

import std/[options, strutils, unittest]
import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/catalog_registry

# The harvested files all re-export ``packages_schema`` so importing
# any one of them brings the enum literals and validators into scope.
import repro_dsl_stdlib/packages/gcc_winlibs
import repro_dsl_stdlib/packages/llvm_mingw
import repro_dsl_stdlib/packages/sevenzip

type
  CatalogUnderTest = object
    name: string                ## operator-facing registry key
    entries: seq[VersionedProvisioning]

proc allCatalogs(): seq[CatalogUnderTest] =
  result.add(CatalogUnderTest(name: "gcc-winlibs", entries: gcc_winlibsCatalog))
  result.add(CatalogUnderTest(name: "llvm-mingw",  entries: llvm_mingwCatalog))
  result.add(CatalogUnderTest(name: "7zip",        entries: sevenzipCatalog))

suite "M8 — bulk-harvested catalog validates":

  test "every harvested catalog is non-empty":
    for c in allCatalogs():
      check c.entries.len > 0
      if c.entries.len == 0:
        echo "EMPTY catalog: " & c.name

  test "validateCatalog returns no errors for any harvested file":
    var failures: seq[string] = @[]
    for c in allCatalogs():
      let errors = validateCatalog(c.entries)
      if errors.len > 0:
        for err in errors:
          failures.add(c.name & ": " & err)
    if failures.len > 0:
      for f in failures: echo f
    check failures.len == 0

  test "selectDefault returns a populated entry per catalog":
    for c in allCatalogs():
      let (found, entry) = selectDefault(c.entries)
      check found
      check entry.version.len > 0
      check entry.platforms.len > 0

  test "every default entry has at least one bin_relpath":
    for c in allCatalogs():
      let (found, entry) = selectDefault(c.entries)
      check found
      check entry.bin_relpath.len > 0
      if entry.bin_relpath.len == 0:
        echo "NO BIN: " & c.name & " v" & entry.version

  test "no platform has both sha256 and sha512":
    for c in allCatalogs():
      for vp in c.entries:
        for pb in vp.platforms:
          check not (pb.sha256.len > 0 and pb.sha512.len > 0)

  test "all M8 catalogs declare a Windows platform slice":
    ## The M8 bulk-harvest pass is Windows-focused (winlibs gcc is
    ## Windows-only by definition; llvm-mingw harvested the
    ## ucrt-x86_64 zip explicitly). Every harvested catalog must
    ## expose at least one ``poWindows`` slice.
    for c in allCatalogs():
      for vp in c.entries:
        var sawWindows = false
        for pb in vp.platforms:
          if pb.os == poWindows: sawWindows = true
        check sawWindows
        if not sawWindows:
          echo "NO WINDOWS: " & c.name & " v" & vp.version

  test "default versions are non-empty version-shaped strings":
    ## Winlibs uses dash-heavy multi-component versions
    ## (``16.1.0posix-14.0.0-ucrt-r2``); llvm-mingw uses a YYYYMMDD
    ## datestamp (``20260519``). The check is loose: at minimum the
    ## version must contain a digit.
    for c in allCatalogs():
      let (found, entry) = selectDefault(c.entries)
      check found
      var sawDigit = false
      for ch in entry.version:
        if ch in {'0' .. '9'}: sawDigit = true
      check sawDigit
      if not sawDigit:
        echo "NO DIGIT: " & c.name & " version='" & entry.version & "'"

  test "every M8 catalog is registered in catalog_registry":
    ## The bulk-validation entry point: catches a missing
    ## ``of "<key>": selectIfNonEmpty(<tool>Catalog)`` arm in
    ## ``catalog_registry.nim``. Without this guard a fresh catalog
    ## file would be byte-equal-emit-clean and still unreachable from
    ## the resolver chain.
    for c in allCatalogs():
      check isRegistered(c.name)
      let resolved = getCatalog(c.name)
      check resolved.isSome
      if resolved.isSome:
        check resolved.get.len == c.entries.len

  test "gcc-winlibs entry bundles gfortran (winlibs's distinguishing trait)":
    ## The whole reason for a separate ``gcc-winlibs`` entry alongside
    ## the M68 ``gcc`` (nuwen.net components-20.0) is that winlibs
    ## bundles a Fortran front-end while nuwen doesn't. Guard the
    ## bin_relpath against an accidental re-harvest that drops it.
    let (found, entry) = selectDefault(gcc_winlibsCatalog)
    check found
    var sawGfortran = false
    for relpath in entry.bin_relpath:
      if relpath.endsWith("gfortran.exe"):
        sawGfortran = true
        break
    check sawGfortran

  test "llvm-mingw entry exposes clang + lld (no shared MinGW gcc)":
    ## Guard against a drift where the harvest accidentally pulls the
    ## winlibs gcc+clang bundle (which doesn't exist in the
    ## mstorsjo/llvm-mingw repo, but a future harvest could mix
    ## sources). The llvm-mingw entry MUST expose clang.exe and the
    ## lld linker.
    let (found, entry) = selectDefault(llvm_mingwCatalog)
    check found
    var sawClang = false
    var sawLld = false
    for relpath in entry.bin_relpath:
      if relpath.endsWith("clang.exe"): sawClang = true
      if relpath.endsWith("ld.lld.exe") or relpath.endsWith("lld.exe"):
        sawLld = true
    check sawClang
    check sawLld

  test "sevenzip entry is the M8 Scoop-MSI re-harvest (root-level 7z.exe)":
    ## Guard the M8 sevenzip swap: the catalog is now the harvested
    ## Scoop ``7zip`` MSI shape, not the M3 hand-authored
    ## standalone-7zr trick. Assertions:
    ##   - install method is imInstallerMsi (M3 was imExtract);
    ##   - bin_relpath is root-level ``7z.exe`` (M3 was ``bin/7z.exe``)
    ##     — confirms the discoverSevenZipExe extension is exercised;
    ##   - Scoop bucket provenance is preserved in the file header.
    let (found, entry) = selectDefault(sevenzipCatalog)
    check found
    check entry.install_method == imInstallerMsi
    check entry.archive_format == afInstallerMsi
    var sawRoot7z = false
    for relpath in entry.bin_relpath:
      # M8 MSI shape: ``7z.exe`` at the root, no leading ``bin/``.
      if relpath == "7z.exe": sawRoot7z = true
    check sawRoot7z
    # The MSI ships the full distribution including the zstd codec —
    # closes a long-standing M6 follow-up. We can't assert the codec
    # presence at catalog-time (it's a realize-time artifact) but we
    # CAN assert the catalog points at the canonical Scoop manifest.
    var sawCanonicalUrl = false
    for vp in sevenzipCatalog:
      for pb in vp.platforms:
        if pb.url.contains("ip7z/7zip/releases") and
           pb.url.endsWith(".msi"):
          sawCanonicalUrl = true
    check sawCanonicalUrl
