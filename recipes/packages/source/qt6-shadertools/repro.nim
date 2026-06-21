## Source-from-tarball qt6-shadertools recipe — M9.R.15n.2 Qt Quick
## blocker. qt6-shadertools supplies the ``qsb`` shader-bundle tool
## that qt6-declarative's Qt Quick scene-graph compiler invokes at
## build time to compile shaders to Qt's RHI bytecode. Without qsb,
## qt6-declarative's configure prints
## ``Qt Quick modules not built due to not finding the qtshadertools
## 'qsb' tool`` and SKIPS building libQt6Quick.so +
## libQt6QuickControls2.so — leaving KF6 modules (ksvg, kio, kded) +
## Plasma framework + kwin unable to link against Qt6::Quick.
##
## ## sha256 strategy
##
## We vendor the upstream 6.8.1 .tar.xz at
## ``recipes/packages/source/qt6-shadertools/vendor/qtshadertools-everywhere-src-6.8.1.tar.xz``
## and reference it via the upstream download.qt.io URL. The 1-MiB
## tarball is well under GitHub's 100-MB single-file ceiling so
## vendoring is safe; sibling Qt6 modules vendor similarly.
##
## sha256 = 55b70cd632473a8043c74ba89310f7ba9c5041d253bc60e7ae1fa789169c4846
##  (computed locally over the vendored
##  ``qtshadertools-everywhere-src-6.8.1.tar.xz``, 1,138,644 bytes;
##  downloaded once from the upstream URL recorded in ``versions:``
##  below).
##
## ## Version choice — 6.8.1 (matches qt6-base + qt6-tools + qt6-declarative)
##
## qt6-shadertools is a coordinated Qt6 release sibling to qt6-base;
## the 6.8.1 tag matches the rest of the Qt6 batch.
##
## ## Build shape
##
## The c_cpp_cmake convention (M9.K) reads the M9.H ``fetch:`` block
## and the inlined ``cmake_package`` flags and lowers them into:
##
##   1. a fetch BuildAction whose argv carries the URL + sha256 +
##      extract dest.
##   2. a ``cmake`` configure BuildAction.
##   3. a ``cmake --build`` compile BuildAction.
##   4. install/output collection actions.
##
## ## Artifacts
##
## qt6-shadertools's CMake build emits:
##
##   * ``libQt6ShaderTools.so`` — the shader-compiler runtime library
##                                  (used at build time by qsb).
##   * ``qsb`` — the shader-bundle tool qt6-declarative invokes at
##                 configure time to detect Qt Quick build capability.
##
## v1 records the ``qsb`` executable as the primary artifact since that
## is what consumers actually probe for. ``libQt6ShaderTools`` is
## available to consumers through the install-mirror but not registered
## as a separate artifact (it's a build-time helper, not a runtime
## consumer-facing API like libQt6Core/libQt6Quick).
##
## ## Configurables
##
## v1 ships NO configurables — same baseline as sibling Qt6 recipes
## (BUILD_TESTING=OFF + CMAKE_BUILD_TYPE=Release + QT_BUILD_TESTS=OFF +
## QT_BUILD_EXAMPLES=OFF + QT_GENERATE_SBOM=OFF).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package qt6ShaderToolsSource:
  ## From-source qt6-shadertools — M9.R.15n.2 Qt Quick blocker. Sibling
  ## to qt6-base, qt6-tools, qt6-declarative, qt6-svg; shares the same
  ## 6.8.1 pin.
  ##
  ## Tier-2b c_cpp_cmake convention consumer. Library + executable
  ## artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.qt.io release tarball URL.
    ##
    ## ``sourceRepository`` points at the canonical code.qt.io
    ## qtshadertools git repository.
    "6.8.1":
      sourceRevision = "v6.8.1"
      sourceUrl = "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtshadertools-everywhere-src-6.8.1.tar.xz"
      sourceRepository = "https://code.qt.io/qt/qtshadertools.git"

  fetch:
    ## Vendored tarball. ``file://`` URL keeps the build deterministic.
    ##
    ## sha256 computed over the vendored 1,138,644-byte tarball.
    url: "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtshadertools-everywhere-src-6.8.1.tar.xz"
    sha256: "55b70cd632473a8043c74ba89310f7ba9c5041d253bc60e7ae1fa789169c4846"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver.
    "cmake >=3.21"
    ## ninja is CMake's preferred backend on Linux.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — qt6-shadertools is C++17.
    "gcc >=11"
    ## perl is needed by qt6-shadertools's syncqt helper script
    ## (forwarding headers + module-header generation, same pattern as
    ## qt6-base / qt6-tools / qt6-declarative).
    "perl >=5.32"
    ## pkg-config is used by the CMake configure step.
    "pkg-config"
    ## python is invoked by Qt's syncqt + code-generation helpers.
    "python3 >=3.8"

  buildDeps:
    ## qt6-base supplies QtCore + QtGui + QtNetwork the qt6-shadertools
    ## library + qsb tool link against.
    "qt6-base >=6.8"

  config:
    ## No prefix lifted from `cmakeFlags:`; flags inlined in the
    ## `build:` block.
    discard

  executable qsb:
    ## ``/usr/bin/qsb`` — the shader-bundle tool qt6-declarative invokes
    ## at configure time to detect Qt Quick build capability. v1
    ## records the artifact only.
    discard

  library libQt6ShaderTools:
    ## ``libQt6ShaderTools.so`` — the shader-compiler runtime library.
    ## qsb links against this; consumer modules use it transitively. v1
    ## records the artifact only.
    discard

  build:
    ## M9.R.15n.2 — explicit `build:` block invoking the
    ## ``cmake_package(...)`` high-level constructor.
    setCurrentOwningPackageOverride("qt6ShaderToolsSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
        "QT_BUILD_TESTS=OFF",
        "QT_BUILD_EXAMPLES=OFF",
        # M9.R.15n.2 — Qt6's SBOM module hard-codes
        # ``/usr/local/Qt-6.8.1`` as the canonical install prefix.
        # Same trip as qt6-base / qt6-tools / qt6-declarative / qt6-svg.
        "QT_GENERATE_SBOM=OFF",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.executable("qsb")
      discard pkg.library("libQt6ShaderTools")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts.
    discard
