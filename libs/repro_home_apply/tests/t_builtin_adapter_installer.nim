## M4 (Realize-Closure-And-Catalog-Expansion spec) — Windows installer
## family realize hooks for MSI / NSIS+MSI bundles + merge-conflict
## detection. Mirrors M3's t_builtin_adapter_7z_*.nim test structure.
##
## Hermetic by design: every fixture is materialized on disk and served
## via a ``file://`` URL. The non-hermetic dependencies are:
##   * a host ``7z.exe`` (or pre-seeded catalog ``7zip`` prefix) for
##     the NSIS-bundle outer-shell unwrap;
##   * a host ``dark.exe`` (or pre-seeded catalog ``wix3`` prefix) for
##     the MSI extraction (synthesized MSI fixtures via WiX's
##     ``candle.exe`` + ``light.exe``);
##   * a host ``msiexec`` (always present on Windows) when the
##     ``CAKBUILTIN_PREFER_MSIEXEC=1`` env-var escape hatch is
##     exercised.
##
## Per the M4 honest-scope contract: these tests exercise the family
## hooks themselves — they assert the realize loop's MSI / NSIS+MSI
## dispatch produces a prefix tree with the declared bin_relpath at
## the right relative path. The downstream per-tool quirks (swift's
## VS Build Tools env activation, python3's PEP 514 registry import)
## are EXPLICITLY out of scope.

import std/[os, osproc, strutils, tables, unittest]
from repro_core/paths import extendedPath

import repro_local_store
import repro_dsl_stdlib/packages_schema

import repro_home_apply/package_catalog
import repro_home_apply/builtin_adapter

const FixtureRoot = "build/test-tmp/t-builtin-adapter-installer"

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

proc resolveRealExe(hostExe: string): string =
  ## Scoop shims (``.shim`` sidecar carrying ``path = "<real>"``) need
  ## the sidecar to dispatch; naively copying the shim into the seeded
  ## prefix produces "Cannot open shim file for read". When a sibling
  ## ``.shim`` is present we parse it and return the real binary path.
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

proc seedCatalogPrefix(store: var Store; packageName, version: string;
                       hostExe, leafName: string;
                       extraFiles: seq[(string, string)] = @[]): string =
  ## Pre-populate the store with a ``<packageName>`` prefix containing
  ## ``<leafName>`` at the prefix root (aliased from ``hostExe``). Used
  ## for the M4 discovery-by-prefix branch.
  let prefixId = computeRealizationHash(packageName, version,
    "builtin", "sha256:seed-" & packageName, leafName,
    "file:///seed-" & packageName, "seed-" & packageName, @["fixture"])
  let hint = StoreReceiptHint(
    adapter: "builtin",
    packageName: packageName,
    version: version,
    declaredExecutablePath: leafName,
    exportedExecutables: @[leafName],
    lockIdentity: "sha256:seed-" & packageName,
    provenanceUrl: "file:///seed-" & packageName,
    provenanceChecksum: "sha256:seed-" & packageName,
    materializationMechanism: "raw+extract")
  let realExe = resolveRealExe(hostExe)
  let outcome = realizePrefix(store, prefixId, hint,
    proc (stagingDir: string; mechanism: var string) =
      copyFile(extendedPath(realExe),
        extendedPath(stagingDir / leafName))
      let realDir = parentDir(realExe)
      for (filename, content) in extraFiles:
        # Either copy a sibling file from realDir/, or write the literal
        # content directly. If ``content`` is exactly the string
        # "<sibling>" we copy from the real binary's neighborhood.
        if content == "<sibling>":
          let sibling = realDir / filename
          if fileExists(extendedPath(sibling)):
            copyFile(extendedPath(sibling),
              extendedPath(stagingDir / filename))
        else:
          writeFile(extendedPath(stagingDir / filename), content)
      mechanism = "copy")
  outcome.absolutePath

