## Recipe uses and home references realize the same archive record, including
## extractPath and allowlisted pre-install actions combined with strip, prune
## and executable aliases. Real tar, filesystem, digest verifier, action graph
## and store; no mocks or network. A malformed digest must leave no prefix.
import std/[os, json, osproc, strutils, tables, tempfiles, unittest]
import repro_interface_artifacts
import repro_dsl_stdlib/packages_schema
import repro_tool_profiles
import repro_tool_profiles/archive_digest
import repro_home_apply/builtin_adapter
import repro_home_apply/[package_catalog, realize]
import repro_local_store
from repro_project_dsl import PackageDef, TarballProvisioningDef,
  registerPackageDef, registeredPackages, resetPackageRegistry

# A real native fixture installer, run as its own child process. It receives
# the same NSIS-style /D argument production supplies and writes a payload;
# no test-only installer bypass is enabled in the provisioner.
if paramCount() > 0 and paramStr(1) == "--fixture-installer":
  var destination = ""
  for arg in commandLineParams():
    if arg.startsWith("/D="): destination = arg[3 .. ^1]
  doAssert destination.len > 0
  createDir(destination / "bin")
  copyFile(getAppFilename(), destination / "bin" / "tool")
  when not defined(windows):
    setFilePermissions(destination / "bin" / "tool",
      {fpUserRead, fpUserWrite, fpUserExec})
  writeFile(destination / "discard", "prune after install")
  quit(0)

proc cleanup(root: string) =
  for p in walkDirRec(root, yieldFilter = {pcFile, pcDir}):
    try: setFilePermissions(p, {fpUserRead, fpUserWrite, fpUserExec})
    except OSError: discard
  removeDir(root)

