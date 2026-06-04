## M6 (Realize-Closure-And-Catalog-Expansion spec) hermetic tests for
## the MSYS2 pacman harvester source.
##
## The tests reuse the synthetic fixture under
## ``tests/fixtures/msys2/`` and route every HTTP fetch through the
## ``REPRO_M6_INDEX_FIXTURE_DIR`` mock that ``msys2_source.fetchUrlToString``
## / ``fetchUrlToFile`` consult. Each test exercises a different facet
## of the harvester pipeline:
##
##   * ``test_msys2_source_parses_synthetic_index`` covers the
##     directory-listing parser + the package filename decomposition
##     + latest-version selection;
##   * ``test_msys2_source_emits_valid_versioned_provisioning`` covers
##     the end-to-end harvest (download + sha256 + tar list + bin
##     synthesis) into a schema-valid ``VersionedProvisioning``;
##   * ``test_msys2_source_idempotent_re_harvest`` covers byte-
##     identical re-harvest against the same fixture (the M6 spec's
##     idempotence requirement);
##   * ``test_msys2_source_missing_package_fails_typed`` covers the
##     diagnostic shape when the requested package isn't in the index.

import std/[os, strutils, unittest]

import ../src/msys2_source
import ../src/nim_emit
import repro_dsl_stdlib/packages_schema

const FixtureDir = currentSourcePath.parentDir / "fixtures" / "msys2"

# Per-test scratch cache so the .pkg.tar.zst download doesn't leak
# between tests.
proc setupFixtureEnv(cacheSubdir: string): string =
  putEnv("REPRO_M6_INDEX_FIXTURE_DIR", FixtureDir)
  let cache = getTempDir() / "m6-msys2-test-cache" / cacheSubdir
  if dirExists(cache):
    removeDir(cache)
  createDir(cache)
  cache

proc teardownFixtureEnv() =
  putEnv("REPRO_M6_INDEX_FIXTURE_DIR", "")

suite "M6 — MSYS2 pacman harvester source (hermetic)":

  test "test_msys2_source_parses_synthetic_index":
    discard setupFixtureEnv("parse-index")
    defer: teardownFixtureEnv()
    let leafs = listIndexFilenames(meMingw64)
    # The fixture's index.html lists three .pkg.tar.zst files; the
    # parser MUST surface all three regardless of insertion order.
    check leafs.len == 3
    check "mingw-w64-x86_64-test-tool-0.9.0-1-any.pkg.tar.zst" in leafs
    check "mingw-w64-x86_64-test-tool-1.0.0-1-any.pkg.tar.zst" in leafs
    check "mingw-w64-x86_64-other-package-2.5.0-3-any.pkg.tar.zst" in leafs

  test "test_msys2_source_parses_pkg_filename":
    let p = parsePkgFilename(meMingw64,
      "mingw-w64-x86_64-test-tool-1.0.0-1-any.pkg.tar.zst")
    check p.ok
    check p.fullName == "mingw-w64-x86_64-test-tool"
    check p.version == "1.0.0"
    check p.rel == "1"
    check p.arch == "any"
    # Non-matching env prefix → discard.
    let q = parsePkgFilename(meUcrt64,
      "mingw-w64-x86_64-test-tool-1.0.0-1-any.pkg.tar.zst")
    check (not q.ok)
    # Malformed name (no version segment) → discard.
    let r = parsePkgFilename(meMingw64, "garbage.pkg.tar.zst")
    check (not r.ok)

  test "test_msys2_source_resolves_latest_version":
    discard setupFixtureEnv("resolve-latest")
    defer: teardownFixtureEnv()
    let p = resolveLatestPackage(meMingw64, "test-tool")
    check p.fullName == "mingw-w64-x86_64-test-tool"
    # 1.0.0 > 0.9.0 — the harvester must pick 1.0.0.
    check p.version == "1.0.0"
    check p.rel == "1"
    check p.url.endsWith("mingw-w64-x86_64-test-tool-1.0.0-1-any.pkg.tar.zst")

  test "test_msys2_source_pins_explicit_version":
    discard setupFixtureEnv("pin-version")
    defer: teardownFixtureEnv()
    let p = resolveLatestPackage(meMingw64, "test-tool", versionPin = "0.9.0")
    check p.version == "0.9.0"

  test "test_msys2_source_emits_valid_versioned_provisioning":
    let cache = setupFixtureEnv("emit-vp")
    defer: teardownFixtureEnv()
    let entry = harvestMsys2Package(meMingw64, "test-tool",
      toolName = "test-tool", cacheDir = cache)
    check entry.version == "1.0.0-1"
    check entry.archive_format == afTarZst
    check entry.install_method == imMsys2Pacman
    check entry.bin_relpath == @["bin/test-tool.exe"]
    check entry.platforms.len == 1
    check entry.platforms[0].extract_path == "mingw64"
    check entry.platforms[0].sha256.len == 64
    # sha256 of the fixture file is deterministic per the test fixture.
    check entry.pacman_packages == @["mingw-w64-x86_64-test-tool"]
    let errors = validateVersionedProvisioning(entry)
    check errors.len == 0

  test "test_msys2_source_idempotent_re_harvest":
    let cache1 = setupFixtureEnv("idempotent-1")
    let entry1 = harvestMsys2Package(meMingw64, "test-tool",
      toolName = "test-tool", cacheDir = cache1)
    let body1 = emitCatalogFile("test-tool",
      "msys2:mingw64/test-tool", @[entry1])
    teardownFixtureEnv()
    let cache2 = setupFixtureEnv("idempotent-2")
    let entry2 = harvestMsys2Package(meMingw64, "test-tool",
      toolName = "test-tool", cacheDir = cache2)
    let body2 = emitCatalogFile("test-tool",
      "msys2:mingw64/test-tool", @[entry2])
    teardownFixtureEnv()
    check body1 == body2
    check body1.len > 0

  test "test_msys2_source_missing_package_fails_typed":
    discard setupFixtureEnv("missing")
    defer: teardownFixtureEnv()
    var raised = false
    var detail = ""
    try:
      discard resolveLatestPackage(meMingw64, "nonexistent-tool")
    except Msys2HarvestError as err:
      raised = true
      detail = err.msg
    check raised
    check "nonexistent-tool" in detail

  test "test_msys2_source_other_package_is_isolated":
    # The fixture also lists ``other-package``; harvesting ``test-tool``
    # MUST NOT pick up the other-package filename even though both
    # start with the ``mingw-w64-x86_64-`` prefix.
    discard setupFixtureEnv("isolated")
    defer: teardownFixtureEnv()
    let p = resolveLatestPackage(meMingw64, "test-tool")
    check p.fullName == "mingw-w64-x86_64-test-tool"
    let q = resolveLatestPackage(meMingw64, "other-package")
    check q.fullName == "mingw-w64-x86_64-other-package"
    check q.version == "2.5.0"
