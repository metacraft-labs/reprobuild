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

import std/[os, osproc, strutils, tables, unittest]
from repro_core/paths import extendedPath

import repro_local_store
import repro_dsl_stdlib/packages_schema

import repro_home_apply/package_catalog
import repro_home_apply/builtin_adapter

const FixtureRoot = "build/test-tmp/t-builtin-adapter-installer-nsis-erlang"

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

suite "M11 — cakBuiltin plain NSIS realize (erlang shape)":

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
      writeFile(extendedPath(ertsDir / "erlc.exe"),
        "stub-erlc-otp-payload\n")
      writeFile(extendedPath(ertsDir / "escript.exe"),
        "stub-escript-otp-payload\n")
      writeFile(extendedPath(ertsDir / "werl.exe"),
        "stub-werl-otp-payload\n")
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

      let vp = initVersionedProvisioning(
        version = "stub-28.5",
        archive_format = afInstallerNsis,
        install_method = imInstallerNsis,
        bin_relpath = @[
          "erts-16.4/bin/erl.exe",
          "erts-16.4/bin/erlc.exe",
          "erts-16.4/bin/escript.exe",
          "erts-16.4/bin/werl.exe",
        ],
        platforms = @[
          initPlatformBinary(
            cpu = detectHostCpu(), os = detectHostOs(),
            url = fileToUrl(absolutePath(nsisPath)),
            sha256 = sha,
            extract_path = "")
        ])
      let res = resolveBuiltinPackage("erlang-nsis", @[vp])
      check res.found
      check res.resolution.installMethod == imInstallerNsis
      check res.resolution.archiveFormat == afInstallerNsis

      let outR = realizeBuiltinPackage(store, res.resolution)
      check (not outR.cacheHit)
      let realizedErl = outR.prefixAbsolutePath / "erts-16.4" / "bin" / "erl.exe"
      check fileExists(extendedPath(realizedErl))
      check readFile(extendedPath(realizedErl)).contains("stub-erl-otp-payload")
      check fileExists(extendedPath(outR.prefixAbsolutePath / "erts-16.4" / "bin" / "erlc.exe"))
      check fileExists(extendedPath(outR.prefixAbsolutePath / "erts-16.4" / "bin" / "escript.exe"))
      check fileExists(extendedPath(outR.prefixAbsolutePath / "erts-16.4" / "bin" / "werl.exe"))

  test "test_m11_imInstallerNsis_missing_sevenzip_fails_closed":
    ## Same fixture realized on a host where 7z.exe is not discoverable
    ## raises EBuiltinSevenZipUnavailable with the
    ## ``repro home add 7zip`` remediation hint. Mirrors the M3 SFX
    ## fail-closed test — needsSevenZip() returns true for
    ## imInstallerNsis so discovery raises BEFORE the download.
    let fixtureDir = FixtureRoot / "erlang-missing-7z"
    let storeDir = fixtureDir / "store"
    resetDir(fixtureDir); resetDir(storeDir)
    let stubPath = fixtureDir / "stub.exe"
    writeFile(extendedPath(stubPath), "stub-nsis-bytes\n")
    let sha = fileShaHex(stubPath, "sha256")
    let emptyDir = fixtureDir / "empty-path"
    resetDir(emptyDir)
    let savedPath = getEnv("PATH")
    putEnv("PATH", emptyDir)
    defer: putEnv("PATH", savedPath)
    var store = openStore(storeDir)
    defer: store.close()
    let vp = initVersionedProvisioning(
      version = "stub-28.5",
      archive_format = afInstallerNsis,
      install_method = imInstallerNsis,
      bin_relpath = @["erts-16.4/bin/erl.exe"],
      platforms = @[
        initPlatformBinary(
          cpu = detectHostCpu(), os = detectHostOs(),
          url = fileToUrl(absolutePath(stubPath)),
          sha256 = sha,
          extract_path = "")
      ])
    let res = resolveBuiltinPackage("erlang-missing-7z", @[vp])
    check res.found
    var raised = false
    var pkg = ""
    var traceLen = 0
    try:
      discard realizeBuiltinPackage(store, res.resolution)
    except EBuiltinSevenZipUnavailable as err:
      raised = true
      pkg = err.packageId
      traceLen = err.discoveryTrace.len
    check raised
    check pkg == "erlang-missing-7z"
    check traceLen >= 1

  test "test_m11_imInstallerNsis_schema_requires_bin_relpath":
    ## Schema validator: imInstallerNsis joins the imInstallerMsi /
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
