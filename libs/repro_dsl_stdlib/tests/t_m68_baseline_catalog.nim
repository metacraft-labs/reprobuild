## M68 baseline-catalog test.
##
## Imports every M68-harvested ``packages/<tool>Catalog`` and asserts:
##
##   * ``nim check`` succeeds (implicit — the import itself fails to
##     compile if the file is malformed);
##   * ``validateCatalog`` returns no errors (every slice is well-
##     formed: at least one platform, one sha256/sha512, non-empty
##     ``bin_relpath`` for ``imExtract`` records, etc.);
##   * the catalog seq is non-empty;
##   * ``selectDefault`` returns a populated entry whose ``version``
##     is non-empty.
##
## The list of catalogs walked here is the M68 baseline-tool harvest.
## ``clang`` is DEFERRED — there is no ``clang.json`` in
## ScoopInstaller/Main (only ``clangd.json``); the winlibs / dedicated
## ``ChrisDenton/clang`` buckets fall outside the M68 "main scoop"
## scope. The M70 ``home migrate-from-env-scripts`` synthesizer will
## either pin a hand-curated clang catalog or fall through to the
## host's existing clang install.
##
## **Known M69 realize-time gaps** (catalog passes ``validateCatalog``
## but the M64 ``cakBuiltin`` adapter cannot fully realize the prefix
## as-is; these tools need follow-up provisioning logic in M69 / a
## future M before ``repro home apply`` will succeed for them):
##
##   * ``nim`` — ``post_install`` hook copies
##     ``dist/nimble/src/nimblepkg`` into ``bin/``; ``nimble``
##     invocations from cakBuiltin's prefix will fail to locate the
##     package definitions until M69 wires a post-extract hook runner.
##   * ``git`` — afSevenZip archive (M64 raises
##     ``EBuiltinExtractFailed``) plus ``pre_install`` (restore
##     persisted etc/gitconfig) + ``post_install`` (emit
##     install-context.reg) hooks that cakBuiltin does not run.
##   * ``gcc`` — afSevenZip archive AND a critical ``pre_install``
##     hook that expands nested ``binutils-*.7z`` +
##     ``mingw-w64+gcc.7z`` from inside the outer 7z; without it the
##     realized prefix surfaces no ``bin/gcc.exe``.
##   * ``cmake`` — clean zip, no hooks; should realize cleanly under
##     M64 once afZip support stabilizes. (Originally documented as
##     carrying an ``installer.script: Add-Path`` hook — that hook
##     actually lives in ``nim``'s manifest, not cmake's; correction
##     applied during M68 review.)
##   * ``meson`` — ``afInstallerMsi`` with ``extract_path =
##     PFiles64\\Meson``; M64's afInstallerMsi extractor (if any) must
##     run ``msiexec /a`` administrative-install + flatten the
##     ``PFiles64\\Meson`` subdir.
##   * ``ninja`` — clean zip, no hooks; should realize cleanly under
##     M64 once afZip support stabilizes.
##   * ``node`` — afSevenZip archive + the ``bin/`` prefix in
##     ``bin_relpath`` (synthesized from
##     ``env_add_path = ["bin", "."]``) only exists after Scoop's
##     ``post_install`` runs ``Set-Content`` against
##     ``node_modules/npm/npmrc``. Root-relative entries
##     (``node.exe``, ``npm.cmd``, ``npx.cmd``) resolve on bare
##     extract.
##   * ``python3`` — ``installer.script`` runs Expand-DarkArchive on
##     the ``.exe`` self-extracting MSI bundle. Harvester records
##     ``imExtract + afRaw`` (script-only ``installer`` block treated
##     as a post-extract hook). cakBuiltin would deposit raw
##     ``setup.exe`` at the prefix root without ever extracting it;
##     M69 needs an ``installer.script`` runner OR a
##     ``afSelfExtractingMsi`` archive_format.
##   * ``dotnet_sdk`` — ``env_set`` carries the literal string
##     ``${prefix}\\sdk\\$version\\Sdks`` (Scoop's own ``$version``
##     placeholder is not translated); M69 needs a Scoop-style
##     ``$version`` substitution pass before setting MSBuildSDKsPath.
##   * ``gh`` / ``just`` — clean zips, no hooks; should realize
##     cleanly under M64.
##
## These gaps are EXPECTED and were enumerated up-front in the M68
## hand-off. The catalog files record the manifest truthfully — the
## realization gap belongs to M69, not M68.

import std/[strutils, unittest]
import repro_dsl_stdlib/packages_schema

# The merged + auto-generated files all re-export ``packages_schema``
# so importing any one of them brings the enum literals and validators
# into scope.
import repro_dsl_stdlib/packages/cmake
import repro_dsl_stdlib/packages/dotnet_sdk
import repro_dsl_stdlib/packages/gcc
import repro_dsl_stdlib/packages/gh
import repro_dsl_stdlib/packages/git
import repro_dsl_stdlib/packages/just
import repro_dsl_stdlib/packages/meson
import repro_dsl_stdlib/packages/nim
import repro_dsl_stdlib/packages/ninja
import repro_dsl_stdlib/packages/node
import repro_dsl_stdlib/packages/python3

type
  CatalogUnderTest = object
    name: string
    entries: seq[VersionedProvisioning]

proc allCatalogs(): seq[CatalogUnderTest] =
  result.add(CatalogUnderTest(name: "cmake",      entries: cmakeCatalog))
  result.add(CatalogUnderTest(name: "dotnet-sdk", entries: dotnet_sdkCatalog))
  result.add(CatalogUnderTest(name: "gcc",        entries: gccCatalog))
  result.add(CatalogUnderTest(name: "gh",         entries: ghCatalog))
  result.add(CatalogUnderTest(name: "git",        entries: gitCatalog))
  result.add(CatalogUnderTest(name: "just",       entries: justCatalog))
  result.add(CatalogUnderTest(name: "meson",      entries: mesonCatalog))
  result.add(CatalogUnderTest(name: "nim",        entries: nimCatalog))
  result.add(CatalogUnderTest(name: "ninja",      entries: ninjaCatalog))
  result.add(CatalogUnderTest(name: "node",       entries: nodeCatalog))
  result.add(CatalogUnderTest(name: "python3",    entries: python3Catalog))

suite "M68 — baseline dev-tool catalog validates":

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

  test "all M68 catalogs declare a Windows platform slice":
    ## The M68 baseline harvest is Windows-focused (the env.ps1
    ## deprecation target is also Windows-only — the macOS/Linux side
    ## continues to flow through the Nix branch of the resolver chain).
    ## Every harvested catalog must expose at least one ``poWindows``
    ## slice.
    for c in allCatalogs():
      for vp in c.entries:
        var sawWindows = false
        for pb in vp.platforms:
          if pb.os == poWindows: sawWindows = true
        check sawWindows
        if not sawWindows:
          echo "NO WINDOWS: " & c.name & " v" & vp.version

  test "default versions are non-empty semver-shaped strings":
    ## Soft guard — the M68 spec ties ``defaultVersion`` to the version
    ## ``env.ps1`` currently installs (regression target for the M70
    ## deprecation cut). The version string format is intentionally
    ## loose (e.g. mingw-winlibs uses ``16.1.0-14.0.0-r2``) but it
    ## must at minimum contain a digit.
    for c in allCatalogs():
      let (found, entry) = selectDefault(c.entries)
      check found
      var sawDigit = false
      for ch in entry.version:
        if ch in {'0' .. '9'}: sawDigit = true
      check sawDigit
      if not sawDigit:
        echo "NO DIGIT: " & c.name & " version='" & entry.version & "'"