proc seedDarkExePrefix(store: var Store; hostDark: string): string =
  ## Wrapper for the discovery-by-prefix test for wix3. The real
  ## dark.exe needs its sibling ``dark.exe.config`` to launch.
  seedCatalogPrefix(store, "wix3", "test-seed", hostDark, "dark.exe",
    extraFiles = @{
      "dark.exe.config": "<sibling>"
    })

proc seedLessmsiExePrefix(store: var Store; hostLessmsi: string): string =
  ## lessmsi.exe ships in a multi-file zip but the .exe runs
  ## standalone alongside LessIO.dll. Copy both into the seed prefix.
  seedCatalogPrefix(store, "lessmsi", "test-seed",
    hostLessmsi, "lessmsi.exe",
    extraFiles = @{
      "LessIO.dll": "<sibling>",
      "LessMsi.Core.dll": "<sibling>",
      "Microsoft.Tools.WindowsInstaller.PackageEditor.dll": "<sibling>",
      "Microsoft.Tools.WindowsInstallerXml.Cab.Interop.dll": "<sibling>",
      "Microsoft.Tools.WindowsInstallerXml.Cab.dll": "<sibling>",
      "Microsoft.Tools.WindowsInstallerXml.Msi.dll": "<sibling>",
      "WindowsInstaller.dll": "<sibling>"
    })

proc seedInnounpExePrefix(store: var Store; hostInnounp: string): string =
  seedCatalogPrefix(store, "innounp", "test-seed",
    hostInnounp, "innounp.exe")

proc seedSevenZipExePrefix(store: var Store; hostSeven: string): string =
  ## 7-Zip needs the sibling 7z.dll to extract.
  seedCatalogPrefix(store, "7zip", "test-seed", hostSeven, "bin/7z.exe",
    extraFiles = @{
      "bin/7z.dll": "<sibling>"
    })

proc buildMinimalMsi(workDir, msiName: string;
                     payload: seq[(string, string)]): string =
  ## Build a minimal MSI from a tiny WiX source. Requires candle.exe +
  ## light.exe on PATH (which dark.exe's release zip ships). Returns
  ## the absolute path of the produced MSI, or empty string on failure.
  let candle = findExe("candle")
  let light = findExe("light")
  if candle.len == 0 or light.len == 0:
    return ""
  resetDir(workDir)
  # Write a minimal WiX source declaring one Component per payload entry
  # under a single Feature, with each File pointing at a sibling-on-disk
  # source. Use deterministic GUIDs (sha-of-content would be cleaner but
  # the test fixture treats the MSI as opaque bytes — what matters is
  # dark.exe can crack it open).
  var sourceFiles = ""
  var components = ""
  var fileRefs = ""
  var compIdx = 0
  for (relpath, content) in payload:
    let srcPath = workDir / ("pl" & $compIdx & "_" & extractFilename(relpath))
    writeFile(extendedPath(srcPath), content)
    sourceFiles.add(srcPath & "\n")
    let compGuid = "{12345678-1234-1234-1234-" & align($compIdx, 12, '0') & "}"
    let compId = "Comp" & $compIdx
    let fileId = "File" & $compIdx
    components.add("        <Component Id=\"" & compId &
      "\" Guid=\"" & compGuid & "\">\n" &
      "          <File Id=\"" & fileId & "\" KeyPath=\"yes\" " &
      "Source=\"" & srcPath.replace('\\', '/') & "\" Name=\"" &
      extractFilename(relpath) & "\" />\n" &
      "        </Component>\n")
    fileRefs.add("        <ComponentRef Id=\"" & compId & "\" />\n")
    inc compIdx
  let wxs = """
<?xml version="1.0" encoding="UTF-8"?>
<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
  <Product Id="*" Name="TestMsi" Language="1033" Version="1.0.0.0"
           Manufacturer="ReprobuildTest"
           UpgradeCode="{ABCDEF12-3456-7890-1234-567890ABCDEF}">
    <Package InstallerVersion="200" Compressed="yes" InstallScope="perUser" />
    <Media Id="1" Cabinet="testmsi.cab" EmbedCab="yes" />
    <Directory Id="TARGETDIR" Name="SourceDir">
      <Directory Id="AppRootDir" Name="TestMsi">
""" & components.replace("        <Component", "        <Component") & """
      </Directory>
    </Directory>
    <Feature Id="MainFeature" Title="Main" Level="1">
""" & fileRefs & """
    </Feature>
  </Product>
</Wix>
"""
  # Need to scope the Components under AppRootDir — restructure.
  let wxsPath = workDir / "test.wxs"
  let wxsContent = """
<?xml version="1.0" encoding="UTF-8"?>
<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
  <Product Id="*" Name="TestMsi" Language="1033" Version="1.0.0.0"
           Manufacturer="ReprobuildTest"
           UpgradeCode="{ABCDEF12-3456-7890-1234-567890ABCDEF}">
    <Package InstallerVersion="200" Compressed="yes" InstallScope="perUser" />
    <Media Id="1" Cabinet="testmsi.cab" EmbedCab="yes" />
    <Directory Id="TARGETDIR" Name="SourceDir">
      <Directory Id="AppRootDir" Name="TestMsi">
""" & components & """
      </Directory>
    </Directory>
    <Feature Id="MainFeature" Title="Main" Level="1">
""" & fileRefs & """
    </Feature>
  </Product>
</Wix>
"""
  writeFile(extendedPath(wxsPath), wxsContent)
  discard sourceFiles  # was for diagnostics
  discard wxs
  # Run candle then light.
  let objPath = workDir / "test.wixobj"
  let msiPath = workDir / msiName
  let candleCmd = quoteShell(candle) & " -nologo -out " &
    quoteShell(objPath) & " " & quoteShell(wxsPath)
  let candleRes = execCmdEx(candleCmd)
  if candleRes.exitCode != 0:
    echo "  [build-msi candle FAILED] exit=", candleRes.exitCode, "\n",
      candleRes.output
    return ""
  let lightCmd = quoteShell(light) & " -nologo -out " &
    quoteShell(msiPath) & " " & quoteShell(objPath)
  let lightRes = execCmdEx(lightCmd)
  if lightRes.exitCode != 0:
    echo "  [build-msi light FAILED] exit=", lightRes.exitCode, "\n",
      lightRes.output
    return ""
  if not fileExists(extendedPath(msiPath)): return ""
  absolutePath(msiPath)

