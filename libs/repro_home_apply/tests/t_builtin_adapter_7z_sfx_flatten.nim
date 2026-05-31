## M3 (Realize-Closure-And-Catalog-Expansion spec) —
## ``afSevenZipSfx`` (7z self-extracting) realize-time hook + the
## ``afSevenZip`` regression coverage for the M64-step-12 basic
## extraction path that already shipped (verifies M3's residual surface
## did not regress the prior art).
##
## Hermetic: every fixture is materialized on disk and served via a
## ``file://`` URL. The single non-hermetic dependency is a host
## ``7z.exe`` on PATH (or in a pre-staged ``7zip`` catalog prefix). Per
## the M3 ``discoverSevenZipExe`` contract, the test pre-seeds the
## store with a hand-rolled ``7zip`` prefix that aliases the host's
## ``7z.exe`` so the catalog-prefix branch (Step i) of the discovery
## order is exercised end-to-end alongside the PATH-fallback (Step ii).
## Step (iii) — fail-closed via ``EBuiltinSevenZipUnavailable`` — is
## covered explicitly with a stripped-PATH realize.
##
## Per the M3 honest-scope contract: this test exercises ``git`` (the
## SFX shape) + ``ruby`` (the SFX shape) + ``erlang`` (the M64 basic
## ``afSevenZip`` shape, re-verified). The downstream bundler / install-
## context.reg / NSIS post-install side effects are OUT of M3 scope
## (deferred per the spec's "honest scope" rule); this test only asserts
## that the family hook itself extracts the archive + flattens to a
## prefix tree carrying the declared bin_relpath.

import std/[os, osproc, strutils, tables, unittest]
from repro_core/paths import extendedPath

import repro_local_store
import repro_dsl_stdlib/packages_schema

import repro_home_apply/package_catalog
import repro_home_apply/builtin_adapter

const FixtureRoot = "build/test-tmp/t-builtin-adapter-7z-sfx"

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

proc resolveRealSevenZip(hostExe: string): string =
  ## On Windows + Scoop, ``findExe("7z")`` returns the Scoop shim under
  ## ``scoop/shims/7z.exe`` — the shim needs its sibling ``.shim`` file
  ## to dispatch to the real binary, so naively copying the shim into
  ## the seeded prefix produces "Cannot open shim file for read". When
  ## a sibling ``.shim`` carrying ``path = "<real-7z>.exe"`` is present
  ## next to ``hostExe`` we parse it and return the real path. Otherwise
  ## ``hostExe`` is the real binary already (PATH lookup on a non-Scoop
  ## host) — return as-is.
  let shimSidecar = changeFileExt(hostExe, "shim")
  if not fileExists(extendedPath(shimSidecar)):
    return hostExe
  for line in lines(extendedPath(shimSidecar)):
    let s = line.strip()
    if s.startsWith("path"):
      let eq = s.find('=')
      if eq > 0:
        var value = s[eq + 1 .. ^1].strip()
        if value.startsWith("\"") and value.endsWith("\""):
          value = value[1 ..< value.len - 1]
        if fileExists(extendedPath(value)):
          return value
  hostExe

