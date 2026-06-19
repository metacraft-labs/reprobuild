## Source-from-tarball ki18n recipe — the THIRTY-SEVENTH real from-
## source production recipe to exercise the M9.H/I/K trio and the
## SECOND recipe in the KF6 module-sweep batch (kconfig / ki18n /
## kwidgetsaddons / kxmlgui).
##
## ki18n is the EIGHTH CMake-driven recipe and the THIRD KF6 foundation
## module after kcoreaddons + kconfig.
##
## ## Why ki18n matters for the v1 desktop story
##
## ki18n (``libKF6I18n.so``) is the KF6 translation/internationalisation
## stack. It wraps gettext/libintl with a Qt-native interface
## (``KLocalizedString``, ``i18n()`` / ``i18nc()`` / ``i18np()`` macros)
## that every KF6 application and every Plasma component uses for user-
## facing strings. kwin's ``uses:`` block declares ``kf6-base`` which
## umbrella-bundles ki18n alongside kconfig + kwidgetsaddons + kxmlgui;
## lifting that umbrella to per-module from-source recipes lets the v2
## Plasma story link against individually pinned KF6 modules.
##
## ## sha256 strategy
##
## We vendor the upstream 6.10.0 .tar.xz at
## ``recipes/packages/source/ki18n/vendor/ki18n-6.10.0.tar.xz`` and
## reference it via a ``file://`` URL. The download.kde.org release URL
## is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 6.10.0 (current upstream stable in the 6.x line)
##
## Same lockstep ABI rationale as the sibling kconfig recipe.
##
## sha256 = 2f59f093f8ce340ab46c556b35c2ead2b96dfeb2ff0024c553ac8c53e9b8a11a
##  (computed locally over the vendored ``ki18n-6.10.0.tar.xz``,
##  3,112,804 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_cmake convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``cmakeFlags:`` block off this package's
## registries and lowers them into fetch + configure BuildActions; the
## downstream ninja-spawn + install glue lands in M9.L; the recipe
## records the library artifact via the ``library`` block so the M9.K
## artifact registry already knows what shared object to expect.
##
## ## Library artifact
##
## ki18n's CMake build emits a single shared library
## (``libKF6I18n.so``) bundling the ``KLocalizedString`` /
## ``KLocalizedContext`` / ``KLocalizedTranslator`` /
## ``KCountry`` / ``KLanguageName`` classes that wrap gettext for the
## KF6 ecosystem. We register the artifact under the package-level
## identifier ``libKF6I18n`` (camelCased from the upstream SONAME
## ``KF6I18n``).
##
## ## Configurables
##
## v1 ships NO configurables — same modern-desktop baseline as the
## sibling KF6 recipes (``BUILD_TESTING=OFF`` + ``BUILD_QCH=OFF`` +
## ``BUILD_PYTHON_BINDINGS=OFF`` + ``CMAKE_BUILD_TYPE=Release``).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package ki18nSource:
  ## From-source ki18n — thirty-seventh M9.H/I/K production recipe and
  ## the SECOND recipe in the KF6 module-sweep batch. Eighth CMake-
  ## driven recipe and the THIRD KF6 foundation module after
  ## kcoreaddons + kconfig.
  ##
  ## Tier-2b c_cpp_cmake convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``cmakeFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"cmake"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags. Single library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.kde.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/ki18n-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/ki18n"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 3,112,804-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/ki18n/vendor/ki18n-6.10.0.tar.xz"
    sha256: "2f59f093f8ce340ab46c556b35c2ead2b96dfeb2ff0024c553ac8c53e9b8a11a"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver — the c_cpp_cmake convention's
    ## configure action invokes ``cmake -S <src> -B <build>``.
    ## ki18n 6.x requires cmake 3.16 for the modern ECM + Qt6
    ## ``find_package`` semantics the KF6 ABI line depends on.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — ki18n is C++17.
    "gcc >=11"
    ## gettext supplies the libintl runtime ki18n wraps + the
    ## ``msgfmt``/``msgmerge`` build-time tools the CMake build invokes
    ## to compile ``.po`` translation catalogues into ``.mo`` files.
    "gettext >=0.21"

  buildDeps:
    ## qt6-base supplies QtCore / QtQml / QtTest the ki18n surface
    ## wraps. 6.6 is the minimum the 6.10 frameworks line targets.
    "qt6-base >=6.6"
    ## qt6-tools supplies ``qhelpgenerator`` for QCH generation (we
    ## disable QCH via ``BUILD_QCH=OFF`` but the ECM module still
    ## probes for the tool at configure time).
    "qt6-tools >=6.6"

  cmakeFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: CMake evaluates ``-D`` overrides
    ## left-to-right and the ``CMAKE_BUILD_TYPE=Release`` sentinel
    ## lives at the tail so any override (e.g. a future debug-build
    ## variant) can append ``-DCMAKE_BUILD_TYPE=Debug`` later without
    ## re-ordering this block.
    "-DBUILD_TESTING=OFF"
    "-DBUILD_QCH=OFF"
    "-DBUILD_PYTHON_BINDINGS=OFF"
    "-DCMAKE_BUILD_TYPE=Release"

  library libKF6I18n:
    ## ``libKF6I18n.so`` — KLocalizedString + KCountry +
    ## KLanguageName + KLocalizedContext + KLocalizedTranslator
    ## classes wrapping gettext for the KF6 ecosystem. v1 records the
    ## artifact only; the per-artifact build body lands in M9.L when
    ## the convention's ninja-spawn + install-glue closes.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
