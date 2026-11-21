## M11 (Realize-Closure-And-Catalog-Expansion spec) — plain NSIS
## realize family hook (the erlang OTP shape). Hermetic: fixtures are
## materialized on disk + served via file://. The non-hermetic
## dependency is a host ``7z.exe`` on PATH (or in a pre-staged
## ``7zip`` catalog prefix) — same dependency the M3 7z-SFX tests use.
##
## Closes the long-standing erlang carryover documented in M3, M4, and
## M8 retros: OTP's installer is a bona-fide NSIS installer (NOT a Burn
## bundle wrapping inner MSIs), so the M4 ``imInstallerNsisBundle``
## dispatch through dark.exe + lessmsi rejects it (``DARK0339``: no
## .wixburn section). The M11 ``imInstallerNsis`` (plain) variant
## dispatches directly through ``extract7z``, exploiting the full
## 7-Zip 26.01's transparent recognition of the modern NSIS envelope.
##
## A LIVE-mode smoke against the real 320 MB OTP installer is the
## load-bearing campaign-close evidence (REPRO_M11_LIVE=1); the
## hermetic test below uses a synthetic 7z payload to validate the
## dispatch shape + bin_relpath flatten — the LIVE smoke validates
## that the full 7z.exe actually accepts the upstream NSIS envelope.

## Negative cases exercise foreign-target refusal or the native consumer's
## missing-helper receipt, and separately preserve the compatibility discovery
## diagnostic. These use real metadata, the executor and empty stores; no mocks.

import std/[os, osproc, strutils, tables, unittest]
from repro_core/paths import extendedPath

import repro_local_store
import repro_dsl_stdlib/packages_schema
import repro_interface_artifacts
import repro_tool_profiles
when defined(windows) and defined(amd64):
  import repro_build_engine

import repro_home_apply/package_catalog
import repro_home_apply/builtin_adapter
from repro_test_support import testCaseScratchSlug

let FixtureRoot = "build/test-tmp/t-builtin-adapter-installer-nsis-erlang" /
  testCaseScratchSlug()

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
  ## Mirrors the t_builtin_adapter_7z_sfx_flatten helper. Scoop ships
  ## 7z as a shim under ``scoop/shims/7z.exe``; we resolve the real
  ## binary via the sibling ``.shim`` file when present.
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
  ## Same shape as the M3 SFX test's pre-seed. Required because the
  ## M11 ``imInstallerNsis`` dispatch flows through the M3
  ## ``discoverSevenZipExe`` (Step i prefers a catalog-resident 7zip
  ## prefix). The seeded prefix carries ``bin/7z.exe`` + sibling
  ## ``7z.dll`` (codec support).
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
      # See t_builtin_adapter_7z_nested.nim: copyFile drops the exec
      # bit on Linux. Use copyFileWithPermissions so the seeded 7z
      # stays runnable when the adapter shells out to it.
      copyFileWithPermissions(extendedPath(realExe),
        extendedPath(stagingDir / "bin" / "7z.exe"))
      let realDir = parentDir(realExe)
      let codecsDll = realDir / "7z.dll"
      if fileExists(extendedPath(codecsDll)):
        copyFile(extendedPath(codecsDll),
          extendedPath(stagingDir / "bin" / "7z.dll"))
      mechanism = "copy")
  outcome.absolutePath

# ---------------------------------------------------------------------------
# GM4b: an archive realization is a `tarball` record of a package definition
# (Provisioning-Contributions.md §"Profile Package References"). A test
# realization is a synthetic record for this host, SELECTED by the same
# `selectRealization` a profile reference goes through and projected by
# `archiveRealizationOf` into the archive realizer's input — so the realizer
# is driven exactly as `repro home apply` drives it.
# ---------------------------------------------------------------------------

proc hostRecord(url, archiveType, executablePath: string;
                extraExecutables: seq[string] = @[];
                sha256 = ""; sha1 = ""; version = "1.0.0";
                installMethod = ""; extractPath = "";
                installerArgs: seq[string] = @[];
                pacmanPackages: seq[string] = @[];
                env: seq[string] = @[]; nested7z = false;
                msiAdminInstall = false;
                preInstall: seq[string] = @[];
                preInstallUnrecognized: seq[string] = @[];
                launcherEmit: seq[string] = @[];
                anyCpu = false): InterfaceTarballProvisioning =
  ## A synthetic `tarball` record for this host's (cpu, os); ``anyCpu``
  ## leaves the cpu open, as a record for every CPU family does.
  let host = hostRealizationTarget()
  result = InterfaceTarballProvisioning(url: url, sha256: sha256,
    archiveType: archiveType, executablePath: executablePath,
    cpu: (if anyCpu: "" else: $host.platform.family), os: $host.os)
  result.detail.version = version
  result.detail.sha1 = sha1
  result.detail.installMethod = installMethod
  result.detail.extractPath = extractPath
  result.detail.extraExecutables = extraExecutables
  result.detail.installerArgs = installerArgs
  result.detail.pacmanPackages = pacmanPackages
  result.detail.env = env
  result.detail.nested7z = nested7z
  result.detail.msiAdminInstall = msiAdminInstall
  result.detail.preInstall = preInstall
  result.detail.preInstallUnrecognized = preInstallUnrecognized
  result.detail.launcherEmit = launcherEmit

