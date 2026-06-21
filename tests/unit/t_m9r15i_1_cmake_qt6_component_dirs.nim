## DSL-port M9.R.15i.1 — Qt6 component CMake-config dir threading.
##
## ## Context
##
## Qt6's CMake-config-package machinery expects every dependent
## ``find_package(Qt6 ... LinguistTools REQUIRED)`` to resolve all
## requested components from a SINGLE install prefix (the Qt6Config
## .cmake co-located with each Qt6<X>Config.cmake). Reprobuild's
## from-source recipes install each ``qt6-*`` package to its OWN
## sibling prefix (``recipes/packages/source/qt6-tools/.repro/output/
## install/usr/lib/cmake/Qt6LinguistTools/...``). KF6 / Plasma recipes
## consume ``qt6-base`` AND ``qt6-tools`` transitively but their
## ``find_package(Qt6 ... LinguistTools REQUIRED)`` only sees qt6-base's
## prefix, so the LinguistTools probe fails.
##
## M9.R.15i.1 fixes this at the ``cmake_package`` constructor level: it
## scans every ``qt6-*`` dep's install-mirror cmake/ tree for
## ``Qt6<X>Config.cmake`` files and auto-threads them as
## ``-DQt6<X>_DIR=<cmake-dir>`` cache vars. Downstream KF6 / Plasma
## recipes inherit the fix without per-recipe boilerplate.
##
## ## What this test pins
##
##   1. ``m9r15iScanQt6CmakeDirs`` enumerates every Qt6<X>Config.cmake
##      under a dep's install-mirror cmake/ tree and returns
##      ``(Component, dir)`` pairs.
##   2. ``m9r15iCollectQt6ComponentDirs`` walks every ``qt6-*`` dep of
##      a package and unions the per-dep scan results.
##   3. ``m9r15iEmitQt6ComponentCacheVars`` formats each pair as
##      ``Component_DIR=dir`` (the configure CLI lowering adds ``-D``).
##   4. Determinism: two invocations against the same on-disk graph
##      produce byte-identical output ordering.
##   5. Non-Qt6 deps don't surface entries (only ``qt6-*`` deps trigger
##      the scan).
##   6. Subdirs without ``Qt6<X>Config.cmake`` are skipped (e.g. random
##      cmake helper dirs).

import std/[os, tempfiles, unittest]

import repro_dsl_stdlib/types/package_result
import repro_project_dsl

proc layQt6CmakeConfig(root, depName, componentName: string) =
  ## Lay down a synthetic ``<depRecipe>/.repro/output/install/usr/lib/
  ## cmake/<componentName>/<componentName>Config.cmake`` so the scan
  ## helper finds it.
  let cmakeRoot = root / depName / ".repro" / "output" / "install" /
    "usr" / "lib" / "cmake" / componentName
  createDir(cmakeRoot)
  writeFile(cmakeRoot / (componentName & "Config.cmake"),
    "# synthetic " & componentName & " config\n")

