## DSL-port M9.R.15q.3.1 — virtual KF6 umbrella config dispatcher.
##
## ## Context
##
## KDE upstream's KF6 packaging convention exposes a top-level umbrella
## probe:
##
##     find_package(KF6 REQUIRED COMPONENTS Config CoreAddons I18n WindowSystem)
##
## cmake looks for ``KF6Config.cmake`` on ``CMAKE_PREFIX_PATH`` (or via
## ``-DKF6_DIR=...``) which then dispatches to each requested module's
## own ``KF6<X>Config.cmake``. Reprobuild's M9.R.15i.5 auto-threads
## per-module ``-DKF6<X>_DIR=...`` cache vars but does NOT synthesise
## the umbrella dispatcher, so the upstream-shape probe fails before
## the per-module threading can satisfy each component.
##
## M9.R.15q.3.1 writes a synthetic ``KF6Config.cmake`` at
## ``<projectRoot>/.repro/build/cmake/KF6/`` and lets the cmake_package
## constructor pass ``-DKF6_DIR=<that-dir>`` so the umbrella probe
## resolves through our dispatcher.
##
## ## What this test pins
##
##   1. ``m9r15q31KF6Components`` filters a generic
##      ``m9r15iCollectAllCmakeConfigDirs`` result to the KF6 component
##      names alone (non-KF6 components — Qt6 / ECM — are excluded).
##   2. ``m9r15q31SynthesizeKF6UmbrellaConfig`` writes the dispatcher to
##      the canonical location and returns the directory path.
##   3. The generated file is syntactically valid cmake (set / foreach /
##      find_package / endforeach are balanced; no stray template
##      placeholders leaked).
##   4. Determinism: same inputs produce byte-identical output.
##   5. Empty projectRoot returns "" (inert in unit-test orchestration).
##   6. No KF6 components → no umbrella generated.

import std/[os, strutils, tempfiles, unittest]

import repro_dsl_stdlib/types/package_result
import repro_project_dsl

proc layCmakeConfig(root, depName, componentName: string) =
  ## Lay down a synthetic ``<dep>/.repro/output/install/usr/lib/cmake
  ## /<componentName>/<componentName>Config.cmake``.
  let cmakeRoot = root / depName / ".repro" / "output" / "install" /
    "usr" / "lib" / "cmake" / componentName
  createDir(cmakeRoot)
  writeFile(cmakeRoot / (componentName & "Config.cmake"),
    "# synthetic " & componentName & " config\n")

