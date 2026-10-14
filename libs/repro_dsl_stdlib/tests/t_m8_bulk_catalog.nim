## GM4b: the M8 ``<tool>Catalog`` records are now ``tarball`` realizations
## of each tool's canonical ``package`` definition (7-Zip's is ``package
## "7zip"``, in ``packages/pkg_7zip.nim``). The properties below are asserted over the records a recipe's
## ``uses:`` and a home profile select from (``realization_checks``); the
## retired catalog's "default entry" is what an unpinned reference selects
## for x86_64-windows. The original M8 notes follow.
##
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
##   * the operator-facing package name (``gcc-winlibs`` /
##     ``llvm-mingw`` / ``7zip``) is a definition the engine links
##     (``package_registry``), so a profile reaches it.
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
##   | 7zip       | scoop:ScoopInstaller/Main/7zip               | RE-HARVESTED IN M8 (replaced M3 hand-author) |
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

import repro_dsl_stdlib/package_registry
import ./realization_checks

const M8Tools = ["gcc-winlibs", "llvm-mingw", "7zip"]

proc defaultOf(name: string): InterfaceTarballProvisioning =
  let picked = unpinnedSelection(name, pcX86_64, poWindows)
  check picked.isSome
  if picked.isSome: picked.get else: InterfaceTarballProvisioning()

proc executablesOf(r: InterfaceTarballProvisioning): seq[string] =
  @[r.executablePath] & r.detail.extraExecutables

suite "M8 — bulk-harvested realizations validate":

  test "every harvested tool has archive realizations":
    for name in M8Tools:
      checkpoint name
      check tarballRecordsOf(name).len > 0

  test "every realization is well-formed":
    var failures: seq[string] = @[]
    for name in M8Tools:
      failures.add(realizationProblems(name))
    for f in failures: echo f
    check failures.len == 0

  test "an unpinned reference selects a versioned record per tool":
    for name in M8Tools:
      checkpoint name
      let r = defaultOf(name)
      check r.detail.version.len > 0
      check r.executablePath.len > 0

  test "no realization carries two digests":
    for name in M8Tools:
      for r in tarballRecordsOf(name):
        check not (r.sha256.len > 0 and r.detail.sha512.len > 0)

  test "all M8 tools keep a Windows realization":
    for name in M8Tools:
      var sawWindows = false
      for r in tarballRecordsOf(name):
        if r.os == "windows": sawWindows = true
      checkpoint name
      check sawWindows

  test "default versions are non-empty version-shaped strings":
    ## Winlibs uses dash-heavy multi-component versions
    ## (``16.1.0posix-14.0.0-ucrt-r2``); llvm-mingw uses a YYYYMMDD
    ## datestamp (``20260519``). At minimum the version contains a digit.
    for name in M8Tools:
      var sawDigit = false
      for ch in defaultOf(name).detail.version:
        if ch in {'0' .. '9'}: sawDigit = true
      checkpoint name
      check sawDigit

  test "every M8 tool is a linked definition":
    ## The bulk-validation entry point: a definition the engine does not
    ## link is unreachable from a home profile however well-formed it is.
    for name in M8Tools:
      checkpoint name
      check isLinkedPackage(name)
      check profileToolUse(name).known

  test "gcc-winlibs entry bundles gfortran (winlibs's distinguishing trait)":
    var sawGfortran = false
    for relpath in executablesOf(defaultOf("gcc-winlibs")):
      if relpath.endsWith("gfortran.exe"):
        sawGfortran = true
    check sawGfortran

  test "llvm-mingw entry exposes clang + lld (no shared MinGW gcc)":
    var sawClang = false
    var sawLld = false
    for relpath in executablesOf(defaultOf("llvm-mingw")):
      if relpath.endsWith("clang.exe"): sawClang = true
      if relpath.endsWith("ld.lld.exe") or relpath.endsWith("lld.exe"):
        sawLld = true
    check sawClang
    check sawLld

  test "7zip entry is the M8 Scoop-MSI re-harvest (root-level 7z.exe)":
    ## Install method is installer-msi, the archive an MSI, the executable
    ## root-level ``7z.exe``, and the URL the canonical upstream release.
    ## An MSI is realized by the home archive realizer.
    let r = defaultOf("7zip")
    check r.detail.installMethod == "installer-msi"
    check r.archiveType == "installer-msi"
    check "7z.exe" in executablesOf(r)
    check archiveRouteFor("7zip", r) == arInstaller
    var sawCanonicalUrl = false
    for rec in tarballRecordsOf("7zip"):
      if rec.url.contains("ip7z/7zip/releases") and rec.url.endsWith(".msi"):
        sawCanonicalUrl = true
    check sawCanonicalUrl
