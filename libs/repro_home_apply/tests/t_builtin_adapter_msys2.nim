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
##
## W13 adds two cases that drive discovery step (iii) — the ``zekZstdPipe``
## arm — against the same fixture, by CONSTRUCTING the extractor record rather
## than discovering it. Discovery reaches that arm only on a host with bare
## ``zstd`` + ``tar`` and no zstd-capable ``7z``/``tar``, so the arm carried a
## shell-assuming ``zstd … | tar …`` command string that no test ever ran:
##
##   * test_m6_zstd_pipe_arm_extracts_real_bytes_without_a_shell
##   * test_m6_zstd_pipe_arm_reports_a_corrupt_archive_loudly

import std/[os, strutils, tempfiles, unittest]
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

  test "test_m6_zstd_pipe_arm_extracts_real_bytes_without_a_shell":
    ## W13 — discovery step (iii), the ``zekZstdPipe`` arm, FORCED and driven
    ## against the real checked-in ``.tar.zst``.
    ##
    ## The arm used to build ``zstd -dc <archive> | tar -xf - -C <dest>`` as ONE
    ## command string for ``execCmdEx``, under a comment asserting that
    ## "``execCmdEx`` runs through cmd.exe on Windows, which honors ``|``
    ## natively". No ``cmd.exe`` is in that path: ``execCmdEx`` adds
    ## ``poEvalCommand`` and Windows ``startProcess`` hands the line to
    ## ``CreateProcessW`` VERBATIM, so ``|``, the tar path and its three
    ## arguments all arrived as ARGV to ``zstd`` and nothing was ever extracted.
    ## The pipe is now connected in-process, with no shell on either platform.
    ##
    ## FORCED rather than discovered: ``discoverZstdExtractor`` reaches step
    ## (iii) only on a host with bare ``zstd`` + ``tar`` and no zstd-capable
    ## ``7z``/``tar``, so on most hosts — including this one, which has a
    ## zstd-capable ``7z`` — a discovery-driven test would silently assert some
    ## OTHER arm. Constructing the record by hand is the only way to make the
    ## claim about the arm the milestone is about.
    ##
    ## It asserts EXTRACTION, not argv shape: the files the archive carries are
    ## on disk afterwards with their real contents. A test that only checked
    ## that no ``|`` reaches a command line would pass against an extractor
    ## that spawns nothing at all.
    ##
    ## Falsifiability: restore the single-command-string form and on Windows
    ## the first two checks fail (``zstd`` rejects the extra arguments, tar
    ## never runs, and ``raiseExtractFailed`` fires instead) — measured. Break
    ## the copy loop (write nothing into tar's stdin) and ``tar`` exits with an
    ## empty-archive error, so the raise-free assertion fails. Point the
    ## extractor at the archive without decompressing and the CONTENT checks
    ## fail rather than the existence ones.
    let zstdExe = findExe("zstd")
    let tarExe = findExe("tar")
    # Anchor on THIS source file, not the process working directory: the
    # fixture is an input and the cwd is not one (the Class-A trap).
    let fixtureArchive = currentSourcePath().parentDir /
      "fixtures" / "m6" / "mingw-w64-x86_64-fake-tool-1.0.0-1-any.pkg.tar.zst"
    if zstdExe.len == 0 or tarExe.len == 0:
      echo "  [skip] this arm needs BOTH a bare `zstd` and a `tar` on PATH" &
        " (zstd=" & zstdExe & " tar=" & tarExe & ")"
      skip()
    elif not fileExists(extendedPath(fixtureArchive)):
      echo "  [skip] M6 fixture archive missing: " & fixtureArchive
      skip()
    else:
      let destDir = createTempDir("m6-zstd-pipe-", "")
      defer: removeDir(extendedPath(destDir))
      let extractor = ZstdExtractor(kind: zekZstdPipe,
        zstdExe: zstdExe, tarExeForPipe: tarExe)
      var raisedWith = ""
      try:
        extractTarZst("m6-zstd-pipe", fixtureArchive, destDir, extractor)
      except EBuiltinExtractFailed as err:
        raisedWith = err.msg
      if raisedWith.len > 0:
        checkpoint("extractTarZst raised: " & raisedWith)
      check raisedWith.len == 0
      # The archive's own entries, on disk, with their real bytes. No flatten
      # happens here (``flattenExtractPath`` is a separate step), so the
      # ``mingw64/`` husk the tarball carries is still the top level.
      let binPath = destDir / "mingw64" / "bin" / "fake-tool.exe"
      let dataPath = destDir / "mingw64" / "lib" / "fake-tool" / "data.txt"
      let pkgInfoPath = destDir / ".PKGINFO"
      check fileExists(extendedPath(binPath))
      check fileExists(extendedPath(dataPath))
      check fileExists(extendedPath(pkgInfoPath))
      check readFile(extendedPath(binPath)).contains(
        "stub-fake-tool-binary-payload")
      check readFile(extendedPath(dataPath)).contains(
        "stub fixture lib payload")
      check readFile(extendedPath(pkgInfoPath)).contains(
        "mingw-w64-x86_64-fake-tool")

  test "test_m6_zstd_pipe_arm_reports_a_corrupt_archive_loudly":
    ## The other half of the arm: a file that is NOT zstd must fail closed with
    ## the structured extractor error, naming the package and carrying both
    ## children's evidence — not silently produce an empty prefix. Without this
    ## case the arm above would be satisfied by an extractor that could not
    ## distinguish success from failure at all.
    ##
    ## Falsifiability: make the arm ignore the children's exit codes and this
    ## case's ``raised`` check fails.
    let zstdExe = findExe("zstd")
    let tarExe = findExe("tar")
    if zstdExe.len == 0 or tarExe.len == 0:
      echo "  [skip] this arm needs BOTH a bare `zstd` and a `tar` on PATH"
      skip()
    else:
      let scratch = createTempDir("m6-zstd-pipe-bad-", "")
      defer: removeDir(extendedPath(scratch))
      let bogus = scratch / "not-really-zstd.tar.zst"
      writeFile(extendedPath(bogus), "this is not a zstd frame\n")
      let destDir = scratch / "dest"
      let extractor = ZstdExtractor(kind: zekZstdPipe,
        zstdExe: zstdExe, tarExeForPipe: tarExe)
      var raised = false
      var message = ""
      var reportedPackage = ""
      try:
        extractTarZst("m6-bogus-zstd", bogus, destDir, extractor)
      except EBuiltinExtractFailed as err:
        raised = true
        message = err.msg
        reportedPackage = err.packageId
      checkpoint("corrupt-archive message: " & message)
      check raised
      check reportedPackage == "m6-bogus-zstd"
      # The diagnostic must say WHICH child failed and what it said, or an
      # operator is left with "extraction failed" and nothing to act on.
      check "zstd exit=" in message
      check "tar exit=" in message
      check "byte(s) piped" in message