proc seedSevenZipPrefix(store: var Store; hostSevenZ: string): string =
  ## Pre-populate the store with a ``7zip``-packaged prefix containing
  ## ``bin/7z.exe`` (aliased from the host's discovered 7z). Returns
  ## the abs path of the realized prefix. Drives the M3
  ## ``discoverSevenZipExe`` Step (i) — catalog-prefix lookup —
  ## without actually exercising the cakBuiltin downloader (we want
  ## the test to focus on SFX flatten, not on the 7zip-as-package
  ## bootstrap).
  ##
  ## Uses the same ``realizePrefix`` plumbing the real adapter does, so
  ## the on-disk layout + the ``prefixes`` index row both look identical
  ## to a "real" 7zip realize.
  let prefixId = computeRealizationHash("7zip", "test-seed",
    "builtin", "sha256:seed", "bin/7z.exe", "file:///seed",
    "seed", @["fixture"])
  let hint = StoreReceiptHint(
    adapter: "builtin",
    packageName: "7zip",
    version: "test-seed",
    declaredExecutablePath: "bin/7z.exe",
    exportedExecutables: @["bin/7z.exe"],
    lockIdentity: "sha256:seed",
    provenanceUrl: "file:///seed",
    provenanceChecksum: "sha256:seed",
    materializationMechanism: "raw+extract")
  let realExe = resolveRealSevenZip(hostSevenZ)
  let outcome = realizePrefix(store, prefixId, hint,
    proc (stagingDir: string; mechanism: var string) =
      createDir(extendedPath(stagingDir / "bin"))
      copyFile(extendedPath(realExe),
        extendedPath(stagingDir / "bin" / "7z.exe"))
      # Also copy any sibling DLLs the real 7z.exe needs (7-Zip splits
      # codec support out into 7z.dll). We probe for the DLL next to
      # the real exe and bring it along.
      let realDir = parentDir(realExe)
      let codecsDll = realDir / "7z.dll"
      if fileExists(extendedPath(codecsDll)):
        copyFile(extendedPath(codecsDll),
          extendedPath(stagingDir / "bin" / "7z.dll"))
      mechanism = "copy")
  outcome.absolutePath

