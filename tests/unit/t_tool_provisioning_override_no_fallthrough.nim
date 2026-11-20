## A per-tool provisioning override is exact: it never falls through to
## another mode's arm.
##
## What is asserted, each against a control showing the same tool WITHOUT the
## override takes the fall-through the override refuses:
##
##   * an override to a mode the package declares no arm for on this host
##     fails before ANY tool is realized -- a realizable tool listed before it
##     leaves nothing in the store -- with the refusal: the package, the
##     mode, the host platform, the override's source, and the modes the
##     package does declare an arm for;
##   * `tarball` never falls through to the package's source recipe;
##   * `from-source` never falls through to the package's archive;
##   * `nix` never takes the package's archive;
##   * a corrupted archive digest under an override fails the realization
##     and does not reach the same-named executable on PATH.
##
## No mocks: archives are real files behind `file://` URLs, the source recipe
## is a real catalog directory with a built artifact, and PATH is real.
## Resolution runs through `toolBuildIdentity`, the entry point `repro build`
## and the activation use.

import std/[os, sequtils, strutils, tables, tempfiles, unittest]

import repro_interface_artifacts
import repro_tool_profiles
import repro_test_support/process_fixtures

proc writeExecutable(path, body: string) =
  createDir(parentDir(path))
  writeFile(path, body)
  when not defined(windows):
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc archiveUse(name, dir: string; corrupt = false): InterfaceToolUse =
  ## A package whose only provisioning arm is a host archive.
  let payload = dir / (name & ".cmd")
  createDir(dir)
  writeFile(payload, "@echo " & name & " 1.0\n")
  let digest =
    if corrupt: "0".repeat(64) else: fileSha256Hex(payload)
  result = InterfaceToolUse(rawConstraint: name, packageSelector: name,
    executableName: name)
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    packageName: name, url: "file://" & payload.replace('\\', '/'),
    sha256: digest, archiveType: "raw",
    executablePath: "bin/" & name & ".cmd", packageId: name & "@1.0",
    lockIdentity: "tarball:" & name & "@1.0:" & digest)]

proc foreignArchiveUse(name: string): InterfaceToolUse =
  ## A package whose archive is for another OS: no host archive.
  result = InterfaceToolUse(rawConstraint: name, packageSelector: name,
    executableName: name)
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    packageName: name, url: "https://example.invalid/" & name & ".tar.gz",
    sha256: "0".repeat(64), archiveType: "tar.gz", executablePath: name,
    packageId: name & "@1.0",
    os: (when defined(windows): "linux" else: "windows"))]

proc artifactOf(uses: seq[InterfaceToolUse]): ProjectInterfaceArtifact =
  ProjectInterfaceArtifact(projectInterface: ProjectInterface(
    projectName: "t_tool_provisioning_override_no_fallthrough",
    toolUses: uses))

proc overriding(package: string; mode: ToolProvisioningMode):
    ToolModeSelections =
  result = initTable[string, ToolModeSelection]()
  result[package] = ToolModeSelection(mode: mode, overriddenBy: "flag",
    location: "--tool-provisioning-for=" & package & "=" &
      provisioningModeName(mode))

template withEnv(name, value: string; body: untyped) =
  let had = existsEnv(name)
  let saved = getEnv(name)
  putEnv(name, value)
  try:
    body
  finally:
    if had: putEnv(name, saved) else: delEnv(name)

proc builtRecipe(root, name: string): string =
  createDir(root / name)
  writeFile(root / name / "repro.nim", "## synthetic " & name & " recipe\n")
  let outDir = root / name / ".repro" / "output" / name
  result = outDir / (when defined(windows): name & ".exe" else: name)
  writeExecutable(result, "#!/bin/sh\nexit 0\n")

proc storeHasPrefixes(storeRoot: string): bool =
  dirExists(storeRoot / "prefixes") and
    toSeq(walkDirRec(storeRoot / "prefixes")).len > 0

