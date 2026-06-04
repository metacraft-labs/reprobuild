## M6 (Realize-Closure-And-Catalog-Expansion spec) hermetic tests for
## the cakBuiltin ``imMsys2Pacman`` realize hook + the ``afTarZst``
## extractor discovery.
##
## The fixture ``tests/fixtures/m6/mingw-w64-x86_64-fake-tool-...-any.pkg.tar.zst``
## is a synthetic .pkg.tar.zst built once and checked in. Its payload
## mirrors a real MSYS2 mingw64 package:
##
##   .PKGINFO
##   mingw64/bin/fake-tool.exe
##   mingw64/lib/fake-tool/data.txt
##   mingw64/share/doc/fake-tool/README
##
## Tests load this fixture via a ``file://`` URL and verify:
##
##   * test_m6_extractor_discovery_returns_usable_extractor
##   * test_m6_realize_imMsys2Pacman_extracts_and_flattens
##   * test_m6_realize_imMsys2Pacman_cache_hit_on_re_realize
##   * test_m6_realize_imMsys2Pacman_fails_closed_without_extractor

import std/[os, strutils, unittest]
from repro_core/paths import extendedPath

import repro_local_store
import repro_dsl_stdlib/packages_schema

import repro_home_apply/package_catalog
import repro_home_apply/builtin_adapter

const FixtureRoot = "build/test-tmp/t-builtin-adapter-msys2"
const M6FixtureArchive = "libs/repro_home_apply/tests/fixtures/m6/" &
  "mingw-w64-x86_64-fake-tool-1.0.0-1-any.pkg.tar.zst"

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

proc fileToUrl(absPath: string): string =
  let normalized = absPath.replace('\\', '/')
  when defined(windows):
    if normalized.len >= 2 and normalized[1] == ':':
      "file:///" & normalized
    else:
      "file://" & normalized
  else:
    "file://" & normalized