suite "DSL-port M9.R.15i.1 — Qt6 component CMake-config dir threading":

  test "scan_qt6_cmake_dirs_finds_config_files":
    # qt6-tools dep with three component configs.
    let scratch = createTempDir("repro-m9r15i-1-scan-", "")
    defer: removeDir(scratch)

    layQt6CmakeConfig(scratch, "qt6-tools", "Qt6LinguistTools")
    layQt6CmakeConfig(scratch, "qt6-tools", "Qt6Help")
    layQt6CmakeConfig(scratch, "qt6-tools", "Qt6Linguist")

    var found: seq[(string, string)] = @[]
    m9r15iScanQt6CmakeDirs(scratch / "qt6-tools", found)

    check found.len == 3
    var sawLinguistTools = false
    var sawHelp = false
    var sawLinguist = false
    for (comp, dir) in found:
      if comp == "Qt6LinguistTools":
        sawLinguistTools = true
        check dir.endsWith("cmake/Qt6LinguistTools")
        check fileExists(dir / "Qt6LinguistToolsConfig.cmake")
      if comp == "Qt6Help":
        sawHelp = true
      if comp == "Qt6Linguist":
        sawLinguist = true
    check sawLinguistTools
    check sawHelp
    check sawLinguist

  test "scan_skips_dirs_without_config_file":
    # Non-Qt6 subdir (random) and a Qt6-named dir without the config
    # file: both must be skipped.
    let scratch = createTempDir("repro-m9r15i-1-skip-", "")
    defer: removeDir(scratch)

    let cmakeRoot = scratch / "qt6-tools" / ".repro" / "output" /
      "install" / "usr" / "lib" / "cmake"
    createDir(cmakeRoot / "RandomNonQt6")
    writeFile(cmakeRoot / "RandomNonQt6" / "FooConfig.cmake",
      "# random non-qt6\n")
    createDir(cmakeRoot / "Qt6Bogus")  # no Qt6BogusConfig.cmake
    layQt6CmakeConfig(scratch, "qt6-tools", "Qt6LinguistTools")

    var found: seq[(string, string)] = @[]
    m9r15iScanQt6CmakeDirs(scratch / "qt6-tools", found)
    check found.len == 1
    check found[0][0] == "Qt6LinguistTools"

  test "collect_qt6_component_dirs_walks_qt6_star_deps":
    # Package with qt6-base + qt6-tools + extra-cmake-modules deps.
    # Only the two qt6-* deps contribute entries; ECM is skipped.
    let scratch = createTempDir("repro-m9r15i-1-collect-", "")
    defer: removeDir(scratch)

    layQt6CmakeConfig(scratch, "qt6-base", "Qt6Core")
    layQt6CmakeConfig(scratch, "qt6-base", "Qt6Gui")
    layQt6CmakeConfig(scratch, "qt6-tools", "Qt6LinguistTools")
    # ECM has its own cmake dir but it's NOT named Qt6 so should be
    # skipped by m9r15iScanQt6CmakeDirs's prefix filter, AND the
    # collector should skip ECM entirely because it doesn't match
    # the ``qt6-*`` selector.
    let ecmCmake = scratch / "extra-cmake-modules" / ".repro" /
      "output" / "install" / "usr" / "lib" / "cmake" / "Qt6Bogus"
    createDir(ecmCmake)
    writeFile(ecmCmake / "Qt6BogusConfig.cmake", "# trap\n")

    # Register the package's deps. ``projectRoot`` is ``<scratch>/<pkgName>``
    # so ``parentDir(projectRoot) == scratch``.
    resetDslPortPackageDepsState()
    let pkgName = "m9r15i1Pkg"
    registerPackageDep(pkgName, "build", "qt6-base >=6.6")
    registerPackageDep(pkgName, "build", "qt6-tools >=6.6")
    registerPackageDep(pkgName, "build", "extra-cmake-modules >=6.0")

    let projectRoot = scratch / pkgName
    createDir(projectRoot)
    let collected = m9r15iCollectQt6ComponentDirs(projectRoot, pkgName)

    # qt6-base contributes Qt6Core + Qt6Gui; qt6-tools contributes
    # Qt6LinguistTools. ECM contributes nothing.
    check collected.len == 3
    var components: seq[string] = @[]
    for (comp, _) in collected:
      components.add(comp)
    check "Qt6Core" in components
    check "Qt6Gui" in components
    check "Qt6LinguistTools" in components

  test "emit_qt6_component_cache_vars_formats_each_entry":
    let pairs = @[
      ("Qt6LinguistTools",
       "/recipes/qt6-tools/.repro/output/install/usr/lib/cmake/Qt6LinguistTools"),
      ("Qt6Help",
       "/recipes/qt6-tools/.repro/output/install/usr/lib/cmake/Qt6Help"),
    ]
    let entries = m9r15iEmitQt6ComponentCacheVars(pairs)
    check entries.len == 2
    check entries[0] == "Qt6LinguistTools_DIR=/recipes/qt6-tools/.repro/output/install/usr/lib/cmake/Qt6LinguistTools"
    check entries[1] == "Qt6Help_DIR=/recipes/qt6-tools/.repro/output/install/usr/lib/cmake/Qt6Help"

  test "determinism_two_runs_produce_identical_output":
    let scratch = createTempDir("repro-m9r15i-1-det-", "")
    defer: removeDir(scratch)

    layQt6CmakeConfig(scratch, "qt6-base", "Qt6Core")
    layQt6CmakeConfig(scratch, "qt6-base", "Qt6Gui")
    layQt6CmakeConfig(scratch, "qt6-tools", "Qt6LinguistTools")
    layQt6CmakeConfig(scratch, "qt6-tools", "Qt6Help")

    resetDslPortPackageDepsState()
    let pkgName = "m9r15i1DetPkg"
    registerPackageDep(pkgName, "build", "qt6-base")
    registerPackageDep(pkgName, "build", "qt6-tools")

    let projectRoot = scratch / pkgName
    createDir(projectRoot)
    let first = m9r15iCollectQt6ComponentDirs(projectRoot, pkgName)
    let second = m9r15iCollectQt6ComponentDirs(projectRoot, pkgName)
    check first == second
    let firstEntries = m9r15iEmitQt6ComponentCacheVars(first)
    let secondEntries = m9r15iEmitQt6ComponentCacheVars(second)
    check firstEntries == secondEntries

  test "non_qt6_deps_do_not_surface_entries":
    let scratch = createTempDir("repro-m9r15i-1-nonqt6-", "")
    defer: removeDir(scratch)

    # Lay an ECM cmake dir with Qt6-prefixed configs (sneaky trap):
    # the scan would PICK them up if asked to walk ECM, but the
    # COLLECTOR must filter ECM out at the ``qt6-*`` selector level.
    layQt6CmakeConfig(scratch, "extra-cmake-modules", "Qt6LinguistTools")
    # And lay a real qt6-tools dir so we know what should surface.
    layQt6CmakeConfig(scratch, "qt6-tools", "Qt6Designer")

    resetDslPortPackageDepsState()
    let pkgName = "m9r15i1FilterPkg"
    registerPackageDep(pkgName, "native", "extra-cmake-modules >=6.0")
    registerPackageDep(pkgName, "build", "qt6-tools >=6.6")

    let projectRoot = scratch / pkgName
    createDir(projectRoot)
    let collected = m9r15iCollectQt6ComponentDirs(projectRoot, pkgName)
    # Only qt6-tools' Qt6Designer should surface; ECM's trapped
    # Qt6LinguistTools must be ignored.
    check collected.len == 1
    check collected[0][0] == "Qt6Designer"

  test "empty_project_root_returns_empty":
    # Inert in unit-test mode: an empty projectRoot means there's no
    # on-disk recipeRoot to walk.
    resetDslPortPackageDepsState()
    let pkgName = "m9r15i1EmptyPkg"
    registerPackageDep(pkgName, "build", "qt6-tools")
    let collected = m9r15iCollectQt6ComponentDirs("", pkgName)
    check collected.len == 0

  test "no_qt6_install_mirror_returns_empty":
    # qt6-tools is declared but its install-mirror doesn't exist yet
    # (recipe not built). The scan returns nothing rather than failing.
    let scratch = createTempDir("repro-m9r15i-1-noinst-", "")
    defer: removeDir(scratch)

    resetDslPortPackageDepsState()
    let pkgName = "m9r15i1UnbuiltPkg"
    registerPackageDep(pkgName, "build", "qt6-tools >=6.6")

    let projectRoot = scratch / pkgName
    createDir(projectRoot)
    let collected = m9r15iCollectQt6ComponentDirs(projectRoot, pkgName)
    check collected.len == 0