suite "a per-tool provisioning override never falls through":
  putEnv("REPRO_CACHE_DISABLE", "1")
  let scratch = createTempDir("repro-override-exact-", "")
  releaseDirAtProcessExit(scratch)
  let recipes = scratch / "recipes"
  createDir(recipes)

  test "no arm for the overridden mode: refused before any tool is realized":
    let store = scratch / "store-noarm"
    let first = archiveUse("realizable", scratch / "a1")
    let target = archiveUse("archiveonly", scratch / "a2")
    try:
      discard toolBuildIdentity(artifactOf(@[first, target]), tpmTarball,
        storeRoot = store, selections = overriding("archiveonly", tpmNix))
      check false
    except ToolProvisioningNoArm as err:
      checkpoint err.msg
      check err.packageSelector == "archiveonly"
      check err.mode == "nix"
      check err.overriddenBy == "flag"
      check "archiveonly" in err.msg
      check " nix arm " in err.msg
      check hostPlatformName() in err.msg
      check "--tool-provisioning-for=archiveonly=nix" in err.msg
      check "tarball" in err.declaredModes
      check "tarball" in err.msg
    # The realizable tool before it was not realized either.
    check not storeHasPrefixes(store)
    # Control: without the override, nix mode takes the archive (the
    # catalog's nix-mode archive-only fallback).
    let control = toolBuildIdentity(artifactOf(@[target]), tpmNix,
      storeRoot = store)
    check control.profiles[0].installMethod == "tarball"

  test "tarball never falls through to the source recipe":
    discard builtRecipe(recipes, "sourceonly")
    withEnv(FromSourceRootEnvVar, recipes):
      let use = foreignArchiveUse("sourceonly")
      # Control: tarball mode realizes it from the source recipe.
      let control = toolBuildIdentity(artifactOf(@[use]), tpmTarball,
        storeRoot = scratch / "store-src")
      check control.profiles[0].installMethod == "from-source"
      expect ToolProvisioningNoArm:
        discard toolBuildIdentity(artifactOf(@[use]), tpmPathOnly,
          storeRoot = scratch / "store-src",
          selections = overriding("sourceonly", tpmTarball))

  test "from-source never falls through to the archive":
    withEnv(FromSourceRootEnvVar, recipes):
      let use = archiveUse("norecipe", scratch / "a3")
      # Control: from-source mode takes the stdlib arm (the archive).
      let control = toolBuildIdentity(artifactOf(@[use]), tpmFromSource,
        storeRoot = scratch / "store-fs")
      check control.profiles[0].installMethod == "tarball"
      expect ToolProvisioningNoArm:
        discard toolBuildIdentity(artifactOf(@[use]), tpmPathOnly,
          storeRoot = scratch / "store-fs",
          selections = overriding("norecipe", tpmFromSource))

  test "a corrupted archive digest under an override fails and does not reach PATH":
    let pathBin = scratch / "path-bin"
    writeExecutable(pathBin / "corrupt", "#!/bin/sh\necho corrupt 1.0\n")
    writeExecutable(pathBin / "corrupt.cmd", "@echo corrupt 1.0\n")
    let use = archiveUse("corrupt", scratch / "a4", corrupt = true)
    let pathValue = pathBin & $PathSep & getEnv("PATH")
    # Control: the path invocation finds it on PATH.
    let control = toolBuildIdentity(artifactOf(@[use]), tpmPathOnly,
      pathValue = pathValue, storeRoot = scratch / "store-c")
    check control.profiles[0].installMethod == "path"
    var failed = false
    try:
      let identity = toolBuildIdentity(artifactOf(@[use]), tpmPathOnly,
        pathValue = pathValue, storeRoot = scratch / "store-c",
        selections = overriding("corrupt", tpmTarball))
      checkpoint "resolved by " & identity.profiles[0].installMethod
    except ToolProvisioningNoArm:
      checkpoint "an arm exists; this must be a realization failure"
    except CatchableError as err:
      checkpoint err.msg
      failed = true
    check failed

  test "the override's arm realizes the tool and records its kind":
    let use = archiveUse("good", scratch / "a5")
    let identity = toolBuildIdentity(artifactOf(@[use]), tpmPathOnly,
      storeRoot = scratch / "store-good",
      selections = overriding("good", tpmTarball))
    check identity.profiles[0].installMethod == "tarball"
    check identity.profiles[0].kind == "tarball"
    check identity.profiles[0].overriddenBy == "flag"

  test "the declared modes are the arms this host has":
    # An empty recipe catalog, so the from-source arm is decided by this
    # fixture and not by whatever catalog the checkout sits beside.
    let emptyCatalog = scratch / "empty-catalog"
    createDir(emptyCatalog)
    withEnv(FromSourceRootEnvVar, emptyCatalog):
      let use = archiveUse("declared", scratch / "a6")
      check useDeclaresProvisioningArm(use, tpmTarball)
      check useDeclaresProvisioningArm(use, tpmPathOnly)
      check not useDeclaresProvisioningArm(use, tpmNix)
      check not useDeclaresProvisioningArm(use, tpmFromSource)
      check not useDeclaresProvisioningArm(foreignArchiveUse("f"), tpmTarball)
      check declaredProvisioningModes(use) == @["path", "tarball"]
      discard builtRecipe(emptyCatalog, "declared")
      check useDeclaresProvisioningArm(use, tpmFromSource)
