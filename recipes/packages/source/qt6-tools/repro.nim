## Source-from-tarball qt6-tools recipe — adds the qt6-tools module
## that every KF6 recipe declares as a buildDep (lupdate, lrelease,
## qhelpgenerator, qdoc). M9.R.15f.2.
##
## ## Why qt6-tools matters
##
## Every KF6 module (kcoreaddons, kconfig, ki18n, kwidgetsaddons,
## kxmlgui, kservice, kglobalaccel, knotifications, ksvg, ksolid, kio,
## kded, plasma-framework) declares ``qt6-tools >=6.6`` in its
## ``buildDeps:`` block. The ECM (Extra CMake Modules) macros KF6
## consumes probe for ``qhelpgenerator`` at configure time even when
## ``BUILD_QCH=OFF`` (the probe-then-skip path is hard-coded). Without
## qt6-tools the KF6 cascade cannot publish.
##
## qt6-tools is also the canonical home of ``lupdate`` / ``lrelease``
## (Qt Linguist tooling KF6's translations build invokes) and
## ``qdoc`` (the documentation generator the ECM module uses to
## populate the Doxygen-style API doc surface that drives
## ``BUILD_QCH``).
##
## ## sha256 strategy
##
## We vendor the upstream 6.8.1 .tar.xz at
## ``recipes/packages/source/qt6-tools/vendor/qttools-everywhere-src-6.8.1.tar.xz``
## and reference it via the upstream download.qt.io URL. The 10 MiB
## tarball is well under GitHub's 100-MB single-file ceiling so
## vendoring is safe; sibling ``qt6-base`` vendors the matching
## 48-MiB qtbase tarball with the same strategy.
##
## sha256 = 9d43d409be08b8681a0155a9c65114b69c9a3fc11aef6487bb7fdc5b283c432d
##  (computed locally over the vendored
##  ``qttools-everywhere-src-6.8.1.tar.xz``, 10,293,192 bytes;
##  downloaded once from the upstream URL recorded in ``versions:``
##  above).
##
## ## Version choice — 6.8.1 (matches qt6-base)
##
## download.qt.io publishes Qt6 modular submodule sources at
## ``https://download.qt.io/official_releases/qt/<major.minor>/<version>/submodules/``
## and 6.8.1 is the current stable in the 6.8.x line as of mid-2026.
## The qt6-base sibling recipe pins the same 6.8.1 tag; the Qt module
## set is built as a coordinated release so cross-module ABI matches
## tag-for-tag.
##
## ## Build shape
##
## The c_cpp_cmake convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``cmakeFlags:`` block off this package's
## registries and lowers them into:
##
##   1. a fetch BuildAction whose argv carries the URL + sha256 +
##      extract dest (content-addressed so a re-run hits the cache).
##   2. a ``cmake`` configure BuildAction that depends on the fetch
##      action and passes every flag in ``cmakeFlags:`` to
##      ``cmake -S <src> -B <build>``, in declared order.
##   3. a ``ninja`` (or ``cmake --build``) compile BuildAction.
##   4. install/output collection actions for the executables (M9.L).
##
## ## Executable artifacts
##
## qt6-tools ships a family of build-time executables; the v1 KF6
## cascade needs ``qhelpgenerator`` + ``lupdate`` + ``lrelease`` at
## configure / translation time. We register all three under their
## upstream binary names; the M9.K artifact registry then knows what
## binaries to expect on install.
##
##   * ``qhelpgenerator`` — QCH-format compressed help generator;
##                          ECM probes for it even when BUILD_QCH=OFF.
##   * ``lupdate``        — Qt Linguist translation-source updater
##                          KF6's translations build invokes.
##   * ``lrelease``       — Qt Linguist .qm-compiler KF6's translations
##                          install step invokes.
##
## ## Configurables
##
## v1 ships NO configurables — the CMake options are hardcoded to the
## modern-desktop baseline:
##
##   * ``BUILD_TESTING=OFF``        — skip the upstream test suite to
##                                     keep the build hermetic + fast.
##   * ``CMAKE_BUILD_TYPE=Release`` — release-mode optimisation;
##                                     matches the sibling qt6-base /
##                                     kcoreaddons recipes.
##   * ``QT_BUILD_TESTS=OFF``        — Qt-side test-build disable
##                                     (qt6-tools honours QT_BUILD_*
##                                     separately from BUILD_TESTING).
##   * ``QT_BUILD_EXAMPLES=OFF``    — skip the upstream examples build;
##                                     not in the v1 closure.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package qt6ToolsSource:
  ## From-source qt6-tools — adds the missing qt6-tools module every
  ## KF6 recipe declares as a buildDep. Sibling to qt6-base
  ## (qt6BaseSource) and shares the same 6.8.1 pin.
  ##
  ## Tier-2b c_cpp_cmake convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``cmakeFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"cmake"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right URL +
  ## hash + flags.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.qt.io release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the same upstream URL.
    ##
    ## ``sourceRepository`` points at the canonical code.qt.io qttools
    ## git repository.
    "6.8.1":
      sourceRevision = "v6.8.1"
      sourceUrl = "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qttools-everywhere-src-6.8.1.tar.xz"
      sourceRepository = "https://code.qt.io/qt/qttools.git"

  fetch:
    ## Vendored tarball. The 10-MiB tarball is well under GitHub's
    ## 100-MB single-file ceiling so vendoring is safe; sibling
    ## qt6-base vendors the matching 48-MiB qtbase tarball with the
    ## same strategy.
    ##
    ## sha256 was computed over the vendored 10,293,192-byte tarball
    ## downloaded once from the upstream URL recorded in ``versions:``
    ## above.
    url: "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qttools-everywhere-src-6.8.1.tar.xz"
    sha256: "9d43d409be08b8681a0155a9c65114b69c9a3fc11aef6487bb7fdc5b283c432d"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver — the c_cpp_cmake convention's
    ## configure action invokes ``cmake -S <src> -B <build>``. qt6-tools
    ## 6.8.x requires cmake 3.21 for the modern qt-internal-build helper
    ## macros that drive the per-feature module gating (matches qt6-base
    ## 6.8.1's cmake floor).
    "cmake >=3.21"
    ## ninja is CMake's preferred backend on Linux — the compile action
    ## invokes ``ninja`` (or ``cmake --build``) against the CMake build
    ## directory.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — qt6-tools is C++17.
    "gcc >=11"
    ## perl is needed by qt6-tools's syncqt helper script (forwarding
    ## headers + module-header generation, same as qt6-base).
    "perl >=5.32"
    ## pkg-config is used by the CMake configure step to probe for
    ## qt6-base's installed pkgconfig.
    "pkg-config"
    ## python is invoked by qt6-tools's code-generation helpers
    ## (matches qt6-base's nativeBuildDep set).
    "python3 >=3.8"

  buildDeps:
    ## qt6-base supplies QtCore + QtGui + QtWidgets + QtNetwork +
    ## QtSql — qt6-tools links against every one of these for the
    ## linguist/assistant/designer/qhelpgenerator binaries. The
    ## sibling ``qt6BaseSource`` recipe vendors 6.8.1.
    "qt6-base >=6.8"

  config:
    ## No prefix lifted from `cmakeFlags:`; flags inlined in the `build:` block.
    discard

  executable qhelpgenerator:
    ## ``qhelpgenerator`` — QCH-format compressed help generator the
    ## ECM (Extra CMake Modules) macros probe for at configure time
    ## even when ``BUILD_QCH=OFF``. v1 records the artifact only.
    discard

  executable lupdate:
    ## ``lupdate`` — Qt Linguist translation-source updater KF6's
    ## translations build invokes. v1 records the artifact only.
    discard

  executable lrelease:
    ## ``lrelease`` — Qt Linguist .qm-compiler KF6's translations
    ## install step invokes. v1 records the artifact only.
    discard

  build:
    ## M9.R.15f.2 — explicit `build:` block constructed from the
    ## inlined verbatim flags. Calls the M9.R.2b high-level
    ## `cmake_package(...)` constructor.
    setCurrentOwningPackageOverride("qt6ToolsSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
        "QT_BUILD_TESTS=OFF",
        "QT_BUILD_EXAMPLES=OFF",
        # M9.R.15h.1 — disable FEATURE_clang to skip qdoc + libclang
        # dependency. The qt6-tools configure.cmake unconditionally
        # probes ``WrapLibClang`` (line 20, BEFORE any feature gate);
        # its FindWrapLibClang.cmake delegates to ``find_package(Clang
        # CONFIG)`` which on cross-mounted WSL builds latches onto
        # Windows MSYS2's mingw64 ClangConfig.cmake at
        # ``/mnt/d/metacraft-dev-deps/msys2/...``. That config then
        # tries to load LLVMConfig.cmake (22.1.4) which the MSYS2
        # install doesn't have, hard-failing the configure.
        #
        # ``CMAKE_DISABLE_FIND_PACKAGE_Clang=TRUE`` makes
        # ``find_package(Clang CONFIG)`` short-circuit to NOT FOUND
        # (Clang is the package the FindWrapLibClang.cmake delegate
        # actually fails on). FEATURE_clang=OFF is the matching
        # high-level gate so the rest of the configure tree records
        # the disable cleanly.
        #
        # qdoc is only the API-documentation generator (Doxygen-style);
        # the v1 KF6 cascade only needs qhelpgenerator + lupdate +
        # lrelease, none of which depend on FEATURE_clang.
        "FEATURE_clang=OFF",
        "CMAKE_DISABLE_FIND_PACKAGE_Clang=TRUE",
        "CMAKE_DISABLE_FIND_PACKAGE_LLVM=TRUE",
        # M9.R.15h.1.4 — Qt6's SBOM module hard-codes ``/usr/local/Qt-6.8.1``
        # as the canonical install prefix when computing per-artifact
        # checksums (same trip as qt6-base M9.R.15f.3). The
        # ``cmake --install --prefix <buildDir>/out/usr`` we emit doesn't
        # match the baked-in prefix, so install fails at
        # ``SPDXRef-PackagedFile-qt-module-UiTools.cmake:5`` with "Cannot
        # find <file> to compute its checksum". Disable SBOM gen for v1.
        "QT_GENERATE_SBOM=OFF",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.executable("qhelpgenerator")
      discard pkg.executable("lupdate")
      discard pkg.executable("lrelease")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
