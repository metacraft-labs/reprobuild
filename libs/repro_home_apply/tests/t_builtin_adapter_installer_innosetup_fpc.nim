## M4 (Realize-Closure-And-Catalog-Expansion spec) — Inno Setup
## realize family hook (the freepascal / fpc shape). Hermetic:
## fixtures are materialized on disk + served via file://. The
## non-hermetic dependency is innounp.exe (catalog-seeded prefix OR
## PATH); the inner Inno Setup .exe is built via the Inno Setup
## compiler ``iscc`` IF it is on PATH, otherwise the test skips.
##
## A future test refinement (gated REPRO_M4_LIVE=1) could swap the
## synthetic Inno fixture for the actual freepascal-3.2.2.exe — but
## that's a 200MB download and exceeds the hermetic-tests budget.
## Live verification of the fpc shape is the REPRO_M4_LIVE smoke
## documented in the M4 hand-off.

import std/[os, osproc, strutils, tables, unittest]
from repro_core/paths import extendedPath

import repro_local_store
import repro_dsl_stdlib/packages_schema

import repro_home_apply/package_catalog
import repro_home_apply/builtin_adapter

const FixtureRoot = "build/test-tmp/t-builtin-adapter-installer-innosetup-fpc"

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

proc seedInnounpPrefix(store: var Store; hostInnounp: string): string =
  let prefixId = computeRealizationHash("innounp", "test-seed",
    "builtin", "sha256:seed-innounp", "innounp.exe",
    "file:///seed-innounp", "seed-innounp", @["fixture"])
  let hint = StoreReceiptHint(
    adapter: "builtin",
    packageName: "innounp",
    version: "test-seed",
    declaredExecutablePath: "innounp.exe",
    exportedExecutables: @["innounp.exe"],
    lockIdentity: "sha256:seed-innounp",
    provenanceUrl: "file:///seed-innounp",
    provenanceChecksum: "sha256:seed-innounp",
    materializationMechanism: "raw+extract")
  let realExe = resolveRealExe(hostInnounp)
  let outcome = realizePrefix(store, prefixId, hint,
    proc (stagingDir: string; mechanism: var string) =
      copyFile(extendedPath(realExe),
        extendedPath(stagingDir / "innounp.exe"))
      mechanism = "copy")
  outcome.absolutePath

proc buildMinimalInnoExe(workDir, outExeName: string;
                         payload: seq[(string, string)]): string =
  ## Build a minimal Inno Setup installer via the Inno Setup compiler
  ## (``iscc.exe``). Returns the abs path on success, empty on failure.
  let iscc = findExe("iscc")
  if iscc.len == 0:
    return ""
  resetDir(workDir)
  var payloadDir = workDir / "payload"
  createDir(extendedPath(payloadDir))
  var fileLines = ""
  for (relpath, content) in payload:
    let dst = payloadDir / relpath
    createDir(extendedPath(parentDir(dst)))
    writeFile(extendedPath(dst), content)
    fileLines.add("Source: \"" & dst.replace("\\", "\\\\") &
      "\"; DestDir: \"{app}\\" & parentDir(relpath).replace("/", "\\") &
      "\"\n")
  let outDir = workDir / "out"
  createDir(extendedPath(outDir))
  let iss = """
[Setup]
AppName=TestInno
AppVersion=1.0
DefaultDirName={pf}\TestInno
DisableDirPage=yes
DisableProgramGroupPage=yes
OutputDir=""" & outDir.replace("\\", "\\\\") & """

OutputBaseFilename=""" & outExeName.changeFileExt("") & """

Compression=lzma
SolidCompression=yes
PrivilegesRequired=lowest

[Files]
""" & fileLines
  let issPath = workDir / "test.iss"
  writeFile(extendedPath(issPath), iss)
  let isccCmd = quoteShell(iscc) & " /Q " & quoteShell(issPath)
  let isccRes = execCmdEx(isccCmd)
  if isccRes.exitCode != 0:
    echo "  [build-inno iscc FAILED] exit=", isccRes.exitCode, "\n",
      isccRes.output
    return ""
  let produced = outDir / outExeName
  if fileExists(extendedPath(produced)):
    return absolutePath(produced)
  return ""