suite "DSL-port M9.R.15q.3.1 — virtual KF6 umbrella config":

  test "kf6_components_filter_skips_non_kf6":
    let pairs = @[
      ("KF6Config",
       "/x/kconfig/.repro/output/install/usr/lib/cmake/KF6Config"),
      ("KF6CoreAddons",
       "/x/kcoreaddons/.repro/output/install/usr/lib/cmake/KF6CoreAddons"),
      ("Qt6Core",
       "/x/qt6-base/.repro/output/install/usr/lib/cmake/Qt6Core"),
      ("ECM",
       "/x/extra-cmake-modules/.repro/output/install/usr/lib/cmake/ECM"),
    ]
    let kf6 = m9r15q31KF6Components(pairs)
    check kf6.len == 2
    check "KF6Config" in kf6
    check "KF6CoreAddons" in kf6
    # Make sure the umbrella's own self-name is never emitted as a
    # component (would cause re-entry on dispatch).
    check "KF6" notin kf6
    check "Qt6Core" notin kf6
    check "ECM" notin kf6

  test "kf6_components_filter_dedups_duplicates":
    let pairs = @[
      ("KF6Config", "/a"),
      ("KF6Config", "/b"),
      ("KF6I18n", "/c"),
    ]
    let kf6 = m9r15q31KF6Components(pairs)
    check kf6.len == 2
    check "KF6Config" in kf6
    check "KF6I18n" in kf6

  test "synthesize_writes_dispatcher_at_canonical_location":
    let scratch = createTempDir("repro-m9r15q-3-synth-", "")
    defer: removeDir(scratch)

    let projectRoot = scratch / "plasma-activities"
    createDir(projectRoot)
    let kf6 = @["KF6Config", "KF6CoreAddons", "KF6I18n", "KF6WindowSystem"]
    let umbrellaDir = m9r15q31SynthesizeKF6UmbrellaConfig(projectRoot, kf6)

    # Canonical layout: <projectRoot>/.repro/build/cmake/KF6
    check umbrellaDir.len > 0
    check umbrellaDir.endsWith(".repro/build/cmake/KF6")
    check dirExists(umbrellaDir)
    let umbrellaFile = umbrellaDir / "KF6Config.cmake"
    check fileExists(umbrellaFile)
    let content = readFile(umbrellaFile)
    # Every requested component name (stripped of the KF6 prefix) is
    # present in the dispatcher's _kf6_known_components list.
    check "\"Config\"" in content
    check "\"CoreAddons\"" in content
    check "\"I18n\"" in content
    check "\"WindowSystem\"" in content
    # The dispatcher body references KF6 + FIND_COMPONENTS + the
    # foreach loop driver.
    check "set(KF6_FOUND TRUE)" in content
    check "KF6_FIND_COMPONENTS" in content
    check "find_package(${_kf6_target} CONFIG QUIET)" in content

  test "synthesize_balanced_cmake_syntax":
    let scratch = createTempDir("repro-m9r15q-3-syntax-", "")
    defer: removeDir(scratch)

    let projectRoot = scratch / "kf6consumer"
    createDir(projectRoot)
    let kf6 = @["KF6Config", "KF6CoreAddons"]
    let umbrellaDir = m9r15q31SynthesizeKF6UmbrellaConfig(projectRoot, kf6)
    let content = readFile(umbrellaDir / "KF6Config.cmake")
    # ``foreach`` ↔ ``endforeach`` balanced; ``if`` ↔ ``endif`` balanced.
    var foreachCount = 0
    var endforeachCount = 0
    var ifCount = 0
    var endifCount = 0
    for line in content.splitLines():
      let trimmed = line.strip()
      if trimmed.startsWith("foreach("):
        inc foreachCount
      if trimmed.startsWith("endforeach("):
        inc endforeachCount
      if trimmed.startsWith("if(") or trimmed.startsWith("if "):
        inc ifCount
      if trimmed.startsWith("endif("):
        inc endifCount
    check foreachCount == endforeachCount
    check ifCount == endifCount
    # No stray template placeholder leaked through (we don't use any
    # mustache-style markers, but a regression that re-introduced them
    # without escaping would surface here).
    check "{{" notin content
    check "}}" notin content

  test "synthesize_deterministic_two_runs_identical":
    let scratch = createTempDir("repro-m9r15q-3-det-", "")
    defer: removeDir(scratch)

    let projectRoot = scratch / "plasma-fw"
    createDir(projectRoot)
    let kf6 = @["KF6Archive", "KF6Config", "KF6CoreAddons", "KF6I18n"]
    let dir1 = m9r15q31SynthesizeKF6UmbrellaConfig(projectRoot, kf6)
    let content1 = readFile(dir1 / "KF6Config.cmake")
    let dir2 = m9r15q31SynthesizeKF6UmbrellaConfig(projectRoot, kf6)
    let content2 = readFile(dir2 / "KF6Config.cmake")
    check dir1 == dir2
    check content1 == content2

  test "synthesize_empty_project_root_returns_empty":
    let kf6 = @["KF6Config", "KF6CoreAddons"]
    let umbrellaDir = m9r15q31SynthesizeKF6UmbrellaConfig("", kf6)
    check umbrellaDir.len == 0

  test "synthesize_empty_components_returns_empty":
    let scratch = createTempDir("repro-m9r15q-3-empty-", "")
    defer: removeDir(scratch)

    let projectRoot = scratch / "nokf6"
    createDir(projectRoot)
    let umbrellaDir = m9r15q31SynthesizeKF6UmbrellaConfig(projectRoot, @[])
    check umbrellaDir.len == 0
    # And no leftover dispatcher dir.
    check not fileExists(projectRoot / ".repro" / "build" / "cmake" /
      "KF6" / "KF6Config.cmake")

  test "umbrella_dir_helper_matches_canonical_layout":
    let projectRoot = "/some/recipe/root"
    let dir = m9r15q31KF6UmbrellaDir(projectRoot)
    check dir == "/some/recipe/root/.repro/build/cmake/KF6"
    check m9r15q31KF6UmbrellaDir("") == ""

  test "synthesize_integrates_with_collect_all_helper":
    # End-to-end shape: lay down four sibling deps (three KF6 + one
    # Qt6) and confirm m9r15iCollectAllCmakeConfigDirs +
    # m9r15q31KF6Components + m9r15q31SynthesizeKF6UmbrellaConfig
    # compose into a dispatcher that names just the KF6 modules.
    let scratch = createTempDir("repro-m9r15q-3-integ-", "")
    defer: removeDir(scratch)

    layCmakeConfig(scratch, "kconfig", "KF6Config")
    layCmakeConfig(scratch, "kcoreaddons", "KF6CoreAddons")
    layCmakeConfig(scratch, "ki18n", "KF6I18n")
    layCmakeConfig(scratch, "kwindowsystem", "KF6WindowSystem")
    layCmakeConfig(scratch, "qt6-base", "Qt6Core")

    resetDslPortPackageDepsState()
    let pkgName = "m9r15q3IntegPkg"
    registerPackageDep(pkgName, "build", "qt6-base >=6.6")
    registerPackageDep(pkgName, "build", "kconfig >=6.0")
    registerPackageDep(pkgName, "build", "kcoreaddons >=6.0")
    registerPackageDep(pkgName, "build", "ki18n >=6.0")
    registerPackageDep(pkgName, "build", "kwindowsystem >=6.0")

    let projectRoot = scratch / pkgName
    createDir(projectRoot)
    let collected = m9r15iCollectAllCmakeConfigDirs(projectRoot, pkgName)
    let kf6 = m9r15q31KF6Components(collected)
    check kf6.len == 4
    let umbrellaDir = m9r15q31SynthesizeKF6UmbrellaConfig(projectRoot, kf6)
    check umbrellaDir.endsWith(".repro/build/cmake/KF6")
    let content = readFile(umbrellaDir / "KF6Config.cmake")
    check "\"Config\"" in content
    check "\"CoreAddons\"" in content
    check "\"I18n\"" in content
    check "\"WindowSystem\"" in content
    # Qt6 must NOT leak into the umbrella's known list.
    check "\"Qt6Core\"" notin content
    check "Qt6Core" notin content