suite "one tarball provisioning realizer":
  setup:
    let suiteSavedCache = getEnv("REPRO_CACHE_DISABLE")
    putEnv("REPRO_CACHE_DISABLE", "1")
  teardown:
    if suiteSavedCache.len > 0: putEnv("REPRO_CACHE_DISABLE", suiteSavedCache)
    else: delEnv("REPRO_CACHE_DISABLE")
  test "mixed archive and installation fields are realized as one edge":
    let root = createTempDir("repro-one-tarball-", "")
    defer: cleanup(root)
    let savedCache = getEnv("REPRO_CACHE_DISABLE")
    putEnv("REPRO_CACHE_DISABLE", "1")
    defer:
      if savedCache.len > 0: putEnv("REPRO_CACHE_DISABLE", savedCache)
      else: delEnv("REPRO_CACHE_DISABLE")
    let source = root / "source"
    createDir(source / "outer" / "payload")
    let script = source / "outer" / "payload" / "original"
    writeFile(script, "#!/bin/sh\necho one-realizer\n")
    setFilePermissions(script, {fpUserRead, fpUserWrite, fpUserExec})
    writeFile(source / "outer" / "payload" / "discard", "unwanted")
    let archive = root / "fixture.tar.gz"
    let tar = findExe("tar")
    doAssert tar.len > 0, "tar fixture builder is required"
    let packed = execCmdEx(quoteShell(tar) & " -czf " & quoteShell(archive) &
      " -C " & quoteShell(source) & " outer")
    doAssert packed.exitCode == 0, packed.output
    var record = InterfaceTarballProvisioning(url: "file://" & archive,
      sha256: fileSha256Hex(archive), archiveType: "tar.gz",
      executablePath: "tool", executableAlias: "alias", stripComponents: 1,
      prunePaths: @["discard"], cpu: "any", os: "any",
      packageId: "one-realizer@1")
    record.detail.extractPath = "payload"
    record.detail.preInstall = @[preInstallAction("move-item", "${prefix}/original", "${prefix}/tool")]
    var useDef = InterfaceToolUse(rawConstraint: "one-realizer",
      packageSelector: "one-realizer", executableName: "tool",
      tarballProvisioning: @[record])
    let profile = resolveTarballTool(useDef, root / "store")
    check fileExists(profile.selectedStorePath / "tool")
    check fileExists(profile.selectedStorePath / "alias")
    check not fileExists(profile.selectedStorePath / "discard")
    check not dirExists(profile.selectedStorePath / "payload")
    var homeStore = openStore(root / "store")
    let home = realizeBuiltinPackage(homeStore,
      archiveRealizationOf("one-realizer", record))
    check home.prefixAbsolutePath == profile.selectedStorePath
    check home.cacheHit
    homeStore.close()
    let warm = resolveTarballTool(useDef, root / "store")
    check warm.selectedStorePath == profile.selectedStorePath
    check readFile(warm.selectedStorePath / "alias") == readFile(script)

  test "SHA512 and SHA1 share verification and malformed digests publish nothing":
    let root = createTempDir("repro-one-digest-", "")
    defer: cleanup(root)
    let payload = root / "tool"
    writeFile(payload, "abc")
    check fileShaHex(payload, "sha1") ==
      "a9993e364706816aba3e25717850c26c9cd0d89d"
    check fileShaHex(payload, "sha512") ==
      "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a" &
      "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
    writeFile(payload, "#!/bin/sh\necho digest\n")
    var record = InterfaceTarballProvisioning(url: "file://" & payload,
      archiveType: "raw", executablePath: "tool", cpu: "any", os: "any")
    record.detail.sha512 = fileShaHex(payload, "sha512")
    var useDef = InterfaceToolUse(rawConstraint: "digest-tool",
      packageSelector: "digest-tool", executableName: "tool",
      tarballProvisioning: @[record])
    let profile = resolveTarballTool(useDef, root / "sha512-store")
    check readFile(profile.resolvedExecutablePath) == readFile(payload)
    var catalog = ProfileCatalog()
    catalog.uses["digest-tool"] = useDef
    let selection = resolveProfilePackage("digest-tool", hostRealizationTarget(),
      @[rkTarball], catalog = catalog)
    var homeStore = openStore(root / "sha512-store")
    let home = realizeResolution(homeStore, selection)
    check home.adapter == akTarball
    check home.prefixAbsolutePath == profile.selectedStorePath
    check home.resolvedExecutablePath == profile.resolvedExecutablePath
    check home.digestAlgorithm == "sha512"
    check home.digestValue == record.detail.sha512
    record.detail.sha512 = ""
    record.detail.sha1 = fileShaHex(payload, "sha1")
    useDef.tarballProvisioning = @[record]
    let weak = resolveTarballTool(useDef, root / "sha1-store")
    check readFile(weak.resolvedExecutablePath) == readFile(payload)
    record.detail.sha1 = repeat('0', 40)
    useDef.tarballProvisioning = @[record]
    try:
      discard resolveTarballTool(useDef, root / "bad-store")
      check false
    except EBuiltinDigestMismatch as err:
      check "sha1 mismatch" in err.msg
      check err.packageId == "digest-tool"
      check err.expectedAlgorithm == "sha1"
      check err.expectedDigest == repeat('0', 40)
      check err.observedDigest == fileShaHex(payload, "sha1")
    for path in walkDirRec(root / "bad-store" / "prefixes"):
      check not path.endsWith(".repro-receipt")
    for path in walkDirs(root / "bad-store" / "prefixes" / "*" / "*"):
      checkpoint path
      check false
    record.detail.sha1 = "not-a-digest"
    useDef.tarballProvisioning = @[record]
    expect ValueError:
      discard resolveTarballTool(useDef, root / "malformed-store")
    check not dirExists(root / "malformed-store" / "prefixes")
    # A mismatching source is not fatal when a later mirror supplies the
    # promised bytes; structured failure is raised only after exhaustion.
    let corrupt = root / "corrupt"
    writeFile(corrupt, "different bytes")
    record.detail.sha1 = fileShaHex(payload, "sha1")
    record.url = "file://" & corrupt
    record.mirrors = @["file://" & payload]
    useDef.tarballProvisioning = @[record]
    let mirrored = resolveTarballTool(useDef, root / "mirror-store")
    check mirrored.tarballSelectedUrl == "file://" & payload
    check readFile(mirrored.resolvedExecutablePath) == readFile(payload)

  test "launcher helper is a dependency and its changed pin changes the prefix":
    let root = createTempDir("repro-one-helper-", "")
    defer: cleanup(root)
    var admin = InterfaceTarballProvisioning()
    admin.detail.preInstall = @[preInstallAction("expand-msi",
      "${prefix}/absent.msi", "${prefix}/unpack")]
    check installationToolRoles(admin) == @["lessmsi"]
    admin.detail.msiAdminInstall = true
    check installationToolRoles(admin).len == 0
    var bindings: seq[tuple[name, value: string]]
    try:
      runPreInstallActions("admin-fixture", root,
        @[decodePreInstallAction(admin.detail.preInstall[0])], @[], "", bindings,
        msiAdminInstallOverride = true, honorAmbientOverride = false)
      check false
    except EBuiltinExtractFailed as err:
      # Explicit admin mode bypasses an unneeded lessmsi helper and reaches
      # validation of the declared source before attempting OS extraction.
      check "source missing" in err.msg
    let registered = registeredPackages()
    defer:
      resetPackageRegistry()
      for package in registered: registerPackageDef(package)
    let interpreter = root / "interpreter"
    writeFile(interpreter, "#!/bin/sh\necho interpreter-one\n")
    let payload = root / "payload"
    writeFile(payload, "#!/bin/sh\necho payload\n")
    var record = InterfaceTarballProvisioning(url: "file://" & payload,
      sha256: fileSha256Hex(payload), archiveType: "raw",
      executablePath: "payload.phar", cpu: "any", os: "any")
    record.detail.launcherEmit = @[launcherEmitSpec("phar", "payload.phar",
      "fixture-interpreter", "fixture")]
    let useDef = InterfaceToolUse(rawConstraint: "helper-consumer",
      packageSelector: "helper-consumer", executableName: "payload",
      tarballProvisioning: @[record])
    proc registerInterpreter() =
      resetPackageRegistry()
      for package in registered: registerPackageDef(package)
      registerPackageDef(PackageDef(packageName: "fixture-interpreter",
        tarballProvisioning: @[TarballProvisioningDef(
          url: "file://" & interpreter, sha256: fileSha256Hex(interpreter),
          archiveType: "raw", executablePath: "interpreter",
          cpu: "any", os: "any")]))
    registerInterpreter()
    let edges = tarballProvisioningEdges(useDef, root / "store")
    check edges.actions.len == 2
    check edges.actions[^1].deps.len == 1
    check edges.actions[^1].inputs.len == 1
    let first = resolveTarballTool(useDef, root / "store")
    let launcher = readFile(first.selectedStorePath / "bin" / "fixture.ps1")
    check "Join-Path $PSScriptRoot" in launcher
    check root notin launcher
    # Helpers outside this store (for example immutable Nix store tools)
    # retain their absolute identity when a cached consumer moves in depth.
    let externalInterpreter = getAppFilename()
    for consumer in [root / "external-store" / "prefixes" / "consumer" / "pin",
        root / "deeper" / "external-store" / "prefixes" / "consumer" / "pin"]:
      let staging = consumer & "-staging"
      runLauncherEmit("external-consumer", "1", staging,
        @[LauncherEmitSpec(kind: lekPhar, target: "payload.phar",
          launcher_name: "external")], @[externalInterpreter],
        installedPrefix = consumer)
      check ("& '" & externalInterpreter & "'") in
        readFile(staging / "bin" / "external.ps1")
      check ("\"" & externalInterpreter & "\"") in
        readFile(staging / "bin" / "external.cmd")
    let warm = resolveTarballTool(useDef, root / "store")
    check warm.selectedStorePath == first.selectedStorePath
    writeFile(interpreter, "#!/bin/sh\necho interpreter-two\n")
    registerInterpreter()
    let second = resolveTarballTool(useDef, root / "store")
    check second.selectedStorePath != first.selectedStorePath
    check readFile(second.selectedStorePath / "bin" / "fixture.ps1") != launcher
    # A failed helper pin blocks the consumer before creating a replacement
    # prefix. Existing successful prefixes remain intact.
    removeFile(interpreter)
    resetPackageRegistry()
    for package in registered: registerPackageDef(package)
    registerPackageDef(PackageDef(packageName: "fixture-interpreter",
      tarballProvisioning: @[TarballProvisioningDef(
        url: "file://" & interpreter, sha256: repeat('a', 64),
        archiveType: "raw", executablePath: "interpreter", cpu: "any", os: "any")]))
    try:
      discard resolveTarballTool(useDef, root / "missing-helper-store")
      check false
    except OSError as err:
      check "fixture-interpreter" in err.msg
      check "file URL does not exist" in err.msg
    for prefix in walkDirs(root / "missing-helper-store" / "prefixes" / "helper-consumer" / "*"):
      checkpoint prefix
      check false
    # The reserved script kind has no emitter yet. Refuse it while planning,
    # before constructing helper edges or entering the old defensive assert.
    var unsupported = useDef
    unsupported.tarballProvisioning[0].detail.launcherEmit = @[
      launcherEmitSpec("script", "payload.phar", "bash", "fixture")]
    try:
      discard tarballAcquisitionPlan(unsupported)
      check false
    except ValueError as err:
      check "helper-consumer" in err.msg
      check "script launcher" in err.msg
      check "not supported" in err.msg

  test "silent native installer runs inside the same provisioning edge":
    let root = createTempDir("repro-one-installer-", "")
    defer: cleanup(root)
    let installer = getAppFilename()
    var record = InterfaceTarballProvisioning(url: "file://" & installer,
      sha256: fileSha256Hex(installer), archiveType: "installer-nsis",
      executablePath: "bin/tool", executableAlias: "tool-alias",
      prunePaths: @["discard"], cpu: "any", os: "any")
    record.detail.installMethod = "installer-silent"
    record.detail.installerArgs = @["--fixture-installer"]
    let useDef = InterfaceToolUse(rawConstraint: "native-installer",
      packageSelector: "native-installer", executableName: "tool",
      tarballProvisioning: @[record])
    let profile = resolveTarballTool(useDef, root / "store")
    check fileExists(root / "store" / "downloads" / (record.sha256 & ".exe"))
    check fileExists(profile.selectedStorePath / "bin" / "tool")
    check fileExists(profile.selectedStorePath / "bin" / "tool-alias")
    check not fileExists(profile.selectedStorePath / "discard")
    let metadata = parseFile(profile.selectedStorePath / ".repro-installation.json")
    check metadata["installerArgvUsed"][^1].getStr() == "/D=${prefix}"
    check root notin $metadata
