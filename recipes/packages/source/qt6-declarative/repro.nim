## Source-from-tarball qt6-declarative recipe — M9.R.15j.1 KF6/Plasma
## blocker. qt6-declarative supplies QtQml / QtQuick / QtQuickControls2
## which kdeclarative + knotifications + kio + ksvg + kpackage + every
## Plasma component (kwin, plasma-workspace, sddm) consume.
##
## Without qt6-declarative the v1 Plasma cascade can't close: kwin's
## compositor effects + plasma-workspace's panel + sddm's greeter all
## render through QtQuick scene-graph, and knotifications' popup widgets
## use Qml.
##
## ## sha256 strategy
##
## We vendor the upstream 6.8.1 .tar.xz at
## ``recipes/packages/source/qt6-declarative/vendor/qtdeclarative-everywhere-src-6.8.1.tar.xz``
## and reference it via the upstream download.qt.io URL. The 36 MiB
## tarball is well under GitHub's 100-MB single-file ceiling so
## vendoring is safe; sibling ``qt6-base`` vendors the matching 48-MiB
## qtbase tarball with the same strategy.
##
## sha256 = 95d15d5c1b6adcedb1df6485219ad13b8dc1bb5168b5151f2f1f7246a4c039fc
##  (computed locally over the vendored
##  ``qtdeclarative-everywhere-src-6.8.1.tar.xz``, 36,463,572 bytes;
##  downloaded once from the upstream URL recorded in ``versions:``
##  below; cross-checked against the upstream HTTP Digest: SHA-256
##  header on download.qt.io's HEAD response).
##
## ## Version choice — 6.8.1 (matches qt6-base + qt6-tools)
##
## download.qt.io publishes Qt6 modular submodule sources at
## ``https://download.qt.io/official_releases/qt/<major.minor>/<version>/submodules/``
## and 6.8.1 is the current stable in the 6.8.x line as of mid-2026.
## qt6-base + qt6-tools sibling recipes pin the same 6.8.1 tag; the Qt
## module set is built as a coordinated release so cross-module ABI
## matches tag-for-tag.
##
## ## Build shape
##
## The c_cpp_cmake convention (M9.K) reads both the M9.H ``fetch:``
## block and the inlined ``cmake_package`` flags and lowers them into:
##
##   1. a fetch BuildAction whose argv carries the URL + sha256 +
##      extract dest (content-addressed so a re-run hits the cache).
##   2. a ``cmake`` configure BuildAction that depends on the fetch
##      action and passes every flag in the inlined ``opts`` to
##      ``cmake -S <src> -B <build>``, in declared order.
##   3. a ``ninja`` (or ``cmake --build``) compile BuildAction.
##   4. install/output collection actions for the libraries.
##
## ## Library artifacts
##
## qt6-declarative's CMake build emits multiple shared libraries; the v1
## KF6/Plasma closure needs:
##
##   * ``libQt6Qml.so``              — the QML language runtime.
##   * ``libQt6Quick.so``             — the Quick scene-graph + items.
##   * ``libQt6QuickControls2.so``    — the desktop-style Quick controls.
##
## ## Configurables
##
## v1 ships NO configurables — the CMake options are hardcoded to the
## modern-desktop baseline:
##
##   * ``BUILD_TESTING=OFF``        — skip the upstream test suite to
##                                     keep the build hermetic + fast.
##   * ``CMAKE_BUILD_TYPE=Release`` — release-mode optimisation;
##                                     matches sibling qt6-base /
##                                     qt6-tools recipes.
##   * ``QT_BUILD_TESTS=OFF``       — Qt-side test-build disable.
##   * ``QT_BUILD_EXAMPLES=OFF``    — skip the upstream examples build.
##   * ``QT_GENERATE_SBOM=OFF``     — SBOM gen hard-codes the canonical
##                                     install prefix and fails when our
##                                     cmake_package install passes a
##                                     different ``--prefix``.  Same
##                                     trip as qt6-base / qt6-tools.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package qt6DeclarativeSource:
  ## From-source qt6-declarative — M9.R.15j.1 KF6/Plasma blocker.
  ## Sibling to qt6-base (qt6BaseSource) and qt6-tools (qt6ToolsSource);
  ## shares the same 6.8.1 pin.
  ##
  ## Tier-2b c_cpp_cmake convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the inlined ``cmake_package`` flags and lowers them into fetch +
  ## configure BuildActions wired with the right URL + hash + flags.
  ## Three library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.qt.io release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the same upstream URL.
    ##
    ## ``sourceRepository`` points at the canonical code.qt.io
    ## qtdeclarative git repository.
    "6.8.1":
      sourceRevision = "v6.8.1"
      sourceUrl = "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtdeclarative-everywhere-src-6.8.1.tar.xz"
      sourceRepository = "https://code.qt.io/qt/qtdeclarative.git"

  fetch:
    ## Vendored tarball. The 36-MiB tarball is well under GitHub's
    ## 100-MB single-file ceiling so vendoring is safe; sibling qt6-base
    ## vendors the matching 48-MiB qtbase tarball with the same strategy.
    ##
    ## sha256 was computed over the vendored 36,463,572-byte tarball
    ## downloaded once from the upstream URL recorded in ``versions:``
    ## above.
    url: "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtdeclarative-everywhere-src-6.8.1.tar.xz"
    sha256: "95d15d5c1b6adcedb1df6485219ad13b8dc1bb5168b5151f2f1f7246a4c039fc"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver — the c_cpp_cmake convention's
    ## configure action invokes ``cmake -S <src> -B <build>``.
    ## qt6-declarative 6.8.x requires cmake 3.21 for the modern
    ## qt-internal-build helper macros (matches qt6-base / qt6-tools
    ## 6.8.1's cmake floor).
    "cmake >=3.21"
    ## ninja is CMake's preferred backend on Linux — the compile action
    ## invokes ``ninja`` (or ``cmake --build``) against the CMake build
    ## directory.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — qt6-declarative is C++17.
    "gcc >=11"
    ## perl is needed by qt6-declarative's syncqt helper script
    ## (forwarding headers + module-header generation, same as qt6-base
    ## / qt6-tools).
    "perl >=5.32"
    ## pkg-config is used by the CMake configure step to probe for
    ## qt6-base's installed pkgconfig.
    "pkg-config"
    ## python is invoked by qt6-declarative's code-generation helpers
    ## (matches qt6-base / qt6-tools nativeBuildDep set).
    "python3 >=3.8"

  buildDeps:
    ## qt6-base supplies QtCore + QtGui + QtNetwork + QtQml-runtime
    ## C++ underpinnings — qt6-declarative links against every one for
    ## the Qml/Quick/QuickControls2 libraries. The sibling
    ## ``qt6BaseSource`` recipe vendors 6.8.1.
    "qt6-base >=6.8"

  config:
    ## No prefix lifted from `cmakeFlags:`; flags inlined in the `build:` block.
    discard

  library libQt6Qml:
    ## ``libQt6Qml.so`` — the QML language runtime KF6 + Plasma
    ## consume for scene-graph item declarations. v1 records the
    ## artifact only.
    discard

  library libQt6Quick:
    ## ``libQt6Quick.so`` — the Quick scene-graph + items KF6 + Plasma
    ## consume for QtQuick window rendering. v1 records the artifact
    ## only.
    discard

  library libQt6QuickControls2:
    ## ``libQt6QuickControls2.so`` — the desktop-style Quick controls
    ## KF6 + Plasma applets consume. v1 records the artifact only.
    discard

  build:
    ## M9.R.15j.1 — explicit `build:` block invoking the
    ## ``cmake_package(...)`` high-level constructor.
    setCurrentOwningPackageOverride("qt6DeclarativeSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
        "QT_BUILD_TESTS=OFF",
        "QT_BUILD_EXAMPLES=OFF",
        # M9.R.15j.1 — Qt6's SBOM module hard-codes
        # ``/usr/local/Qt-6.8.1`` as the canonical install prefix when
        # computing per-artifact checksums (same trip as qt6-base
        # M9.R.15f.3 + qt6-tools M9.R.15h.1.4). The
        # ``cmake --install --prefix <buildDir>/out/usr`` we emit doesn't
        # match the baked-in prefix, so install fails with "Cannot find
        # <file> to compute its checksum". Disable SBOM gen for v1.
        "QT_GENERATE_SBOM=OFF",
        # M9.R.15j.1 — disable FEATURE_clang (qdoc dependency).
        # qt6-declarative shares the qt6-tools FEATURE_clang configure
        # trip on cross-mounted WSL builds where MSYS2's mingw64
        # ClangConfig.cmake gets latched; same surgical workaround as
        # qt6-tools M9.R.15h.1.
        "FEATURE_clang=OFF",
        "CMAKE_DISABLE_FIND_PACKAGE_Clang=TRUE",
        "CMAKE_DISABLE_FIND_PACKAGE_LLVM=TRUE",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libQt6Qml")
      discard pkg.library("libQt6Quick")
      discard pkg.library("libQt6QuickControls2")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