suite "M6 — cakBuiltin imMsys2Pacman realize hook + afTarZst":

  test "test_m6_extractor_discovery_returns_usable_extractor":
    ## Discovery picks one of the three strategies on the host. We do
    ## NOT assert which one — the test asserts only that the
    ## discoverer returned a usable record, exercising the
    ## prefix-lookup / tar-filter / zstd-pipe walk end-to-end.
    let fixtureDir = FixtureRoot / "discover"
    let storeDir = fixtureDir / "store"
    resetDir(fixtureDir); resetDir(storeDir)
    var store = openStore(storeDir)
    defer: store.close()
    try:
      let extractor = discoverZstdExtractor(store, "m6-test-tool")
      check extractor.kind in {zekSevenZip, zekTarFilter, zekZstdPipe}
    except EBuiltinZstdUnavailable:
      echo "  [skip] host has no zstd-capable extractor (full 7z, " &
        "tar --zstd / bsdtar+libzstd, or zstd)"
      skip()

  test "test_m6_realize_imMsys2Pacman_extracts_and_flattens":
    ## End-to-end realize against the checked-in fixture: the
    ## prefix carries ``bin/fake-tool.exe`` + the sibling
    ## ``lib/fake-tool/data.txt`` (mingw64/ husk flattened).
    if not fileExists(extendedPath(M6FixtureArchive)):
      echo "  [skip] M6 fixture archive missing: " & M6FixtureArchive
      skip()
    else:
      let fixtureDir = FixtureRoot / "realize-flatten"
      let storeDir = fixtureDir / "store"
      resetDir(fixtureDir); resetDir(storeDir)
      let archiveAbs = absolutePath(M6FixtureArchive)
      let sha = fileShaHex(archiveAbs, "sha256")
      var store = openStore(storeDir)
      defer: store.close()
      let vp = initVersionedProvisioning(
        version = "1.0.0-1",
        archive_format = afTarZst,
        install_method = imMsys2Pacman,
        bin_relpath = @["bin/fake-tool.exe"],
        platforms = @[
          initPlatformBinary(
            cpu = detectHostCpu(), os = detectHostOs(),
            url = fileToUrl(archiveAbs),
            sha256 = sha,
            extract_path = "mingw64")
        ],
        pacman_packages = @["mingw-w64-x86_64-fake-tool"])
      let res = resolveBuiltinPackage("fake-tool", @[vp])
      check res.found
      check res.resolution.archiveFormat == afTarZst
      check res.resolution.installMethod == imMsys2Pacman
      var skipFlatten = false
      var outR: RealizeBuiltinResult
      try:
        outR = realizeBuiltinPackage(store, res.resolution)
      except EBuiltinZstdUnavailable:
        echo "  [skip] no zstd extractor available on host"
        skipFlatten = true
      if not skipFlatten:
        check (not outR.cacheHit)
        let realizedBin = outR.prefixAbsolutePath / "bin" / "fake-tool.exe"
        check fileExists(extendedPath(realizedBin))
        check readFile(extendedPath(realizedBin)).contains(
          "stub-fake-tool-binary-payload")
        let realizedData = outR.prefixAbsolutePath / "lib" /
          "fake-tool" / "data.txt"
        check fileExists(extendedPath(realizedData))
        # Inner mingw64/ husk should be gone after flatten.
        check (not dirExists(extendedPath(
          outR.prefixAbsolutePath / "mingw64")))

  test "test_m6_realize_imMsys2Pacman_cache_hit_on_re_realize":
    ## Re-realize against the same prefixId is a cache hit. Mirrors
    ## the M64 cache-hit invariant for the new install_method
    ## dispatch.
    if not fileExists(extendedPath(M6FixtureArchive)):
      echo "  [skip] M6 fixture archive missing"
      skip()
    else:
      let fixtureDir = FixtureRoot / "cache-hit"
      let storeDir = fixtureDir / "store"
      resetDir(fixtureDir); resetDir(storeDir)
      let archiveAbs = absolutePath(M6FixtureArchive)
      let sha = fileShaHex(archiveAbs, "sha256")
      var store = openStore(storeDir)
      defer: store.close()
      let vp = initVersionedProvisioning(
        version = "1.0.0-1",
        archive_format = afTarZst,
        install_method = imMsys2Pacman,
        bin_relpath = @["bin/fake-tool.exe"],
        platforms = @[
          initPlatformBinary(
            cpu = detectHostCpu(), os = detectHostOs(),
            url = fileToUrl(archiveAbs),
            sha256 = sha,
            extract_path = "mingw64")
        ],
        pacman_packages = @["mingw-w64-x86_64-fake-tool"])
      let res = resolveBuiltinPackage("fake-tool", @[vp])
      check res.found
      var skipCache = false
      var first: RealizeBuiltinResult
      try:
        first = realizeBuiltinPackage(store, res.resolution)
      except EBuiltinZstdUnavailable:
        echo "  [skip] no zstd extractor on host"
        skipCache = true
      if not skipCache:
        check (not first.cacheHit)
        let second = realizeBuiltinPackage(store, res.resolution)
        check second.cacheHit
        check second.prefixAbsolutePath == first.prefixAbsolutePath

  test "test_m6_realize_imMsys2Pacman_fails_closed_without_extractor":
    ## Discovery (iv): when no zstd-capable extractor is on PATH AND
    ## no catalog 7zip prefix carries the codec, the realize raises
    ## ``EBuiltinZstdUnavailable`` with a populated discovery trace.
    let fixtureDir = FixtureRoot / "fail-closed"
    let storeDir = fixtureDir / "store"
    resetDir(fixtureDir); resetDir(storeDir)
    let emptyDir = fixtureDir / "empty-path"
    resetDir(emptyDir)
    let savedPath = getEnv("PATH")
    putEnv("PATH", emptyDir)
    defer: putEnv("PATH", savedPath)
    var store = openStore(storeDir)
    defer: store.close()
    var raised = false
    var traceLen = 0
    var pkg = ""
    try:
      discard discoverZstdExtractor(store, "needy-tool")
    except EBuiltinZstdUnavailable as err:
      raised = true
      traceLen = err.discoveryTrace.len
      pkg = err.packageId
    check raised
    check pkg == "needy-tool"
    check traceLen >= 1