suite "M3 — cakBuiltin 7z SFX flatten":

  test "test_m3_discover_sevenzip_finds_catalog_prefix":
    ## M3 ``discoverSevenZipExe`` Step (i): a store-resident 7zip
    ## prefix is preferred over PATH. Pre-seeds a 7zip prefix, then
    ## asserts the discovery returns its bin/7z.exe.
    let fixtureDir = FixtureRoot / "discover-catalog"
    let storeDir = fixtureDir / "store"
    resetDir(fixtureDir); resetDir(storeDir)
    let hostSeven = findExe("7z")
    if hostSeven.len == 0:
      echo "  [skip] no host 7z on PATH; cannot seed the catalog prefix"
      skip()
    else:
      var store = openStore(storeDir)
      defer: store.close()
      let prefixAbs = seedSevenZipPrefix(store, hostSeven)
      check fileExists(extendedPath(prefixAbs / "bin" / "7z.exe"))
      let discovered = discoverSevenZipExe(store, "test-tool")
      check discovered.startsWith(prefixAbs)
      check fileExists(extendedPath(discovered))

  test "test_m3_discover_sevenzip_fails_closed_without_7zip":
    ## M3 ``discoverSevenZipExe`` Step (iii): no catalog prefix + no
    ## PATH 7z → ``EBuiltinSevenZipUnavailable`` carries the discovery
    ## trace + the offending package id.
    let fixtureDir = FixtureRoot / "discover-fail"
    let storeDir = fixtureDir / "store"
    resetDir(fixtureDir); resetDir(storeDir)
    var store = openStore(storeDir)
    defer: store.close()
    let emptyDir = fixtureDir / "empty-path"
    resetDir(emptyDir)
    let savedPath = getEnv("PATH")
    putEnv("PATH", emptyDir)
    defer: putEnv("PATH", savedPath)
    var raised = false
    var traceLen = 0
    var pkg = ""
    try:
      discard discoverSevenZipExe(store, "needy-tool")
    except EBuiltinSevenZipUnavailable as err:
      raised = true
      traceLen = err.discoveryTrace.len
      pkg = err.packageId
    check raised
    check pkg == "needy-tool"
    check traceLen >= 1

  test "test_m3_sfx_flatten_synthetic_git_realizes_bin_git":
    ## Builds a synthetic 7z-SFX archive (a 7z stream concatenated to
    ## a placeholder PE-loader prefix) carrying a stub ``bin/git.exe``
    ## fixture and asserts the realize loop:
    ##   * dispatches ``afSevenZipSfx`` through ``extract7z``;
    ##   * flattens the inner ``PortableGit-stub/`` extract_path;
    ##   * the realized prefix carries ``bin/git.exe`` directly.
    ##
    ## NB the SFX-loader prefix is a synthetic 4-byte marker — the real
    ## Git-for-Windows SFX uses a multi-KB PE stub. The 7z extractor
    ## locates the inner 7z stream by scanning for the 7z signature
    ## bytes so both shapes extract identically. The synthetic marker
    ## keeps the test hermetic + fast.
    let fixtureDir = FixtureRoot / "git-sfx"
    let storeDir = fixtureDir / "store"
    let stagingDir = fixtureDir / "staging"
    resetDir(fixtureDir); resetDir(storeDir); resetDir(stagingDir)

    let hostSeven = findExe("7z")
    if hostSeven.len == 0:
      echo "  [skip] no host 7z on PATH; SFX flatten test needs 7z to build the fixture"
      skip()
    else:
      let innerName = "PortableGit-stub"
      let innerDir = stagingDir / innerName
      createDir(extendedPath(innerDir / "bin"))
      createDir(extendedPath(innerDir / "etc"))
      writeFile(extendedPath(innerDir / "bin" / "git.exe"),
        "stub-git-payload-bytes\n")
      writeFile(extendedPath(innerDir / "etc" / "gitconfig"),
        "# stub system gitconfig\n")
      let plain7z = fixtureDir / "git-plain.7z"
      let addCmd = quoteShell(hostSeven) & " a -t7z " &
        quoteShell(absolutePath(plain7z)) & " " & quoteShell(innerName) &
        " -y -bsp0 -bso0"
      let addRes = execCmdEx(addCmd, workingDir = stagingDir)
      check addRes.exitCode == 0
      check fileExists(extendedPath(plain7z))
      let sfxPath = fixtureDir / "git-sfx.7z.exe"
      let plainBytes = readFile(extendedPath(plain7z))
      writeFile(extendedPath(sfxPath), "MZ\x90\x00" & plainBytes)
      let sha = fileShaHex(sfxPath, "sha256")

      var store = openStore(storeDir)
      defer: store.close()
      discard seedSevenZipPrefix(store, hostSeven)

      let vp = initVersionedProvisioning(
        version = "stub-2.54.0",
        archive_format = afSevenZipSfx,
        install_method = imExtract,
        bin_relpath = @["bin/git.exe"],
        platforms = @[
          initPlatformBinary(
            cpu = detectHostCpu(), os = detectHostOs(),
            url = fileToUrl(absolutePath(sfxPath)),
            sha256 = sha,
            extract_path = innerName)
        ])
      let res = resolveBuiltinPackage("git-sfx", @[vp])
      check res.found
      check res.resolution.archiveFormat == afSevenZipSfx

      let outR = realizeBuiltinPackage(store, res.resolution)
      check (not outR.cacheHit)
      let realizedGit = outR.prefixAbsolutePath / "bin" / "git.exe"
      check fileExists(extendedPath(realizedGit))
      check readFile(extendedPath(realizedGit)).contains("stub-git-payload-bytes")
      check (not dirExists(extendedPath(outR.prefixAbsolutePath / innerName)))

  test "test_m3_basic_7z_still_works_erlang_shape":
    ## Re-verifies the M64-step-12 basic afSevenZip path (no SFX, no
    ## nested, no pre_install). Build a plain .7z carrying erlang-style
    ## bin/erl.exe + bin/erlc.exe stubs and assert realize materializes
    ## both binaries.
    let fixtureDir = FixtureRoot / "erlang-basic"
    let storeDir = fixtureDir / "store"
    let stagingDir = fixtureDir / "staging"
    resetDir(fixtureDir); resetDir(storeDir); resetDir(stagingDir)
    let hostSeven = findExe("7z")
    if hostSeven.len == 0:
      echo "  [skip] no host 7z on PATH"
      skip()
    else:
      let innerDir = stagingDir / "otp-stub-28.5"
      createDir(extendedPath(innerDir / "bin"))
      writeFile(extendedPath(innerDir / "bin" / "erl.exe"),
        "stub-erl-bytes\n")
      writeFile(extendedPath(innerDir / "bin" / "erlc.exe"),
        "stub-erlc-bytes\n")
      let archivePath = fixtureDir / "otp.7z"
      let addRes = execCmdEx(
        quoteShell(hostSeven) & " a -t7z " &
        quoteShell(absolutePath(archivePath)) &
        " otp-stub-28.5 -y -bsp0 -bso0",
        workingDir = stagingDir)
      check addRes.exitCode == 0
      let sha = fileShaHex(archivePath, "sha256")
      var store = openStore(storeDir)
      defer: store.close()
      discard seedSevenZipPrefix(store, hostSeven)
      let vp = initVersionedProvisioning(
        version = "stub-28.5",
        archive_format = afSevenZip,
        install_method = imExtract,
        bin_relpath = @["bin/erl.exe", "bin/erlc.exe"],
        platforms = @[
          initPlatformBinary(
            cpu = detectHostCpu(), os = detectHostOs(),
            url = fileToUrl(absolutePath(archivePath)),
            sha256 = sha,
            extract_path = "otp-stub-28.5")
        ])
      let res = resolveBuiltinPackage("erlang-basic", @[vp])
      check res.found
      let outR = realizeBuiltinPackage(store, res.resolution)
      check (not outR.cacheHit)
      check fileExists(extendedPath(outR.prefixAbsolutePath / "bin" / "erl.exe"))
      check fileExists(extendedPath(outR.prefixAbsolutePath / "bin" / "erlc.exe"))

  test "test_m3_sfx_flatten_synthetic_ruby_shape":
    ## RubyInstaller ships as a 7z-SFX (.exe + appended 7z payload).
    ## This synthetic mirrors that shape — confirms M3 SFX flatten
    ## covers ruby's M71-deferred entry.
    let fixtureDir = FixtureRoot / "ruby-sfx"
    let storeDir = fixtureDir / "store"
    let stagingDir = fixtureDir / "staging"
    resetDir(fixtureDir); resetDir(storeDir); resetDir(stagingDir)
    let hostSeven = findExe("7z")
    if hostSeven.len == 0:
      echo "  [skip] no host 7z on PATH"
      skip()
    else:
      let innerName = "rubyinstaller-stub-4.0.5-1-x64"
      let innerDir = stagingDir / innerName
      createDir(extendedPath(innerDir / "bin"))
      writeFile(extendedPath(innerDir / "bin" / "ruby.exe"),
        "stub-ruby-payload\n")
      writeFile(extendedPath(innerDir / "bin" / "gem.cmd"),
        "@echo stub-gem\n")
      let plain7z = fixtureDir / "ruby-plain.7z"
      discard execCmdEx(
        quoteShell(hostSeven) & " a -t7z " &
        quoteShell(absolutePath(plain7z)) &
        " " & quoteShell(innerName) & " -y -bsp0 -bso0",
        workingDir = stagingDir)
      check fileExists(extendedPath(plain7z))
      let sfxPath = fixtureDir / "ruby-sfx.7z.exe"
      writeFile(extendedPath(sfxPath), "MZ\x90\x00" & readFile(extendedPath(plain7z)))
      let sha = fileShaHex(sfxPath, "sha256")
      var store = openStore(storeDir)
      defer: store.close()
      discard seedSevenZipPrefix(store, hostSeven)
      let vp = initVersionedProvisioning(
        version = "stub-4.0.5-1",
        archive_format = afSevenZipSfx,
        install_method = imExtract,
        bin_relpath = @["bin/ruby.exe", "bin/gem.cmd"],
        platforms = @[
          initPlatformBinary(
            cpu = detectHostCpu(), os = detectHostOs(),
            url = fileToUrl(absolutePath(sfxPath)),
            sha256 = sha,
            extract_path = innerName)
        ])
      let res = resolveBuiltinPackage("ruby-sfx", @[vp])
      check res.found
      let outR = realizeBuiltinPackage(store, res.resolution)
      check (not outR.cacheHit)
      check fileExists(extendedPath(outR.prefixAbsolutePath / "bin" / "ruby.exe"))
      check fileExists(extendedPath(outR.prefixAbsolutePath / "bin" / "gem.cmd"))
