## M9.R.81 — per-dependency install-mirror root env vars.
##
## Pins the resolver-backed DEP_<name>_ROOT mechanism at three levels:
## name sanitization, raw dependency-list env generation, and the
## BuildActionDef registry surface the engine consumes.

import std/[envvars, os, strutils, unittest]

import repro_project_dsl

const MirrorModeEnv = "REPRO_INSTALL_MIRROR_MODE"

template withInstallMirrorEnv(modeValue, storeRootValue: string;
                              body: untyped) =
  block:
    let oldModeSet = existsEnv(MirrorModeEnv)
    let oldModeValue = getEnv(MirrorModeEnv)
    let oldStoreSet = existsEnv(StoreRootEnvVar)
    let oldStoreValue = getEnv(StoreRootEnvVar)
    putEnv(MirrorModeEnv, modeValue)
    if storeRootValue.len > 0:
      putEnv(StoreRootEnvVar, storeRootValue)
    else:
      delEnv(StoreRootEnvVar)
    try:
      body
    finally:
      if oldModeSet:
        putEnv(MirrorModeEnv, oldModeValue)
      else:
        delEnv(MirrorModeEnv)
      if oldStoreSet:
        putEnv(StoreRootEnvVar, oldStoreValue)
      else:
        delEnv(StoreRootEnvVar)

package m9r81DepEnvFixture:
  nativeBuildDeps:
    "native-tool >=1"
  buildDeps:
    "qt6-base >=6.6"
    "dep.with+dots"
  runtimeDeps:
    "runtime+tool"
  executable depEnvProbe:
    discard

template withLegacyMirrorMode(body: untyped) =
  let oldSet = existsEnv(MirrorModeEnv)
  let oldValue = getEnv(MirrorModeEnv)
  putEnv(MirrorModeEnv, "legacy")
  try:
    body
  finally:
    if oldSet:
      putEnv(MirrorModeEnv, oldValue)
    else:
      delEnv(MirrorModeEnv)

proc findAction(id: string): BuildActionDef =
  for action in registeredBuildActions():
    if action.id == id:
      return action
  raise newException(ValueError, "action not found: " & id)

proc envValue(action: BuildActionDef; name: string): string =
  for (key, value) in action.env:
    if key == name:
      return value
  ""

proc envNames(action: BuildActionDef): seq[string] =
  for (key, _) in action.env:
    result.add(key)

