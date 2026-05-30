## M67 bulk-harvest catalog test.
##
## Imports every M67-harvested ``packages/<tool>Catalog`` and asserts:
##
##   * ``nim check`` succeeds (implicit — the import itself fails to
##     compile if the file is malformed);
##   * ``validateCatalog`` returns no errors (every slice is well-
##     formed: at least one platform, one sha256/sha512, non-empty
##     ``bin_relpath`` for ``imExtract`` records, etc.);
##   * the catalog seq is non-empty;
##   * ``selectDefault`` returns a populated entry whose ``version``
##     non-empty.
##
## The list of catalogs walked here is the M67 bulk-harvest result.
## Tools deferred by M67 (ocaml/dune via msys2-pacman, bundler via
## source-bootstrap, fpc/gnat for hash-algo + scoop-availability
## reasons — see the M67 hand-off report) are NOT in this list; they
## land in later milestones.
##
## ``jdk`` continues to live under its existing M63 reference file
## (``packages/jdk.nim``) which co-hosts the M21 Nix ``package``
## block + the M63 hand-written ``jdkCatalog``. M67 does NOT re-emit
## it (the harvester would clobber the Nix block); the existing
## ``t_versioned_provisioning_schema.nim`` already exercises the jdk
## entry, so this M67 test focuses on the bulk-harvested twelve.
##
## **Known M69 realize-time gaps** (catalog passes ``validateCatalog``
## but the M64 ``cakBuiltin`` adapter cannot realize the prefix as-is;
## these tools need follow-up provisioning logic in M69 / a future M
## before ``repro home apply`` will succeed for them):
##
##   * ``swift`` — manifest URL is a ``.exe`` MSI installer. The
##     harvester records ``afRaw + imExtract`` (the format sniffer
##     can't tell NSIS from MSI from the ``.exe`` extension alone);
##     the upstream Scoop pre_install runs ``Expand-DarkArchive`` to
##     flatten the MSI into ``Toolchains/`` + ``Runtimes/``. cakBuiltin
##     would deposit the raw .exe at the prefix root — ``bin_relpath``
##     entries will not resolve. M69 needs an MSI-flatten hook.
##   * ``composer`` — ``bin_relpath = @["composer.ps1"]`` but the
##     manifest fetches a ``.phar`` and Scoop's pre_install generates
##     the ``.ps1`` shim. cakBuiltin produces no ``composer.ps1``.
##     M69 needs a generic launcher-emit hook OR the catalog needs to
##     point at ``composer.phar`` directly.
##   * ``ruby`` / ``erlang`` — ``afSevenZip`` archives; the M64
##     cakBuiltin raises ``EBuiltinExtractFailed`` (no 7z dispatch).
##     M69 (or a follow-up M) must add a 7z extractor.
##
## These are EXPECTED for the M49–M62 toolchains and were called out
## up front in the M67 review (scrutiny C/D/E). The catalog files
## record the manifest truthfully — the realization gap belongs to
## M69, not M67.

import std/[strutils, unittest]
import repro_dsl_stdlib/packages_schema

# The harvested files all re-export ``packages_schema`` so importing
# any one of them brings the enum literals and validators into scope.
import repro_dsl_stdlib/packages/cabal
import repro_dsl_stdlib/packages/composer
import repro_dsl_stdlib/packages/crystal
import repro_dsl_stdlib/packages/elixir
import repro_dsl_stdlib/packages/erlang
import repro_dsl_stdlib/packages/ghc
import repro_dsl_stdlib/packages/gradle
import repro_dsl_stdlib/packages/maven
import repro_dsl_stdlib/packages/php
import repro_dsl_stdlib/packages/ruby
import repro_dsl_stdlib/packages/swift
import repro_dsl_stdlib/packages/zig

# (jdk re-validated by t_versioned_provisioning_schema.nim — the
# M63 reference; not re-emitted by M67.)

type
  CatalogUnderTest = object
    name: string
    entries: seq[VersionedProvisioning]

proc allCatalogs(): seq[CatalogUnderTest] =
  result.add(CatalogUnderTest(name: "cabal",    entries: cabalCatalog))
  result.add(CatalogUnderTest(name: "composer", entries: composerCatalog))
  result.add(CatalogUnderTest(name: "crystal",  entries: crystalCatalog))
  result.add(CatalogUnderTest(name: "elixir",   entries: elixirCatalog))
  result.add(CatalogUnderTest(name: "erlang",   entries: erlangCatalog))
  result.add(CatalogUnderTest(name: "ghc",      entries: ghcCatalog))
  result.add(CatalogUnderTest(name: "gradle",   entries: gradleCatalog))
  result.add(CatalogUnderTest(name: "maven",    entries: mavenCatalog))
  result.add(CatalogUnderTest(name: "php",      entries: phpCatalog))
  result.add(CatalogUnderTest(name: "ruby",     entries: rubyCatalog))
  result.add(CatalogUnderTest(name: "swift",    entries: swiftCatalog))
  result.add(CatalogUnderTest(name: "zig",      entries: zigCatalog))

suite "M67 — bulk-harvested catalog validates":

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
    ## imExtract and imInstallerSilent records require bin_relpath
    ## entries downstream. Catch silent regressions where a re-harvest
    ## drops the synthesized bin list.
    for c in allCatalogs():
      let (found, entry) = selectDefault(c.entries)
      check found
      check entry.bin_relpath.len > 0
      if entry.bin_relpath.len == 0:
        echo "NO BIN: " & c.name & " v" & entry.version

  test "no platform has both sha256 and sha512":
    ## A guard against a future harvester change that accidentally
    ## emits both digests; ``validateCatalog`` already catches this,
    ## but a targeted assert keeps the failure crisp.
    for c in allCatalogs():
      for vp in c.entries:
        for pb in vp.platforms:
          check not (pb.sha256.len > 0 and pb.sha512.len > 0)

  test "all M67 catalogs declare a Windows platform slice":
    ## The M67 campaign is Windows-focused (M49-M62 only ran on
    ## Windows). Every harvested catalog must expose at least one
    ## ``poWindows`` slice.
    for c in allCatalogs():
      for vp in c.entries:
        var sawWindows = false
        for pb in vp.platforms:
          if pb.os == poWindows: sawWindows = true
        check sawWindows
        if not sawWindows:
          echo "NO WINDOWS: " & c.name & " v" & vp.version
