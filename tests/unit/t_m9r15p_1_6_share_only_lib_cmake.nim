## DSL-port M9.R.15p.1.6 — share-only-package fast-path widening to
## ``lib/cmake/`` + ``lib64/cmake/`` layouts.
##
## Pins the fix for the M9.R.15p.1 status report's
## "plasma-wayland-protocols ships PlasmaWaylandProtocolsConfig.cmake
## under build/out/usr/lib/cmake/PlasmaWaylandProtocols/, but the
## M9.R.15h.14 share-only fast-path only probed share/" gap.  Two
## layout shapes are now covered:
##
##   * share-rooted with extra ``cmake/`` nesting:
##         <share>/<Pkg>/cmake/<Pkg>Config.cmake     (ECM)
##   * lib-rooted without the extra cmake/ nesting:
##         <lib>/cmake/<Pkg>/<Pkg>Config.cmake       (plasma-wayland-
##                                                    protocols, every
##                                                    standard CMake
##                                                    package-config
##                                                    install)

import std/[os, strutils, tempfiles, unittest]

import repro_tool_profiles
import repro_interface_artifacts

proc makeRecipeFile(root, name: string) =
  let recipeDir = root / name
  createDir(recipeDir)
  writeFile(recipeDir / "repro.nim", "## synthetic " & name & " recipe\n")

proc syntheticUseDef(name: string): InterfaceToolUse =
  InterfaceToolUse(
    rawConstraint: name,
    packageSelector: name,
    executableName: name)

proc stageShareLayoutConfig(recipeRoot, name, pkgDir: string) =
  ## ECM layout:
  ##   <recipeRoot>/<name>/build/out/usr/share/<pkgDir>/cmake/<pkgDir>Config.cmake
  let configDir = recipeRoot / name / "build" / "out" / "usr" / "share" /
    pkgDir / "cmake"
  createDir(configDir)
  writeFile(configDir / (pkgDir & "Config.cmake"),
    "# synthetic " & pkgDir & " config\n")

proc stageLibLayoutConfig(recipeRoot, name, pkgDir: string;
                          libDir = "lib") =
  ## plasma-wayland-protocols layout:
  ##   <recipeRoot>/<name>/build/out/usr/lib/cmake/<pkgDir>/<pkgDir>Config.cmake
  let configDir = recipeRoot / name / "build" / "out" / "usr" / libDir /
    "cmake" / pkgDir
  createDir(configDir)
  writeFile(configDir / (pkgDir & "Config.cmake"),
    "# synthetic " & pkgDir & " config\n")

suite "DSL-port M9.R.15p.1.6 — share-only fast-path lib/cmake widening":

  test "test_m9r15p_1_6_share_layout_still_resolves_ecm_shape":
    # Baseline regression pin: the M9.R.15h.14 share-rooted ECM shape
    # MUST keep working after widening.
    let scratch = createTempDir("repro-m9r15p-share-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "extra-cmake-modules")
    stageShareLayoutConfig(scratch, "extra-cmake-modules", "ECM")
    let useDef = syntheticUseDef("extra-cmake-modules")
    let outcome = tryResolveFromSourceTool(useDef, recipeRoot = scratch)
    check outcome.kind == rrResolved
    check outcome.profile.resolvedExecutablePath.endsWith("ECMConfig.cmake")

  test "test_m9r15p_1_6_lib_cmake_layout_resolves_plasma_wayland_shape":
    # The M9.R.15p.1.6 widening pin: a lib-rooted CMake config install
    # like plasma-wayland-protocols (which installs at
    # lib/cmake/PlasmaWaylandProtocols/PlasmaWaylandProtocolsConfig.cmake)
    # MUST resolve through the share-only fast-path.
    let scratch = createTempDir("repro-m9r15p-libcmake-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "plasma-wayland-protocols")
    stageLibLayoutConfig(scratch, "plasma-wayland-protocols",
      "PlasmaWaylandProtocols")
    let useDef = syntheticUseDef("plasma-wayland-protocols")
    let outcome = tryResolveFromSourceTool(useDef, recipeRoot = scratch)
    check outcome.kind == rrResolved
    check outcome.profile.resolvedExecutablePath.endsWith(
      "PlasmaWaylandProtocolsConfig.cmake")

  test "test_m9r15p_1_6_lib64_cmake_layout_resolves":
    # 64-bit multilib hosts install CMake configs under lib64/cmake/
    # instead of lib/cmake/. The fast-path MUST cover both.
    let scratch = createTempDir("repro-m9r15p-lib64-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "some-cmake-pkg")
    stageLibLayoutConfig(scratch, "some-cmake-pkg", "SomeCmakePkg",
      libDir = "lib64")
    let useDef = syntheticUseDef("some-cmake-pkg")
    let outcome = tryResolveFromSourceTool(useDef, recipeRoot = scratch)
    check outcome.kind == rrResolved
    check outcome.profile.resolvedExecutablePath.endsWith(
      "SomeCmakePkgConfig.cmake")

  test "test_m9r15p_1_6_no_config_anywhere_returns_needs_build":
    # When neither share/ nor lib/cmake nor lib64/cmake has a config,
    # the resolver returns rrNeedsBuild so the dispatcher's
    # auto-recurse triggers a fresh build.
    let scratch = createTempDir("repro-m9r15p-empty-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "empty-pkg")
    # Stage a recipe dir but NO config files anywhere
    createDir(scratch / "empty-pkg" / "build" / "out" / "usr")
    let useDef = syntheticUseDef("empty-pkg")
    let outcome = tryResolveFromSourceTool(useDef, recipeRoot = scratch)
    check outcome.kind == rrNeedsBuild
