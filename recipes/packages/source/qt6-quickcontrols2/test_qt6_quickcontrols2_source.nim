## Smoke test for the qt6QuickControls2Source shim recipe.
##
## M9.R.81 coverage: the shim declares its qt6-declarative dependency
## and consumes generated DEP_<name>_ROOT / OUT_MIRROR env vars rather
## than hardcoded sibling install-mirror paths.

import std/[strutils, unittest]

import repro_project_dsl

# Side-effect import: registers the package, dependency declarations, and
# build body helper under ``qt6QuickControls2Source``.
import ./repro

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

proc argValue(action: BuildActionDef; name: string): string =
  for arg in action.call.arguments:
    if arg.name == name:
      return arg.encodedValue
  ""

suite "qt6QuickControls2Source — shim recipe smoke test":

  test "declares qt6-declarative as the sibling source dependency":
    check "qt6-declarative >=6.6" in
      registeredBuildDeps("qt6QuickControls2Source")

  test "shim action uses DEP_QT6_DECLARATIVE_ROOT and OUT_MIRROR":
    resetBuildActionRegistry()
    buildQt6QuickControls2SourcePackage()

    let action = findAction("qt6QuickControls2Source.shim_stage")
    let command = action.argValue("command")
    check action.call.packageName == "sh"
    check action.call.executableName == "sh"
    check command.contains("SRC=${DEP_QT6_DECLARATIVE_ROOT}/usr")
    check command.contains("DST=${OUT_MIRROR}/usr")
    check not command.contains("../qt6-declarative/.repro/output/install")

    let qtdeclRoot = dependencyInstallMirrorRoot(
      "qt6-declarative", "qt6QuickControls2Source")
    let ownRoot = dependencyInstallMirrorRoot(
      "qt6-quickcontrols2", "qt6QuickControls2Source")
    check action.envValue("DEP_QT6_DECLARATIVE_ROOT") == qtdeclRoot
    check action.envValue("OUT_MIRROR") == ownRoot
    check qtdeclRoot & "/usr/lib/cmake/Qt6QuickControls2/Qt6QuickControls2Config.cmake" in
      action.inputs
    check ownRoot & "/usr/lib/cmake/Qt6QuickControls2/Qt6QuickControls2Config.cmake" in
      action.outputs
