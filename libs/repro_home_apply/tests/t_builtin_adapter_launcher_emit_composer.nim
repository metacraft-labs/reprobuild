## Composer-style payload and launcher realization through the shared edge.
## Artifacts and the interpreter declaration use real local file URLs. The
## fixture interpreter is a real provisioned executable payload (not invoked:
## these cases validate launcher generation, dependency receipts and prefix
## reuse). No store rows, discovery adapters or network servers are mocked.

import std/[os, strutils, unittest]
from repro_core/paths import extendedPath

import repro_local_store
import repro_dsl_stdlib/packages_schema
import repro_interface_artifacts
import repro_tool_profiles
from repro_project_dsl import PackageDef, TarballProvisioningDef,
  registerPackageDef, registeredPackages, resetPackageRegistry

import repro_home_apply/package_catalog
import repro_home_apply/builtin_adapter
from repro_test_support import testCaseScratchSlug

let FixtureRoot = "build/test-tmp/t-builtin-adapter-launcher-emit-composer" /
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

proc writePayloadFile(path: string; content: string): string =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), content)
  fileShaHex(path, "sha256")

const FixturePhpPackage = "fixture-php-for-launcher"

proc declarePhpPayload(path: string; sha256: string) =
  registerPackageDef(PackageDef(packageName: FixturePhpPackage,
    tarballProvisioning: @[TarballProvisioningDef(
      url: fileToUrl(absolutePath(path)), sha256: sha256,
      archiveType: "raw", executablePath: "php.exe", cpu: "any", os: "any")]))

proc realizePhpFixture(store: var Store; content: string): string =
  ## Declare and realize the fixture through its actual provisioning edge.
  let payload = store.root / "fixture-interpreter"
  let digest = writePayloadFile(payload, content)
  declarePhpPayload(payload, digest)
  let useDef = extractorToolUses(FixturePhpPackage)[0]
  resolveTarballTool(useDef, store.root).selectedStorePath

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

