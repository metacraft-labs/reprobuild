import std/[os, osproc, sets, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_project_dsl
import repro_tool_profiles

proc tool(name: string): InterfaceToolUse =
  InterfaceToolUse(rawConstraint: name, packageSelector: name,
    executableName: name)

proc executable(path: string; body = "#!/bin/sh\nexit 0\n") =
  createDir(parentDir(path))
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc recipe(root, name: string; deps: seq[InterfaceToolUse] = @[];
            runtime = false; installed = true): string =
  let dir = root / name
  createDir(dir)
  writeFile(dir / "repro.nim", "# synthetic source recipe\n")
  let metadata = dir / ".repro/build/repro/project-interface.rbsz"
  createDir(parentDir(metadata))
  writeInterfaceArtifact(metadata, artifactFor(ProjectInterface(
    projectName: name, packageName: name, toolUses: deps,
    runtimeToolUses: (if runtime: deps else: @[]))))
  result = dir / ".repro/output/install/usr"
  if installed:
    executable(result / "bin" / name)
    createDir(result / "lib")
    createDir(result / "include")
    createDir(result / "lib/pkgconfig")

proc missingTarball(root, name: string): InterfaceToolUse =
  result = tool(name)
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    url: "file://" & root / "unavailable.tar.gz", sha256: "0".repeat(64),
    archiveType: "tar.gz", executablePath: "bin/" & name,
    packageId: name & "@1", cpu: "any", os: "any",
    lockIdentity: "unavailable:" & name)]

proc identity(root: string): PathOnlyBuildIdentity =
  toolBuildIdentity(artifactFor(ProjectInterface(projectName: "consumer",
    packageName: "consumer", toolUses: @[tool("compiler")])),
    tpmFromSource, pathValue = root / "ambient", storeRoot = root / "store")

proc localTarball(root: string; version = "1"): InterfaceToolUse =
  let payload = root / ("payload-" & version)
  executable(payload / "bin/assembler", "#!/bin/sh\necho provider-" & version & "\n")
  createDir(payload / "lib")
  writeFile(payload / "lib/libassembler.so", "fixture-library")
  let archive = root / ("assembler-" & version & ".tar.gz")
  let packed = execCmdEx("tar -czf " & quoteShell(archive) &
    " -C " & quoteShell(payload) & " .")
  if packed.exitCode != 0:
    raise newException(OSError, packed.output)
  let hashed = execCmdEx("sha256sum " & quoteShell(archive))
  if hashed.exitCode != 0:
    raise newException(OSError, hashed.output)
  result = missingTarball(root, "assembler")
  result.tarballProvisioning[0].url = "file://" & archive
  result.tarballProvisioning[0].sha256 = hashed.output.splitWhitespace()[0]
  result.tarballProvisioning[0].packageId = "assembler@" & version
  result.tarballProvisioning[0].lockIdentity = "fixture:assembler@" & version

