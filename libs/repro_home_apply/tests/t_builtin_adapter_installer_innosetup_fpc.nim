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

## Negative cases exercise foreign-target refusal or the native consumer's
## missing-helper receipt, and separately preserve the compatibility discovery
## diagnostic. These use real metadata, the executor and empty stores; no mocks.

import std/[os, osproc, strutils, tables, unittest]
import repro_test_support/reasoned_skip
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

let FixtureRoot = "build/test-tmp/t-builtin-adapter-installer-innosetup-fpc" /
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

suite "M4 — archive realizer Inno Setup realize (fpc shape)":

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
      skip("innounp not on PATH")
    elif exePath.len == 0:
      echo "  [skip] no iscc.exe on PATH; cannot build synthetic Inno fixture"
      skip("iscc not on PATH — cannot build the synthetic Inno Setup fixture")
    else:
      let sha = fileShaHex(exePath, "sha256")
      var store = openStore(storeDir)
      defer: store.close()
      discard seedInnounpPrefix(store, hostInnounp)
      let res = selectArchive("fpc-inno", [hostRecord(fileToUrl(exePath),
        "raw", "bin/fpc.exe", @["bin/ppcx64.exe"], sha256 = sha,
        version = "test-fpc-1.0", installMethod = "installer-inno-setup")])
      check res.installMethod == imInstallerInnoSetup
      let outR = realizeBuiltinPackage(store, res)
      check (not outR.cacheHit)
      let realizedFpc = outR.prefixAbsolutePath / "bin" / "fpc.exe"
      check fileExists(extendedPath(realizedFpc))
      check readFile(extendedPath(realizedFpc)).contains("stub-fpc-payload")
      let realizedPpc = outR.prefixAbsolutePath / "bin" / "ppcx64.exe"
      check fileExists(extendedPath(realizedPpc))

  test "m4_innosetup_foreign_target_or_missing_helper_receipt_fails_closed":
    ## The real Windows record is still selected, with its installer metadata
    ## intact. A foreign host refuses it before downloads. On its native host,
    ## executing the consumer without its helper receipt fails before staging;
    ## helper execution and download are covered by the common graph fixtures.
    let fixtureDir = FixtureRoot / "fpc-target-and-helper-refusal"
    let storeDir = fixtureDir / "store"
    resetDir(fixtureDir); resetDir(storeDir)
    var store = openStore(storeDir)
    defer: store.close()
    let resolution = resolveProfilePackage("fpc",
      realizationTargetFor(pcX86_64, poWindows, mlX86_64_v1), @[rkTarball])
    check resolution.archiveRoute == arExtract
    let res = resolution.archive
    check res.installMethod == imInstallerInnoSetup
    check res.digestAlgorithm == "sha1"
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
      check "the innounp dependency edge left no receipt" in outcome.stderr
      check not fileExists(edges.rootReceipt)
    else:
      let host = hostRealizationTarget()
      var refused = false
      try:
        discard realizeBuiltinPackage(store, res)
      except ValueError as err:
        refused = true
        check "no tarball provisioning entry for package \"fpc\"" in err.msg
        check "matches host cpu=" & $host.platform.family & " os=" & $host.os in err.msg
      check refused
    check listPrefixes(store).len == 0
    for prefix in walkDirs(storeDir / "prefixes" / "fpc" / "*"):
      checkpoint(prefix)
      check false

  test "m4_innosetup_compatibility_discovery_missing_helper_fails_closed":
    ## The exported compatibility discovery API keeps its typed diagnostic;
    ## production realization instead requires the helper's dependency receipt.
    let fixtureDir = FixtureRoot / "fpc-compatibility-discovery"
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
      discard discoverInnounpExe(store, "fpc")
    except EBuiltinInnounpUnavailable as err:
      raised = true
      check err.packageId == "fpc"
      check err.discoveryTrace.len >= 2
      check "catalog-prefix:scanned 0 rows" in err.discoveryTrace[0]
      check "path:no" in err.discoveryTrace[^1]
      check "repro home add innounp" in err.msg
    check raised
    check listPrefixes(store).len == 0