suite "M9.R.81 dependency root env vars":

  test "sanitizes dependency selectors into stable env names":
    check dependencyNameFromConstraint("qt6-base >=6.6") == "qt6-base"
    check dependencyNameFromConstraint("dep.with+dots <2") ==
      "dep.with+dots"
    check dependencyRootEnvVarName("qt6-base") ==
      "DEP_QT6_BASE_ROOT"
    check dependencyRootEnvVarName("dep.with+dots") ==
      "DEP_DEP_WITH_DOTS_ROOT"

  test "dependencyRootEnvEntries uses resolver paths in input order":
    withLegacyMirrorMode:
      let entries = dependencyRootEnvEntries(
        "/recipes",
        @["qt6-base >=6.6", "dep.with+dots", "qt6-base <7"])
      check entries.len == 2
      check entries[0] == (
        "DEP_QT6_BASE_ROOT",
        "/recipes/qt6-base/.repro/output/install")
      check entries[1] == (
        "DEP_DEP_WITH_DOTS_ROOT",
        "/recipes/dep.with+dots/.repro/output/install")

  test "dependencyRootEnvEntries resolves hashed prefixes from sidecars":
    let scratch = getTempDir() / "t_m9r81_dep_root_env_vars_hashed"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    defer:
      if dirExists(scratch):
        removeDir(scratch)

    let recipesRoot = scratch / "recipes"
    let storeRoot = (scratch / "store").replace("\\", "/")
    let hashHex = repeat("a", 64)
    writeRealizationInfoFile(recipesRoot, "qt6-base", "6.6.2", hashHex)

    withInstallMirrorEnv("hashed", storeRoot):
      let entries = dependencyRootEnvEntries(
        recipesRoot,
        @["qt6-base >=6.6", "qt6-base <7"])
      check entries == @[
        (
          "DEP_QT6_BASE_ROOT",
          storeRoot & "/" &
            installMirrorStoreRelativePath("qt6-base", "6.6.2", hashHex)
        )
      ]

  test "buildAction registry carries package dependency roots":
    withLegacyMirrorMode:
      resetBuildActionRegistry()
      setCurrentOwningPackageOverride("m9r81DepEnvFixture")
      try:
        discard buildAction(
          id = "m9r81-dep-env-action",
          call = publicCliCall("pkg", "exe", "build",
            "pkg.exe.build", @[]),
          env = @[("EXPLICIT_ENV", "kept-last")])
      finally:
        clearCurrentOwningPackageOverride()

      let action = findAction("m9r81-dep-env-action")
      let names = action.envNames()
      check names == @[
        "OUT_MIRROR",
        "DEP_NATIVE_TOOL_ROOT",
        "DEP_QT6_BASE_ROOT",
        "DEP_DEP_WITH_DOTS_ROOT",
        "DEP_RUNTIME_TOOL_ROOT",
        "DEP_LIBXKBCOMMON_ROOT",
        "DEP_MESA_ROOT",
        "EXPLICIT_ENV",
      ]
      check action.envValue("OUT_MIRROR").endsWith(
        "/tests/unit/.repro/output/install")
      check action.envValue("DEP_QT6_BASE_ROOT").endsWith(
        "/tests/qt6-base/.repro/output/install")
      check action.envValue("DEP_DEP_WITH_DOTS_ROOT").endsWith(
        "/tests/dep.with+dots/.repro/output/install")
      check action.envValue("DEP_LIBXKBCOMMON_ROOT").endsWith(
        "/tests/libxkbcommon/.repro/output/install")
      check action.envValue("DEP_MESA_ROOT").endsWith(
        "/tests/mesa/.repro/output/install")
      check action.envValue("EXPLICIT_ENV") == "kept-last"

  test "buildAction env keeps OUT_MIRROR staging while DEP roots hash":
    let scratch = getTempDir() / "t_m9r81_action_env_hashed"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    defer:
      if dirExists(scratch):
        removeDir(scratch)

    let recipesRoot = currentSourcePath.parentDir.parentDir
    let storeRoot = (scratch / "store").replace("\\", "/")
    let ownHashHex = repeat("b", 64)
    let depHashHex = repeat("c", 64)
    let ownSidecar = realizationInfoPath(recipesRoot, "unit")
    let depSidecar = realizationInfoPath(recipesRoot, "qt6-base")
    let oldOwnExists = fileExists(ownSidecar)
    let oldOwnParentExists = dirExists(parentDir(ownSidecar))
    let oldOwn =
      if oldOwnExists: readFile(ownSidecar)
      else: ""
    let oldDepExists = fileExists(depSidecar)
    let oldDepParentExists = dirExists(parentDir(depSidecar))
    let oldDep =
      if oldDepExists: readFile(depSidecar)
      else: ""
    defer:
      if oldOwnExists:
        createDir(parentDir(ownSidecar))
        writeFile(ownSidecar, oldOwn)
      elif fileExists(ownSidecar):
        removeFile(ownSidecar)
      if not oldOwnParentExists and dirExists(parentDir(ownSidecar)):
        try: removeDir(parentDir(ownSidecar)) except OSError: discard
      if oldDepExists:
        createDir(parentDir(depSidecar))
        writeFile(depSidecar, oldDep)
      elif fileExists(depSidecar):
        removeFile(depSidecar)
      if not oldDepParentExists and dirExists(parentDir(depSidecar)):
        try: removeDir(parentDir(depSidecar)) except OSError: discard

    writeRealizationInfoFile(recipesRoot, "unit", "1.0.0", ownHashHex)
    writeRealizationInfoFile(recipesRoot, "qt6-base", "6.6.2", depHashHex)

    withInstallMirrorEnv("hashed", storeRoot):
      resetBuildActionRegistry()
      setCurrentOwningPackageOverride("m9r81DepEnvFixture")
      try:
        discard buildAction(
          id = "m9r81-hashed-action-env",
          call = publicCliCall("pkg", "exe", "build",
            "pkg.exe.build", @[]))
      finally:
        clearCurrentOwningPackageOverride()

      let action = findAction("m9r81-hashed-action-env")
      check action.envValue("OUT_MIRROR") ==
        (currentSourcePath.parentDir / ".repro" / "output" / "install").
          replace("\\", "/")
      check action.envValue("DEP_QT6_BASE_ROOT") ==
        storeRoot & "/" &
          installMirrorStoreRelativePath("qt6-base", "6.6.2", depHashHex)