suite "cached source dependency closure":
  setup:
    let root = createTempDir("source-closure-", "")
    let savedRoot = getEnv(FromSourceRootEnvVar)
    let savedCycles = fromSourceCycleBrokenTools
    putEnv(FromSourceRootEnvVar, root)
    fromSourceCycleBrokenTools = initHashSet[string]()

  teardown:
    fromSourceCycleBrokenTools = savedCycles
    if savedRoot.len > 0: putEnv(FromSourceRootEnvVar, savedRoot)
    else: delEnv(FromSourceRootEnvVar)
    removeDir(root)

  test "cached compiler rejects an unavailable runtime bootstrap provider":
    discard recipe(root, "compiler", @[missingTarball(root, "binutils")],
      runtime = true)
    discard recipe(root, "binutils", installed = false)
    fromSourceCycleBrokenTools.incl("binutils")
    expect OSError:
      discard identity(root)

  test "legacy build dependency without a provider fails closed":
    discard recipe(root, "compiler", @[tool("missing-library")])
    executable(root / "ambient/missing-library")
    expect OSError:
      discard identity(root)

  test "unbuilt non-floor source dependency cannot be silently skipped":
    discard recipe(root, "compiler", @[tool("assembler")])
    discard recipe(root, "assembler", installed = false)
    expect OSError:
      discard identity(root)

  test "transitive source closure terminates cycles and fingerprints providers":
    discard recipe(root, "compiler", @[tool("middle")])
    discard recipe(root, "middle", @[tool("leaf")])
    let leaf = recipe(root, "leaf", @[tool("compiler")])
    let before = identity(root)
    require before.profiles.len == 1
    check leaf / "lib" in before.profiles[0].libraryPathList
    check leaf / "bin" in before.actionIdentities[0].pathSearchList
    executable(leaf / "bin/leaf", "#!/bin/sh\nexit 1\n")
    let after = identity(root)
    check before.profiles[0].profileFingerprint != after.profiles[0].profileFingerprint
    check before.actionIdentities[0].actionFingerprint !=
      after.actionIdentities[0].actionFingerprint

  test "completed source provider takes precedence over unavailable bootstrap":
    discard recipe(root, "compiler", @[missingTarball(root, "binutils")])
    let binutils = recipe(root, "binutils")
    fromSourceCycleBrokenTools.incl("binutils")
    let resolved = identity(root)
    require resolved.profiles.len == 1
    check binutils / "bin" in resolved.profiles[0].pathSearchList
    check root / "binutils" in resolved.profiles[0].realizedStorePaths
    check root / "ambient" notin resolved.profiles[0].pathSearchList

  test "native build dependencies do not enter the consumed source closure":
    var native = tool("build-generator")
    native.depKind = "native"
    discard recipe(root, "compiler", @[native])
    let withoutNative = identity(root)
    let generator = recipe(root, "build-generator", @[tool("missing-build-tool")])
    let withNative = identity(root)
    check generator / "bin" notin withNative.profiles[0].pathSearchList
    check generator / "lib" notin withNative.profiles[0].libraryPathList
    check withoutNative.actionIdentities[0].actionFingerprint ==
      withNative.actionIdentities[0].actionFingerprint

  test "interface projection and codec preserve dependency roles":
    let projected = toProjectInterface(PackageDef(packageName: "roles",
      toolUses: @[PackageUseDef(packageSelector: "linked", depKind: "target")],
      nativeBuildDeps: @[PackageUseDef(packageSelector: "generator", depKind: "native")],
      runtimeDeps: @[PackageUseDef(packageSelector: "loader", depKind: "runtime")]))
    let decoded = decodeInterfacePayload(encodeInterfacePayload(projected))
    require decoded.toolUses.len == 3
    check decoded.toolUses[0].depKind == "target"
    check decoded.toolUses[1].depKind == "native"
    check decoded.toolUses[2].depKind == "runtime"
    check decoded.runtimeToolUses[0].depKind == "runtime"
    var changedRole = projected
    changedRole.toolUses[1].depKind = "runtime"
    check artifactFor(projected).interfaceFingerprint !=
      artifactFor(changedRole).interfaceFingerprint
    let legacy = decodeInterfacePayload(encodeInterfacePayload(projected, 14), 14)
    require legacy.toolUses.len == 3
    check legacy.toolUses[1].depKind == ""

  test "cache-only source inherits declared fallback paths and identity":
    when defined(windows):
      skip()
    else:
      let dep = localTarball(root)
      discard recipe(root, "compiler", @[dep])
      discard recipe(root, "assembler", @[tool("unselected-build-dependency")],
        installed = false)
      let assemblerInterface = root / "assembler/.repro/build/repro/project-interface.rbsz"
      var assembler = readInterfaceArtifact(assemblerInterface).projectInterface
      assembler.runtimeToolUses = @[tool("runtime-loader")]
      writeInterfaceArtifact(assemblerInterface, artifactFor(assembler))
      let loader = recipe(root, "runtime-loader")
      fromSourceCycleBrokenTools.incl("assembler")
      let resolved = identity(root)
      require resolved.profiles.len == 1
      let profile = resolved.profiles[0]
      var inherited = ""
      for path in profile.pathSearchList:
        if fileExists(path / "assembler"):
          inherited = path
      check inherited.len > 0
      check root / "ambient" notin profile.pathSearchList
      check profile.realizedStorePaths.len > 1
      check loader / "bin" in profile.pathSearchList
      check profile.lockIdentity.contains(":closure:")
      check resolved.actionIdentities[0].lockIdentity == profile.lockIdentity

  test "fallback without a recipe never traverses caller metadata":
    when defined(windows):
      skip()
    else:
      discard recipe(root, "compiler", @[localTarball(root)])
      discard recipe(root, "caller", @[tool("poisoned-caller-dependency")],
        runtime = true)
      let savedCwd = getCurrentDir()
      setCurrentDir(root / "caller")
      defer: setCurrentDir(savedCwd)
      let resolved = identity(root)
      require resolved.profiles.len == 1
      check resolved.profiles[0].realizedStorePaths.len > 1
      check root / "caller" notin resolved.profiles[0].realizedStorePaths

  test "directly selected fallback inherits and fingerprints its runtime closure":
    when defined(windows):
      skip()
    else:
      let dep = localTarball(root)
      discard recipe(root, "assembler", @[tool("runtime-loader")],
        runtime = true, installed = false)
      let loader = recipe(root, "runtime-loader")
      fromSourceCycleBrokenTools.incl("assembler")
      let consumer = artifactFor(ProjectInterface(projectName: "consumer", toolUses: @[dep]))
      let before = toolBuildIdentity(consumer, tpmFromSource, storeRoot = root / "store")
      require before.profiles.len == 1
      check loader / "bin" in before.profiles[0].pathSearchList
      check loader / "lib" in before.profiles[0].libraryPathList
      executable(loader / "bin/runtime-loader", "#!/bin/sh\nexit 1\n")
      let after = toolBuildIdentity(consumer, tpmFromSource, storeRoot = root / "store")
      check before.actionIdentities[0].actionFingerprint != after.actionIdentities[0].actionFingerprint

  test "historical fallback paths cannot shadow the currently selected provider":
    when defined(windows):
      skip()
    else:
      let oldUse = localTarball(root, "1")
      let oldIdentity = toolBuildIdentity(artifactFor(ProjectInterface(
        projectName: "compiler", toolUses: @[oldUse])), tpmFromSource,
        storeRoot = root / "store")
      let newUse = localTarball(root, "2")
      discard recipe(root, "compiler", @[newUse])
      let record = root / "compiler/.repro/build/repro/from-source-tool-identities.rbtp"
      writePathOnlyBuildIdentity(record, oldIdentity)
      let resolved = identity(root)
      require resolved.profiles.len == 1
      let oldBin = parentDir(oldIdentity.profiles[0].resolvedExecutablePath)
      check oldBin notin resolved.profiles[0].pathSearchList
      var selected = ""
      for path in resolved.profiles[0].pathSearchList:
        if fileExists(path / "assembler"):
          selected = path / "assembler"
          break
      require selected.len > 0
      check execCmdEx(quoteShell(selected)).output.strip() == "provider-2"
      removeFile(record)
      let withoutHistory = identity(root)
      check resolved.actionIdentities[0].actionFingerprint ==
        withoutHistory.actionIdentities[0].actionFingerprint
