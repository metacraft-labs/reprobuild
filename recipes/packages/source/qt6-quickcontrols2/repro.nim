## Source-from-tarball qt6-quickcontrols2 recipe -- M9.R.19.1 ReproOS
## Installer blocker. Provides ``libQt6QuickControls2.so`` to the
## reproos-installer Qt6/QML wizard.
##
## ## Why this recipe shares the qtdeclarative tarball
##
## In the Qt 5.x release line QtQuickControls2 was a standalone upstream
## module shipping its own ``qtquickcontrols2-everywhere-src-<ver>.tar.xz``
## tarball.  Starting with Qt 6.2 (per upstream Qt 6 module restructure)
## the QtQuickControls2 source tree was merged INTO qtdeclarative -- the
## ``qtquickcontrols2-everywhere-src-6.x.x.tar.xz`` submodule URL returns
## a hard HTTP 404 from download.qt.io's official_releases tree (verified
## 2026-06-23), and qtdeclarative's tarball now contains
## ``src/quickcontrols/`` (the modern path) plus
## ``dist/archived/qtquickcontrols2/`` (historical changelogs).
##
## The c_cpp_cmake convention requires a separately-named recipe per
## buildDep selector so the engine's tool-resolution layer can map
## ``"qt6-quickcontrols2 >=6.6"`` (declared on the reproos-installer
## recipe) onto a sibling-recipe build artifact.  We therefore configure
## this recipe to fetch the same qtdeclarative tarball as the sibling
## qt6-declarative recipe and declare the ``libQt6QuickControls2``
## artifact -- the cmake build naturally produces it from
## ``src/quickcontrols/`` while building qtdeclarative.
##
## The duplicated build is the cost of honest provenance:
## qt6-quickcontrols2 IS qtdeclarative-as-built-from-the-controls-subset,
## and the recipe declares that explicitly via the shared tarball + sha.
## The action-cache makes the second invocation a cache hit on the
## extract step (same content-addressed tarball) so the marginal cost is
## the configure + the controls-subset link, not a full second qtquick
## compile.
##
## ## sha256 strategy
##
## We reference the sibling qt6-declarative recipe's vendored tarball via
## the relative ``file:../qt6-declarative/vendor/...`` URL form (supported
## by cmake_package since M9.R.15q.5.4).  The 36-MiB tarball already
## lives in tree under qt6-declarative; no duplicate vendor tarball is
## committed here.
##
## sha256 = 95d15d5c1b6adcedb1df6485219ad13b8dc1bb5168b5151f2f1f7246a4c039fc
##  (matches the sibling qt6-declarative recipe; the same upstream
##  qtdeclarative-everywhere-src-6.8.1.tar.xz at 36,463,572 bytes
##  downloaded once from download.qt.io and cross-checked against the
##  upstream HTTP Digest: SHA-256 header).
##
## ## Version choice -- 6.8.1 (matches qt6-base / qt6-tools / qt6-declarative / qt6-svg / qt6-positioning)
##
## download.qt.io publishes Qt6 modular submodule sources at
## ``https://download.qt.io/official_releases/qt/<major.minor>/<version>/submodules/``
## and 6.8.1 is the current stable in the 6.8.x line as of mid-2026.
## qt6-base + qt6-tools + qt6-declarative + qt6-svg + qt6-positioning
## sibling recipes pin the same 6.8.1 tag; the Qt module set is built as
## a coordinated release so cross-module ABI matches tag-for-tag.
##
## ## Build shape
##
## The c_cpp_cmake convention (M9.K) reads both the M9.H ``fetch:`` block
## and the inlined ``cmake_package`` flags and lowers them into:
##
##   1. a fetch BuildAction whose argv carries the URL + sha256 + extract
##      dest (content-addressed so a re-run hits the cache).
##   2. a ``cmake`` configure BuildAction that depends on the fetch action
##      and passes every flag in the inlined ``opts`` to
##      ``cmake -S <src> -B <build>``, in declared order.
##   3. a ``ninja`` (or ``cmake --build``) compile BuildAction.
##   4. install/output collection actions for the libraries.
##
## ## Library artifacts
##
## qt6-quickcontrols2's CMake build (against the shared qtdeclarative
## tarball) emits the desktop-style Quick controls library:
##
##   * ``libQt6QuickControls2.so``  -- the desktop-style Quick controls
##     library the reproos-installer wizard's QML scenes consume
##     (Button / ComboBox / TextField / ScrollView / TextArea /
##     ProgressBar / CheckBox per PRD Sec 7.1).
##
## ## Configurables
##
## v1 ships NO configurables -- the CMake options are hardcoded to the
## modern-desktop baseline:
##
##   * ``BUILD_TESTING=OFF``        -- skip the upstream test suite to
##                                     keep the build hermetic + fast.
##   * ``CMAKE_BUILD_TYPE=Release`` -- release-mode optimisation;
##                                     matches sibling qt6-base /
##                                     qt6-tools / qt6-declarative /
##                                     qt6-svg / qt6-positioning recipes.
##   * ``QT_BUILD_TESTS=OFF``       -- Qt-side test-build disable.
##   * ``QT_BUILD_EXAMPLES=OFF``    -- skip the upstream examples build.
##   * ``QT_GENERATE_SBOM=OFF``     -- SBOM gen hard-codes the canonical
##                                     install prefix and fails when our
##                                     cmake_package install passes a
##                                     different ``--prefix``.  Same trip
##                                     as qt6-base / qt6-tools /
##                                     qt6-declarative / qt6-svg /
##                                     qt6-positioning.
##   * ``FEATURE_clang=OFF``        -- disable qdoc/Clang dependency
##                                     (same trip as qt6-declarative).
##   * ``CMAKE_DISABLE_FIND_PACKAGE_Clang=TRUE``
##                                  -- belt-and-braces FEATURE_clang
##                                     disable.
##   * ``CMAKE_DISABLE_FIND_PACKAGE_LLVM=TRUE``
##                                  -- belt-and-braces FEATURE_clang
##                                     disable.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package qt6QuickControls2Source:
  ## From-source qt6-quickcontrols2 -- M9.R.19.1 ReproOS Installer
  ## blocker.  Sibling to qt6-base (qt6BaseSource), qt6-tools
  ## (qt6ToolsSource), qt6-declarative (qt6DeclarativeSource), qt6-svg
  ## (qt6SvgSource), qt6-positioning (qt6PositioningSource); shares the
  ## same 6.8.1 pin.  Builds against the shared qtdeclarative tarball
  ## because QtQuickControls2 was merged INTO qtdeclarative in Qt 6.2
  ## (see header docstring for the upstream merge rationale).

  versions:
    "6.8.1":
      sourceRevision = "v6.8.1"
      sourceUrl = "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtdeclarative-everywhere-src-6.8.1.tar.xz"
      sourceRepository = "https://code.qt.io/qt/qtdeclarative.git"

  fetch:
    ## Sibling-vendored tarball.  ``file:../qt6-declarative/vendor/...``
    ## resolves to the sibling qt6-declarative recipe's vendored
    ## tarball; no duplicate 36-MiB blob is committed here.  The
    ## ``file:../`` form is supported by cmake_package's URL resolver
    ## per M9.R.15q.5.4.
    url: "file:../qt6-declarative/vendor/qtdeclarative-everywhere-src-6.8.1.tar.xz"
    sha256: "95d15d5c1b6adcedb1df6485219ad13b8dc1bb5168b5151f2f1f7246a4c039fc"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.21"
    "ninja >=1.10"
    "gcc >=11"
    "perl >=5.32"
    "pkg-config"
    "python3 >=3.8"
    "qt6-tools >=6.8"

  buildDeps:
    ## qt6-base supplies QtCore + QtGui + QtNetwork the controls library
    ## links against.
    "qt6-base >=6.8"
    ## qt6-shadertools supplies the ``qsb`` shader-bundle tool the
    ## qtdeclarative configure probes for at build time.  Without qsb
    ## the configure SKIPS libQt6Quick.so + libQt6QuickControls2.so
    ## artifacts entirely -- same trip as qt6-declarative M9.R.15n.2.
    "qt6-shadertools >=6.8"

  config:
    discard

  library libQt6QuickControls2:
    ## ``libQt6QuickControls2.so`` -- the desktop-style Quick controls
    ## library the reproos-installer wizard's QML scenes consume
    ## (Button / ComboBox / TextField / ScrollView / TextArea /
    ## ProgressBar / CheckBox per ReproOS-Installer-PRD.md Sec 7.1).
    ## v1 records the artifact only.
    discard

  build:
    setCurrentOwningPackageOverride("qt6QuickControls2Source")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
        "QT_BUILD_TESTS=OFF",
        "QT_BUILD_EXAMPLES=OFF",
        # Qt6's SBOM module hard-codes the canonical install prefix
        # (matches qt6-base M9.R.15f.3 + qt6-tools M9.R.15h.1.4 +
        # qt6-declarative M9.R.15j.1 + qt6-svg M9.R.15k.1 +
        # qt6-positioning M9.R.15q.9.1).  Disable SBOM gen for v1.
        "QT_GENERATE_SBOM=OFF",
        # Disable FEATURE_clang (qdoc dependency) -- same trip as
        # qt6-declarative M9.R.15j.1 on cross-mounted WSL builds.
        "FEATURE_clang=OFF",
        "CMAKE_DISABLE_FIND_PACKAGE_Clang=TRUE",
        "CMAKE_DISABLE_FIND_PACKAGE_LLVM=TRUE",
      ]
      # M9.R.19.1 -- when building qtdeclarative as the source for
      # qt6-quickcontrols2, CMake's implicit-include-dir scan picks
      # up sibling recipes' include dirs (qt6-base, qt6-tools, glib2,
      # ...) from the nix-shell's NIX_CFLAGS_COMPILE env var that
      # the cmake compile-test reads. CMake then DEDUPLICATES the
      # explicit -I.../QtCore + -isystem .../usr/include flags out
      # of the per-target compile commands because it thinks gcc
      # already has them. The actual build invocation drops
      # NIX_CFLAGS_COMPILE (it's a configure-time env), so the
      # compiler invocation is missing those paths -- breaking
      # qrc_*_init.cpp compiles that #include <QtCore/qtsymbolmacros.h>.
      #
      # Clear NIX_CFLAGS_COMPILE for the cmake invocation so the
      # implicit-include-dir scan doesn't pick up sibling Qt installs.
      # qt6-declarative's recipe was lucky -- it ran in a nix-shell env
      # that happened not to surface the sibling Qt include dirs in
      # the C/CXX implicit scan, but the env nondeterminism shouldn't
      # be relied upon.
      let env = @[
        ("NIX_CFLAGS_COMPILE", ""),
        ("NIX_CFLAGS_COMPILE_FOR_TARGET", ""),
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts, extraEnv = env)
      discard pkg.library("libQt6QuickControls2")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