suite "M4 — cakBuiltin installer family realize":

  test "test_m4_discover_dark_finds_catalog_prefix":
    ## M4 ``discoverDarkExe`` Step (i): a store-resident wix3 prefix is
    ## preferred over PATH. (dark.exe is retained for Burn-bundle outer
    ## unwrap of imInstallerNsisBundle; not used for plain MSI extract
    ## per the post-live-smoke amendment.)
    let fixtureDir = FixtureRoot / "discover-dark-catalog"
    let storeDir = fixtureDir / "store"
    resetDir(fixtureDir); resetDir(storeDir)
    let hostDark = findExe("dark")
    if hostDark.len == 0:
      echo "  [skip] no host dark.exe on PATH; cannot seed wix3 prefix"
      skip()
    else:
      var store = openStore(storeDir)
      defer: store.close()
      let prefixAbs = seedDarkExePrefix(store, hostDark)
      check fileExists(extendedPath(prefixAbs / "dark.exe"))
      let discovered = discoverDarkExe(store, "test-tool")
      check discovered.startsWith(prefixAbs)
      check fileExists(extendedPath(discovered))

  test "test_m4_discover_dark_fails_closed_without_wix3":
    ## M4 ``discoverDarkExe`` Step (iii): no catalog prefix + no PATH
    ## dark → ``EBuiltinDarkUnavailable`` carries the trace + packageId.
    let fixtureDir = FixtureRoot / "discover-dark-fail"
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
      discard discoverDarkExe(store, "needy-msi-tool")
    except EBuiltinDarkUnavailable as err:
      raised = true
      traceLen = err.discoveryTrace.len
      pkg = err.packageId
    check raised
    check pkg == "needy-msi-tool"
    check traceLen >= 1

  test "test_m4_discover_lessmsi_finds_catalog_prefix":
    ## M4-amendment ``discoverLessmsiExe`` Step (i): a store-resident
    ## lessmsi prefix is preferred over PATH. lessmsi is the M4
    ## default MSI extractor.
    let fixtureDir = FixtureRoot / "discover-lessmsi-catalog"
    let storeDir = fixtureDir / "store"
    resetDir(fixtureDir); resetDir(storeDir)
    let hostLessmsi = findExe("lessmsi")
    if hostLessmsi.len == 0:
      echo "  [skip] no host lessmsi.exe on PATH"
      skip()
    else:
      var store = openStore(storeDir)
      defer: store.close()
      let prefixAbs = seedLessmsiExePrefix(store, hostLessmsi)
      check fileExists(extendedPath(prefixAbs / "lessmsi.exe"))
      let discovered = discoverLessmsiExe(store, "test-tool")
      check discovered.startsWith(prefixAbs)

  test "test_m4_discover_lessmsi_fails_closed_without_lessmsi":
    let fixtureDir = FixtureRoot / "discover-lessmsi-fail"
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
    var pkg = ""
    try:
      discard discoverLessmsiExe(store, "needy-msi-tool")
    except EBuiltinLessmsiUnavailable as err:
      raised = true
      pkg = err.packageId
    check raised
    check pkg == "needy-msi-tool"

  test "test_m4_discover_innounp_finds_catalog_prefix":
    let fixtureDir = FixtureRoot / "discover-innounp-catalog"
    let storeDir = fixtureDir / "store"
    resetDir(fixtureDir); resetDir(storeDir)
    let hostInnounp = findExe("innounp")
    if hostInnounp.len == 0:
      echo "  [skip] no host innounp.exe on PATH"
      skip()
    else:
      var store = openStore(storeDir)
      defer: store.close()
      let prefixAbs = seedInnounpExePrefix(store, hostInnounp)
      check fileExists(extendedPath(prefixAbs / "innounp.exe"))
      let discovered = discoverInnounpExe(store, "test-tool")
      check discovered.startsWith(prefixAbs)

  test "test_m4_discover_innounp_fails_closed_without_innounp":
    let fixtureDir = FixtureRoot / "discover-innounp-fail"
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
    var pkg = ""
    try:
      discard discoverInnounpExe(store, "needy-inno-tool")
    except EBuiltinInnounpUnavailable as err:
      raised = true
      pkg = err.packageId
    check raised
    check pkg == "needy-inno-tool"

  test "test_m4_msi_realize_via_lessmsi_synthetic_meson_shape":
    ## File:// realize of a synthetic MSI flattens through lessmsi
    ## (the M4-amendment default, per the post-live-smoke finding that
    ## WiX dark.exe extracts MSI metadata rather than the install
    ## file tree). The synthetic MSI is built via candle.exe +
    ## light.exe (which the wix3 zip ships); lessmsi extracts the
    ## payload to ``<staging>/SourceDir/TestMsi/`` and the extract_path
    ## flattens that down to the prefix root.
    let fixtureDir = FixtureRoot / "msi-realize-meson"
    let storeDir = fixtureDir / "store"
    let buildDir = fixtureDir / "build-msi"
    resetDir(fixtureDir); resetDir(storeDir); resetDir(buildDir)
    let hostLessmsi = findExe("lessmsi")
    let hostCandle = findExe("candle")
    let msiPath =
      if hostLessmsi.len == 0 or hostCandle.len == 0: ""
      else: buildMinimalMsi(buildDir, "meson-test-1.0.msi",
        @[("meson.exe", "stub-meson-payload\n")])
    if hostLessmsi.len == 0:
      echo "  [skip] no host lessmsi.exe on PATH"
      skip()
    elif hostCandle.len == 0:
      echo "  [skip] no host candle.exe (WiX) on PATH; needed to build MSI"
      skip()
    elif msiPath.len == 0:
      echo "  [skip] could not build minimal MSI (candle/light failed)"
      skip()
    else:
      let sha = fileShaHex(msiPath, "sha256")
      var store = openStore(storeDir)
      defer: store.close()
      discard seedLessmsiExePrefix(store, hostLessmsi)
      let vp = initVersionedProvisioning(
        version = "test-1.0",
        archive_format = afInstallerMsi,
        install_method = imInstallerMsi,
        bin_relpath = @["meson.exe"],
        platforms = @[
          initPlatformBinary(
            cpu = detectHostCpu(), os = detectHostOs(),
            url = fileToUrl(msiPath),
            sha256 = sha,
            # lessmsi writes under SourceDir/<MSI install hierarchy>;
            # our minimal MSI's hierarchy puts the file under TestMsi/.
            extract_path = "SourceDir/TestMsi")
        ])
      let res = resolveBuiltinPackage("meson-msi", @[vp])
      check res.found
      check res.resolution.installMethod == imInstallerMsi
      let outR = realizeBuiltinPackage(store, res.resolution)
      check (not outR.cacheHit)
      let realizedMeson = outR.prefixAbsolutePath / "meson.exe"
      check fileExists(extendedPath(realizedMeson))
      check readFile(extendedPath(realizedMeson)).contains("stub-meson-payload")

  test "test_m4_nsis_msi_bundle_merge_conflict_fails_closed":
    ## Two MSIs declaring the same path with different content via a
    ## synthetic bundle fixture (we use a 7z-archived dir containing
    ## two MSI files; 7z is the fallback outer-shell unwrapper for
    ## legacy NSIS bundles that dark.exe cannot crack).
    ## ``EBuiltinPrefixMergeConflict`` raised carrying both source
    ## basenames + the conflicting path.
    let fixtureDir = FixtureRoot / "merge-conflict"
    let storeDir = fixtureDir / "store"
    let stagingDir = fixtureDir / "staging"
    let buildDir = fixtureDir / "build-msis"
    resetDir(fixtureDir); resetDir(storeDir)
    resetDir(stagingDir); resetDir(buildDir)
    let hostSeven = findExe("7z")
    let hostLessmsi = findExe("lessmsi")
    let hostCandle = findExe("candle")
    let msi1 =
      if hostSeven.len == 0 or hostLessmsi.len == 0 or hostCandle.len == 0: ""
      else: buildMinimalMsi(buildDir / "a", "alpha.msi",
        @[("shared.txt", "content-from-alpha\n")])
    let msi2 =
      if hostSeven.len == 0 or hostLessmsi.len == 0 or hostCandle.len == 0: ""
      else: buildMinimalMsi(buildDir / "b", "beta.msi",
        @[("shared.txt", "content-from-beta-different-bytes\n")])
    if hostSeven.len == 0 or hostLessmsi.len == 0 or hostCandle.len == 0:
      echo "  [skip] need 7z + lessmsi + candle on PATH for merge-conflict test"
      skip()
    elif msi1.len == 0 or msi2.len == 0:
      echo "  [skip] could not build minimal MSIs"
      skip()
    else:
      # Bundle them into a synthetic 7z archive (the fallback shape).
      let bundleStage = stagingDir / "bundle-inner"
      createDir(extendedPath(bundleStage))
      copyFile(extendedPath(msi1),
        extendedPath(bundleStage / "alpha.msi"))
      copyFile(extendedPath(msi2),
        extendedPath(bundleStage / "beta.msi"))
      let bundle7z = stagingDir / "synthetic-nsis-bundle.7z"
      let addCmd = quoteShell(hostSeven) & " a -t7z " &
        quoteShell(absolutePath(bundle7z)) & " bundle-inner -y -bsp0 -bso0"
      let addRes = execCmdEx(addCmd, workingDir = stagingDir)
      check addRes.exitCode == 0
      # We use ``extractNsisMsiBundle`` directly here rather than going
      # through the full realize loop — keeps the merge-conflict
      # assertion close to the API it tests + avoids the realize loop's
      # bin_relpath sanity check (since the bundle has no `bin/`
      # payload).
      var store = openStore(storeDir)
      defer: store.close()
      discard seedSevenZipExePrefix(store, hostSeven)
      discard seedLessmsiExePrefix(store, hostLessmsi)
      let outDir = stagingDir / "merged-out"
      resetDir(outDir)
      let sevenExe = discoverSevenZipExe(store, "merge-conflict-tool")
      let lessmsiExe = discoverLessmsiExe(store, "merge-conflict-tool")
      # darkExe = "" → outer unwrap falls back to 7z (which handles the
      # synthetic .7z fixture cleanly).
      var raised = false
      var conflictPath = ""
      try:
        extractNsisMsiBundle("merge-conflict-tool", bundle7z, outDir,
          lessmsiExe, "", sevenExe)
      except EBuiltinPrefixMergeConflict as err:
        raised = true
        conflictPath = err.conflictPath
      check raised
      check "shared.txt" in conflictPath

  test "test_m4_msi_extractor_dispatch_honors_msiexec_env_var":
    ## With ``CAKBUILTIN_PREFER_MSIEXEC=1``, the realize loop skips
    ## dark.exe discovery and uses msiexec /a — assert needsDark()
    ## returns false. Indirect assertion: realize with no wix3 + no
    ## dark.exe on PATH but the env var set should NOT raise
    ## ``EBuiltinDarkUnavailable``. We exercise this with a stub MSI
    ## that msiexec can crack open (a real, minimal MSI built via
    ## buildMinimalMsi).
    let fixtureDir = FixtureRoot / "msi-msiexec-escape"
    let storeDir = fixtureDir / "store"
    let buildDir = fixtureDir / "build-msi"
    resetDir(fixtureDir); resetDir(storeDir); resetDir(buildDir)
    let hostCandle = findExe("candle")
    let msiPath =
      if hostCandle.len == 0: ""
      else: buildMinimalMsi(buildDir, "msiexec-test.msi",
        @[("hello.txt", "msiexec-payload\n")])
    if hostCandle.len == 0:
      echo "  [skip] no host candle.exe (WiX) on PATH; cannot build MSI"
      skip()
    elif msiPath.len == 0:
      echo "  [skip] could not build minimal MSI for msiexec test"
      skip()
    else:
      let sha = fileShaHex(msiPath, "sha256")
      # Strip PATH of lessmsi.exe so we'd raise
      # EBuiltinLessmsiUnavailable WITHOUT the env-var escape hatch.
      let savedPath = getEnv("PATH")
      let prunedPath = block:
        var dirs: seq[string] = @[]
        for d in savedPath.split(';'):
          let lmCand = d / "lessmsi.exe"
          if not fileExists(extendedPath(lmCand)):
            dirs.add(d)
        dirs.join(";")
      putEnv("PATH", prunedPath)
      putEnv("CAKBUILTIN_PREFER_MSIEXEC", "1")
      defer:
        putEnv("PATH", savedPath)
        delEnv("CAKBUILTIN_PREFER_MSIEXEC")
      var store = openStore(storeDir)
      defer: store.close()
      let vp = initVersionedProvisioning(
        version = "msiexec-1.0",
        archive_format = afInstallerMsi,
        install_method = imInstallerMsi,
        bin_relpath = @["hello.txt"],
        platforms = @[
          initPlatformBinary(
            cpu = detectHostCpu(), os = detectHostOs(),
            url = fileToUrl(msiPath),
            sha256 = sha,
            # msiexec /a lays files under <TARGETDIR>/<MSI's directory
            # table> — for our minimal MSI with TestMsi as the inner
            # dir, the file lives at <prefix>/TestMsi/hello.txt.
            extract_path = "TestMsi")
        ])
      let res = resolveBuiltinPackage("msi-msiexec-tool", @[vp])
      check res.found
      var raisedLessmsi = false
      try:
        let outR = realizeBuiltinPackage(store, res.resolution)
        check fileExists(extendedPath(outR.prefixAbsolutePath / "hello.txt"))
      except EBuiltinLessmsiUnavailable:
        raisedLessmsi = true
      check (not raisedLessmsi)
