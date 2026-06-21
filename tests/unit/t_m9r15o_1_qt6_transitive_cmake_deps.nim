## DSL-port M9.R.15o.1 — Auto-thread Qt6Gui transitive find_dependency
## targets (libxkbcommon + mesa) for every qt6-* consumer.
##
## ## Context
##
## M9.R.15n.3..5 hand-patched ``kcrash`` / ``kglobalaccel`` / ``kded``
## to add ``libxkbcommon >=1.5`` + ``mesa >=23.3`` as buildDeps so
## Qt6Gui's CMake config-package ``find_dependency(XKB)`` +
## ``find_dependency(GLESv2)`` succeeds. Every Qt6Gui consumer needs
## the same boilerplate.
##
## M9.R.15o.1 moves the boilerplate to the ``cmake_package``
## constructor: whenever any ``qt6-*`` dep is in the package's
## nativeBuildDeps + buildDeps AND the sibling install-mirror exists,
## the constructor virtually injects ``libxkbcommon`` + ``mesa`` as
## tool-identity refs (so the M9.R.14e search-path channels reach the
## action env) and re-runs the generic CMake-config dir scan against
## them.
##
## ## What this test pins
##
##   1. ``m9r15oCollectQt6TransitiveCmakeDeps`` returns
##      ``@["libxkbcommon", "mesa"]`` (in declaration order) when a
##      qt6-* dep is present and both sibling mirrors exist on disk.
##   2. The helper returns ``@[]`` when no qt6-* dep is declared.
##   3. The helper returns ``@[]`` when ``projectRoot`` is empty
##      (unit-test inert path).
##   4. The helper skips a dep the recipe already declared by hand
##      (the M9.R.15n hand-patched recipes don't see duplicate refs).
##   5. The helper skips a dep whose sibling install-mirror is missing
##      (recipe not built yet — graceful degradation).
##   6. Determinism: two invocations against the same on-disk graph +
##      same registered deps produce identical output.

import std/[os, tempfiles, unittest]

import repro_dsl_stdlib/types/package_result
import repro_project_dsl

proc layInstallMirror(root, depName: string) =
  ## Lay down a synthetic ``<depRecipe>/.repro/output/install/usr/``
  ## directory so the helper's ``dirExists(mirrorUsr)`` probe returns
  ## true.
  createDir(root / depName / ".repro" / "output" / "install" / "usr")