suite "M5 — shared tarball edge launcher emit (composer .phar)":
  setup:
    let registered = registeredPackages()
    let savedCache = getEnv("REPRO_CACHE_DISABLE")
    putEnv("REPRO_CACHE_DISABLE", "1")
  teardown:
    resetPackageRegistry()
    for package in registered: registerPackageDef(package)
    if savedCache.len > 0: putEnv("REPRO_CACHE_DISABLE", savedCache)
    else: delEnv("REPRO_CACHE_DISABLE")

  test "test_m5_launcher_emit_composer_phar_realize_synthesizes_ps1_and_cmd":
    ## End-to-end realize of a synthetic composer catalog entry. The
    ## .phar payload is downloaded via file://, copied to the prefix
    ## root via afRaw with the launcher_emit-aware target redirect,
    ## then the launcher emit step writes bin/composer.ps1 +
    ## bin/composer.cmd. Both launchers reference the declared interpreter
    ## through a path relative to the final launcher directory.
    let fixtureDir = FixtureRoot / "phar-realize"
    let storeDir = fixtureDir / "store"
    let payloadDir = fixtureDir / "payload"
    resetDir(fixtureDir); resetDir(storeDir); resetDir(payloadDir)

    var store = openStore(storeDir)
    defer: store.close()

    # Declare the interpreter as a package and realize it through its edge.
    let phpPrefixAbs = realizePhpFixture(store, "#!/bin/sh\nexit 0\n")
    let expectedPhpExe = phpPrefixAbs / "php.exe"
    check fileExists(extendedPath(expectedPhpExe))

    let payload = "<?php /* fake composer phar bytes */ ?>\n"
    let payloadPath = payloadDir / "composer.phar"
    let sha = writePayloadFile(payloadPath, payload)
    let url = fileToUrl(absolutePath(payloadPath))

    # The record has the shape of the REAL stdlib composer realization:
    # its Windows `tarball` record decodes to this very launcher spec.
    let stdlibComposer = resolveProfilePackage("composer",
      realizationTargetFor(pcX86_64, poWindows, mlX86_64_v1), @[rkTarball])
    check stdlibComposer.archiveRoute == arExtract
    check stdlibComposer.archive.launcherEmit == @[LauncherEmitSpec(
      kind: lekPhar, target: "composer.phar", interpreter_package_id: "php",
      launcher_name: "composer")]
    check stdlibComposer.archive.binRelpath ==
      @["bin/composer.ps1", "bin/composer.cmd"]

    let res = selectArchive("composer", [hostRecord(url, "raw", "bin/composer.ps1", @["bin/composer.cmd"],
      sha256 = sha, version = "2.10.0", anyCpu = true,
      launcherEmit = @[launcherEmitSpec("phar", "composer.phar", FixturePhpPackage,
        "composer")])])
    check res.launcherEmit.len == 1
    check res.launcherEmit[0].kind == lekPhar
    check res.launcherEmit[0].target == "composer.phar"

    let consumer = InterfaceToolUse(rawConstraint: "composer",
      packageSelector: "composer", executableName: "composer",
      tarballProvisioning: @[archiveRecordOf(res)])
    let edges = tarballProvisioningEdges(consumer, store.root)
    check edges.actions.len == 2
    check edges.actions[^1].deps.len == 1
    check edges.actions[^1].inputs.len == 1
    let outR = realizeBuiltinPackage(store, res)
    check (not outR.cacheHit)
    let prefixAbs = outR.prefixAbsolutePath

    # The .phar payload landed at the prefix root.
    let realizedPhar = prefixAbs / "composer.phar"
    check fileExists(extendedPath(realizedPhar))
    check readFile(extendedPath(realizedPhar)) == payload

    # Both launchers exist.
    let ps1Path = prefixAbs / "bin" / "composer.ps1"
    let cmdPath = prefixAbs / "bin" / "composer.cmd"
    check fileExists(extendedPath(ps1Path))
    check fileExists(extendedPath(cmdPath))

    # Launcher contents reference the provisioned PHP through a relative path
    # and the .phar target VIA $PSScriptRoot / %~dp0 (relative to the
    # launcher's own bin/ directory so the launcher works after
    # realizePrefix's atomic rename).
    let ps1Body = readFile(extendedPath(ps1Path))
    let relativePhp = relativePath(expectedPhpExe, prefixAbs / "bin").replace('/', '\\')
    check ps1Body.contains("Join-Path $PSScriptRoot '" & relativePhp & "'")
    check not ps1Body.contains(absolutePath(storeDir))
    check ps1Body.contains("$PSScriptRoot")
    check ps1Body.contains("composer.phar")
    check ps1Body.contains("lekPhar")
    # The target is referenced relative to bin/ (one dir up).
    check ps1Body.contains("..\\composer.phar")

    let cmdBody = readFile(extendedPath(cmdPath))
    check cmdBody.contains("%~dp0" & relativePhp)
    check not cmdBody.contains(absolutePath(storeDir))
    check cmdBody.contains("%~dp0")
    check cmdBody.contains("composer.phar")
    check cmdBody.contains("..\\composer.phar")

  test "test_m5_launcher_emit_idempotent_bytes_across_reruns":
    ## A second realize against the same inputs is a cache-hit (the
    ## prefix digest covers the launcher bytes; identical inputs
    ## produce identical output). Verify by capturing the realized
    ## prefix path on run 1, re-running with the source payload
    ## removed, and checking the launcher bytes match.
    let fixtureDir = FixtureRoot / "phar-idempotent"
    let storeDir = fixtureDir / "store"
    let payloadDir = fixtureDir / "payload"
    resetDir(fixtureDir); resetDir(storeDir); resetDir(payloadDir)
    var store = openStore(storeDir)
    defer: store.close()
    discard realizePhpFixture(store, "#!/bin/sh\nexit 0\n")

    let payload = "<?php /* idempotent */ ?>\n"
    let payloadPath = payloadDir / "composer.phar"
    let sha = writePayloadFile(payloadPath, payload)
    let url = fileToUrl(absolutePath(payloadPath))

    let res = selectArchive("composer", [hostRecord(url, "raw", "bin/composer.ps1", @["bin/composer.cmd"],
      sha256 = sha, version = "2.10.0", anyCpu = true,
      launcherEmit = @[launcherEmitSpec("phar", "composer.phar", FixturePhpPackage,
        "composer")])])

    let out1 = realizeBuiltinPackage(store, res)
    check (not out1.cacheHit)
    let ps1Bytes1 = readFile(extendedPath(
      out1.prefixAbsolutePath / "bin" / "composer.ps1"))
    let cmdBytes1 = readFile(extendedPath(
      out1.prefixAbsolutePath / "bin" / "composer.cmd"))

    # Remove the source so a second download FAILS; the cache-hit must
    # skip download AND launcher emit (the prefix is already realized).
    removeFile(extendedPath(payloadPath))
    let out2 = realizeBuiltinPackage(store, res)
    check out2.cacheHit
    check out2.prefixId == out1.prefixId
    let ps1Bytes2 = readFile(extendedPath(
      out2.prefixAbsolutePath / "bin" / "composer.ps1"))
    let cmdBytes2 = readFile(extendedPath(
      out2.prefixAbsolutePath / "bin" / "composer.cmd"))
    check ps1Bytes1 == ps1Bytes2
    check cmdBytes1 == cmdBytes2

  test "test_m5_launcher_emit_declared_interpreter_failure_blocks_consumer":
    let fixtureDir = FixtureRoot / "phar-no-php"
    let storeDir = fixtureDir / "store"
    let payloadDir = fixtureDir / "payload"
    resetDir(fixtureDir); resetDir(storeDir); resetDir(payloadDir)
    let payloadPath = payloadDir / "composer.phar"
    let sha = writePayloadFile(payloadPath, "stub-phar\n")
    declarePhpPayload(payloadDir / "absent-interpreter", "a".repeat(64))
    var store = openStore(storeDir)
    defer: store.close()
    let res = selectArchive("composer", [hostRecord(
      fileToUrl(absolutePath(payloadPath)), "raw", "bin/composer.ps1",
      @["bin/composer.cmd"], sha256 = sha, version = "2.10.0", anyCpu = true,
      launcherEmit = @[launcherEmitSpec("phar", "composer.phar",
        FixturePhpPackage, "composer")])])
    var raised = false
    try:
      discard realizeBuiltinPackage(store, res)
    except OSError as err:
      raised = true
      check FixturePhpPackage in err.msg
      check "file URL does not exist" in err.msg
    check raised
    for row in listPrefixes(store):
      check row.packageName != "composer"

  test "test_m5_schema_validator_rejects_launcher_name_not_in_bin_relpath":
    ## launcher_name typo / missing-from-bin_relpath is caught by the
    ## schema validator of the harvester's parse model
    ## (``VersionedProvisioning``; GM4b keeps it as the harvester's
    ## in-memory record). Sanity check that the validator catches the
    ## bin_relpath drift class.
    let vp = initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afRaw,
      install_method = imExtract,
      bin_relpath = @["bin/wrong.ps1"],
      platforms = @[
        initPlatformBinary(cpu = pcAny, os = poWindows,
          url = "file:///x",
          sha256 = "a".repeat(64))
      ],
      launcher_emit = @[
        LauncherEmitSpec(kind: lekPhar, target: "composer.phar",
          interpreter_package_id: "php", launcher_name: "composer")
      ])
    let errors = validateVersionedProvisioning(vp)
    var foundMismatch = false
    for err in errors:
      if "launcher_name 'composer'" in err and "bin_relpath" in err:
        foundMismatch = true
    check foundMismatch