suite "M4 — cakBuiltin Inno Setup realize (fpc shape)":

  test "test_m4_innosetup_realize_synthetic_fpc_shape":
    ## File:// realize of a synthetic Inno Setup installer flattens
    ## through innounp; the resulting prefix has bin/fpc.exe-stub at
    ## the root via the M4 ``flattenInnoAppDir`` ({app}\ -> root)
    ## transformation.
    let fixtureDir = FixtureRoot / "fpc-realize"
    let storeDir = fixtureDir / "store"
    let buildDir = fixtureDir / "build-inno"
    resetDir(fixtureDir); resetDir(storeDir); resetDir(buildDir)
    let hostInnounp = findExe("innounp")
    let exePath =
      if hostInnounp.len == 0: ""
      else: buildMinimalInnoExe(buildDir, "fpc-test.exe",
        @[("bin/fpc.exe", "stub-fpc-payload\n"),
          ("bin/ppcx64.exe", "stub-ppcx64-payload\n")])
    if hostInnounp.len == 0:
      echo "  [skip] no host innounp.exe on PATH"
      skip()
    elif exePath.len == 0:
      echo "  [skip] no iscc.exe on PATH; cannot build synthetic Inno fixture"
      skip()
    else:
      let sha = fileShaHex(exePath, "sha256")
      var store = openStore(storeDir)
      defer: store.close()
      discard seedInnounpPrefix(store, hostInnounp)
      let vp = initVersionedProvisioning(
        version = "test-fpc-1.0",
        archive_format = afRaw,
        install_method = imInstallerInnoSetup,
        bin_relpath = @["bin/fpc.exe", "bin/ppcx64.exe"],
        platforms = @[
          initPlatformBinary(
            cpu = detectHostCpu(), os = detectHostOs(),
            url = fileToUrl(exePath),
            sha256 = sha,
            extract_path = "")
        ])
      let res = resolveBuiltinPackage("fpc-inno", @[vp])
      check res.found
      check res.resolution.installMethod == imInstallerInnoSetup
      let outR = realizeBuiltinPackage(store, res.resolution)
      check (not outR.cacheHit)
      let realizedFpc = outR.prefixAbsolutePath / "bin" / "fpc.exe"
      check fileExists(extendedPath(realizedFpc))
      check readFile(extendedPath(realizedFpc)).contains("stub-fpc-payload")
      let realizedPpc = outR.prefixAbsolutePath / "bin" / "ppcx64.exe"
      check fileExists(extendedPath(realizedPpc))

  test "test_m4_innosetup_missing_extractor_fails_closed":
    ## Same fixture realized on a host where innounp is not
    ## discoverable raises EBuiltinInnounpUnavailable with the
    ## ``repro home add innounp`` remediation hint.
    let fixtureDir = FixtureRoot / "fpc-missing-innounp"
    let storeDir = fixtureDir / "store"
    let buildDir = fixtureDir / "build-inno"
    resetDir(fixtureDir); resetDir(storeDir); resetDir(buildDir)
    # We don't need a real Inno installer for this test — the discovery
    # raises BEFORE the download (and certainly before extraction)
    # because needsInnounp() returns true for imInstallerInnoSetup. We
    # use a stub file just to satisfy the digest sanity check.
    let stubPath = buildDir / "stub.exe"
    writeFile(extendedPath(stubPath), "stub-inno-bytes\n")
    let sha = fileShaHex(stubPath, "sha256")
    let emptyDir = fixtureDir / "empty-path"
    resetDir(emptyDir)
    let savedPath = getEnv("PATH")
    putEnv("PATH", emptyDir)
    defer: putEnv("PATH", savedPath)
    var store = openStore(storeDir)
    defer: store.close()
    let vp = initVersionedProvisioning(
      version = "test-stub-1.0",
      archive_format = afRaw,
      install_method = imInstallerInnoSetup,
      bin_relpath = @["bin/fpc.exe"],
      platforms = @[
        initPlatformBinary(
          cpu = detectHostCpu(), os = detectHostOs(),
          url = fileToUrl(absolutePath(stubPath)),
          sha256 = sha,
          extract_path = "")
      ])
    let res = resolveBuiltinPackage("fpc-missing-innounp", @[vp])
    check res.found
    var raised = false
    var pkg = ""
    var msg = ""
    try:
      discard realizeBuiltinPackage(store, res.resolution)
    except EBuiltinInnounpUnavailable as err:
      raised = true
      pkg = err.packageId
      msg = err.msg
    check raised
    check pkg == "fpc-missing-innounp"
    check "repro home add innounp" in msg