suite "DSL-port M9.R.15o.1 — Qt6Gui transitive CMake deps auto-thread":

  test "auto_injects_libxkbcommon_and_mesa_when_qt6_dep_present":
    let scratch = createTempDir("repro-m9r15o-1-inject-", "")
    defer: removeDir(scratch)

    layInstallMirror(scratch, "libxkbcommon")
    layInstallMirror(scratch, "mesa")

    resetDslPortPackageDepsState()
    let pkgName = "m9r15o1InjectPkg"
    registerPackageDep(pkgName, "build", "qt6-base >=6.6")
    registerPackageDep(pkgName, "build", "kconfig >=6.0")

    let projectRoot = scratch / pkgName
    createDir(projectRoot)
    let extras = m9r15oCollectQt6TransitiveCmakeDeps(projectRoot, pkgName)

    check extras.len == 2
    check extras[0] == "libxkbcommon"
    check extras[1] == "mesa"

  test "inert_when_no_qt6_dep_declared":
    let scratch = createTempDir("repro-m9r15o-1-noqt6-", "")
    defer: removeDir(scratch)

    layInstallMirror(scratch, "libxkbcommon")
    layInstallMirror(scratch, "mesa")

    resetDslPortPackageDepsState()
    let pkgName = "m9r15o1NoQt6Pkg"
    # No qt6-* dep declared — only ECM + kconfig.
    registerPackageDep(pkgName, "native", "extra-cmake-modules >=6.0")
    registerPackageDep(pkgName, "build", "kconfig >=6.0")

    let projectRoot = scratch / pkgName
    createDir(projectRoot)
    let extras = m9r15oCollectQt6TransitiveCmakeDeps(projectRoot, pkgName)

    check extras.len == 0

  test "inert_when_project_root_empty":
    # Inert in unit-test mode without an on-disk recipeRoot.
    resetDslPortPackageDepsState()
    let pkgName = "m9r15o1EmptyPkg"
    registerPackageDep(pkgName, "build", "qt6-base >=6.6")
    let extras = m9r15oCollectQt6TransitiveCmakeDeps("", pkgName)
    check extras.len == 0

  test "skips_dep_already_declared_by_recipe":
    # M9.R.15n hand-patched recipes (kcrash / kglobalaccel / kded)
    # carry the explicit ``libxkbcommon`` + ``mesa`` annotations.
    # The auto-thread MUST NOT double-inject; the result is the
    # subset of transitive deps the recipe hasn't already listed.
    let scratch = createTempDir("repro-m9r15o-1-dedup-", "")
    defer: removeDir(scratch)

    layInstallMirror(scratch, "libxkbcommon")
    layInstallMirror(scratch, "mesa")

    resetDslPortPackageDepsState()
    let pkgName = "m9r15o1DedupPkg"
    registerPackageDep(pkgName, "build", "qt6-base >=6.6")
    # Recipe already declares libxkbcommon by hand — auto-thread
    # must skip it and only inject mesa.
    registerPackageDep(pkgName, "build", "libxkbcommon >=1.5")

    let projectRoot = scratch / pkgName
    createDir(projectRoot)
    let extras = m9r15oCollectQt6TransitiveCmakeDeps(projectRoot, pkgName)

    check extras.len == 1
    check extras[0] == "mesa"

  test "skips_dep_whose_install_mirror_missing":
    # libxkbcommon sibling install-mirror has been wiped (e.g. the
    # recipe is registered but hasn't built yet). The helper
    # gracefully omits it instead of producing a broken dep ref.
    let scratch = createTempDir("repro-m9r15o-1-missing-", "")
    defer: removeDir(scratch)

    # Only mesa's install-mirror exists; libxkbcommon's is missing.
    layInstallMirror(scratch, "mesa")

    resetDslPortPackageDepsState()
    let pkgName = "m9r15o1MissingPkg"
    registerPackageDep(pkgName, "build", "qt6-base >=6.6")

    let projectRoot = scratch / pkgName
    createDir(projectRoot)
    let extras = m9r15oCollectQt6TransitiveCmakeDeps(projectRoot, pkgName)

    check extras.len == 1
    check extras[0] == "mesa"

  test "determinism_two_runs_produce_identical_output":
    let scratch = createTempDir("repro-m9r15o-1-det-", "")
    defer: removeDir(scratch)

    layInstallMirror(scratch, "libxkbcommon")
    layInstallMirror(scratch, "mesa")

    resetDslPortPackageDepsState()
    let pkgName = "m9r15o1DetPkg"
    registerPackageDep(pkgName, "build", "qt6-base >=6.6")
    registerPackageDep(pkgName, "build", "qt6-tools >=6.6")

    let projectRoot = scratch / pkgName
    createDir(projectRoot)
    let first = m9r15oCollectQt6TransitiveCmakeDeps(projectRoot, pkgName)
    let second = m9r15oCollectQt6TransitiveCmakeDeps(projectRoot, pkgName)
    check first == second
    check first.len == 2

  test "qt6_in_native_build_deps_triggers_auto_thread":
    # qt6-tools is usually a nativeBuildDep (for qhelpgenerator + lupdate).
    # The auto-thread MUST trigger off nativeBuildDeps too, not just
    # buildDeps.
    let scratch = createTempDir("repro-m9r15o-1-native-", "")
    defer: removeDir(scratch)

    layInstallMirror(scratch, "libxkbcommon")
    layInstallMirror(scratch, "mesa")

    resetDslPortPackageDepsState()
    let pkgName = "m9r15o1NativePkg"
    registerPackageDep(pkgName, "native", "qt6-tools >=6.6")

    let projectRoot = scratch / pkgName
    createDir(projectRoot)
    let extras = m9r15oCollectQt6TransitiveCmakeDeps(projectRoot, pkgName)

    check extras.len == 2
    check extras[0] == "libxkbcommon"
    check extras[1] == "mesa"