proc selectArchive(packageId: string;
                   records: openArray[InterfaceTarballProvisioning];
                   version = ""): ArchiveRealization =
  ## Select among ``records`` for this host (policy ``[tarball]``) and
  ## project the selection into the archive realizer's input.
  var useDef = InterfaceToolUse(rawConstraint: packageId,
    packageSelector: packageId, executableName: packageId)
  useDef.tarballProvisioning = @records
  let selection = selectRealization(useDef, SelectionRequest(
    packageName: packageId, target: hostRealizationTarget(),
    policy: @[rkTarball], version: version, definitionKnown: true))
  archiveRealizationOf(packageId, selection.tarball)

suite "M11 — archive realizer plain NSIS realize (erlang shape)":

  test "test_m11_imInstallerNsis_synthetic_otp_shape":
    ## Builds a synthetic .7z fixture mirroring the OTP layout —
    ## ``erts-16.4/bin/erl.exe`` etc. — and labels it
    ## ``afInstallerNsis + imInstallerNsis``. Asserts:
    ##   * the resolver picks the imInstallerNsis dispatch;
    ##   * the realize loop extracts via extract7z (the M3 7z dispatch);
    ##   * the realized prefix carries the declared bin_relpath under
    ##     ``erts-16.4/bin/``.
    ##
    ## The fixture uses a plain .7z stream (NOT an actual NSIS-wrapped
    ## .exe) because the test exercises the imInstallerNsis dispatch
    ## SHAPE, not the upstream 7z's NSIS-envelope recognition (that's
    ## the LIVE smoke's responsibility). A plain .7z stream is binary-
    ## compatible with the extract7z code path: 7z.exe recognises the
    ## file via the 7z signature bytes, the realize loop's case dispatch
    ## treats imInstallerNsis identically to the imExtract+afSevenZip
    ## path. The LIVE smoke against the real otp_win64_28.5.exe is
    ## what validates the upstream-NSIS-envelope claim.
    let fixtureDir = FixtureRoot / "erlang-realize"
    let storeDir = fixtureDir / "store"
    let stagingDir = fixtureDir / "staging"
    resetDir(fixtureDir); resetDir(storeDir); resetDir(stagingDir)

    let hostSeven = findExe("7z")
    if hostSeven.len == 0:
      echo "  [skip] no host 7z on PATH; cannot build synthetic OTP fixture"
      skip()
    else:
      # Build the synthetic OTP file tree under staging/erts-16.4/bin/.
      let ertsDir = stagingDir / "erts-16.4" / "bin"
      createDir(extendedPath(ertsDir))
      writeFile(extendedPath(ertsDir / "erl.exe"),
        "stub-erl-otp-payload\n")
      setFilePermissions(extendedPath(ertsDir / "erl.exe"),
        {fpUserRead, fpUserWrite, fpUserExec})
      writeFile(extendedPath(ertsDir / "erlc.exe"),
        "stub-erlc-otp-payload\n")
      setFilePermissions(extendedPath(ertsDir / "erlc.exe"),
        {fpUserRead, fpUserWrite, fpUserExec})
      writeFile(extendedPath(ertsDir / "escript.exe"),
        "stub-escript-otp-payload\n")
      setFilePermissions(extendedPath(ertsDir / "escript.exe"),
        {fpUserRead, fpUserWrite, fpUserExec})
      writeFile(extendedPath(ertsDir / "werl.exe"),
        "stub-werl-otp-payload\n")
      setFilePermissions(extendedPath(ertsDir / "werl.exe"),
        {fpUserRead, fpUserWrite, fpUserExec})
      # Pack as plain .7z with the synthetic outer-NSIS extension.
      let nsisPath = fixtureDir / "otp_win64_28.5.exe"
      let addRes = execCmdEx(
        quoteShell(hostSeven) & " a -t7z " &
        quoteShell(absolutePath(nsisPath)) &
        " erts-16.4 -y -bsp0 -bso0",
        workingDir = stagingDir)
      check addRes.exitCode == 0
      check fileExists(extendedPath(nsisPath))
      let sha = fileShaHex(nsisPath, "sha256")

      var store = openStore(storeDir)
      defer: store.close()
      discard seedSevenZipPrefix(store, hostSeven)

      let res = selectArchive("erlang-nsis", [hostRecord(
        fileToUrl(absolutePath(nsisPath)), "installer-nsis",
        "erts-16.4/bin/erl.exe",
        @["erts-16.4/bin/erlc.exe", "erts-16.4/bin/escript.exe",
          "erts-16.4/bin/werl.exe"],
        sha256 = sha, version = "stub-28.5",
        installMethod = "installer-nsis")])
      check res.installMethod == imInstallerNsis
      check res.archiveFormat == afInstallerNsis

      let outR = realizeBuiltinPackage(store, res)
      check (not outR.cacheHit)
      let realizedErl = outR.prefixAbsolutePath / "erts-16.4" / "bin" / "erl.exe"
      check fileExists(extendedPath(realizedErl))
      check readFile(extendedPath(realizedErl)).contains("stub-erl-otp-payload")
      check fileExists(extendedPath(outR.prefixAbsolutePath / "erts-16.4" / "bin" / "erlc.exe"))
      check fileExists(extendedPath(outR.prefixAbsolutePath / "erts-16.4" / "bin" / "escript.exe"))
      check fileExists(extendedPath(outR.prefixAbsolutePath / "erts-16.4" / "bin" / "werl.exe"))

  test "m11_imInstallerNsis_foreign_target_or_missing_helper_receipt_fails_closed":
    ## The real Windows record is still selected, with its installer metadata
    ## intact. A foreign host refuses it before downloads. On its native host,
    ## executing the consumer without its helper receipt fails before staging;
    ## helper execution and download are covered by the common graph fixtures.
    let fixtureDir = FixtureRoot / "erlang-target-and-helper-refusal"
    let storeDir = fixtureDir / "store"
    resetDir(fixtureDir); resetDir(storeDir)
    var store = openStore(storeDir)
    defer: store.close()
    let resolution = resolveProfilePackage("erlang",
      realizationTargetFor(pcX86_64, poWindows, mlX86_64_v1), @[rkTarball])
    check resolution.archiveRoute == arExtract
    let res = resolution.archive
    check res.installMethod == imInstallerNsis
    when defined(windows) and defined(amd64):
      let edges = tarballProvisioningEdges(resolution.useDef, absolutePath(storeDir))
      check edges.actions.len >= 2
      let consumer = edges.actions[^1]
      check consumer.id == edges.rootId
      check consumer.deps.len >= 1
      check consumer.inputs.len >= 1
      let outcome = executeTarballProvisionEdge(consumer)
      checkpoint(outcome.stderr)
      check outcome.status == asFailed
      check "the 7z dependency edge left no receipt" in outcome.stderr
      check not fileExists(edges.rootReceipt)
    else:
      let host = hostRealizationTarget()
      var refused = false
      try:
        discard realizeBuiltinPackage(store, res)
      except ValueError as err:
        refused = true
        check "no tarball provisioning entry for package \"erlang\"" in err.msg
        check "matches host cpu=" & $host.platform.family & " os=" & $host.os in err.msg
      check refused
    check listPrefixes(store).len == 0
    for prefix in walkDirs(storeDir / "prefixes" / "erlang" / "*"):
      checkpoint(prefix)
      check false

  test "m11_imInstallerNsis_compatibility_discovery_missing_helper_fails_closed":
    ## The exported compatibility discovery API keeps its typed diagnostic;
    ## production realization instead requires the helper's dependency receipt.
    let fixtureDir = FixtureRoot / "erlang-compatibility-discovery"
    let storeDir = fixtureDir / "store"
    let emptyDir = fixtureDir / "empty-path"
    resetDir(fixtureDir); resetDir(storeDir); resetDir(emptyDir)
    let savedPath = getEnv("PATH")
    putEnv("PATH", absolutePath(emptyDir))
    defer: putEnv("PATH", savedPath)
    var store = openStore(storeDir)
    defer: store.close()
    var raised = false
    try:
      discard discoverSevenZipExe(store, "erlang")
    except EBuiltinSevenZipUnavailable as err:
      raised = true
      check err.packageId == "erlang"
      check err.discoveryTrace.len >= 2
      check "catalog-prefix:scanned 0 rows" in err.discoveryTrace[0]
      check "path:no" in err.discoveryTrace[^1]
      check "repro home add 7zip" in err.msg
    check raised
    check listPrefixes(store).len == 0

  test "test_m11_imInstallerNsis_schema_requires_bin_relpath":
    ## Schema validator of the harvester's parse model
    ## (``VersionedProvisioning``; GM4b keeps it as the harvester's
    ## in-memory record): imInstallerNsis joins the imInstallerMsi /
    ## imInstallerNsisBundle / imInstallerInnoSetup family — every
    ## Windows installer family record needs at least one bin_relpath
    ## entry so the post-extract sanity check has something to verify
    ## against the realized prefix tree.
    let vp = initVersionedProvisioning(
      version = "1.0",
      archive_format = afInstallerNsis,
      install_method = imInstallerNsis,
      bin_relpath = @[],
      platforms = @[
        initPlatformBinary(
          cpu = pcX86_64, os = poWindows,
          url = "https://example.invalid/x.exe",
          sha256 = "00" & "00".repeat(31),
          extract_path = "")
      ])
    let errs = validateVersionedProvisioning(vp)
    var sawBinRelpathErr = false
    for e in errs:
      # The validator reports via the install_method's $-repr
      # ("installer-nsis") OR by enum-ident — accept either shape so
      # this test isn't coupled to the validator's exact phrasing.
      if "bin_relpath" in e and
         ("imInstallerNsis" in e or "installer-nsis" in e):
        sawBinRelpathErr = true
    check sawBinRelpathErr
