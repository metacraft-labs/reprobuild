## Source-from-tarball kwidgetsaddons recipe — the THIRTY-EIGHTH real
## from-source production recipe to exercise the M9.H/I/K trio and the
## THIRD recipe in the KF6 module-sweep batch (kconfig / ki18n /
## kwidgetsaddons / kxmlgui).
##
## kwidgetsaddons is the NINTH CMake-driven recipe and the FOURTH KF6
## foundation module after kcoreaddons + kconfig + ki18n.
##
## ## Why kwidgetsaddons matters for the v1 desktop story
##
## kwidgetsaddons (``libKF6WidgetsAddons.so``) supplies the cross-
## cutting QtWidgets extensions every KF6 application + Plasma
## component uses on the GUI side: ``KMessageBox``, ``KPasswordDialog``,
## ``KSeparator``, ``KColorButton``, ``KPageWidget``, ``KRichTextEdit``,
## ``KToolBar`` extensions, ``KAssistantDialog``, etc. kxmlgui +
## kcompletion + kio-widgets layer on top of this for the standard
## KF6 widget vocabulary that Plasma's panel/krunner/systemsettings
## skin onto.
##
## ## sha256 strategy
##
## We vendor the upstream 6.10.0 .tar.xz at
## ``recipes/packages/source/kwidgetsaddons/vendor/kwidgetsaddons-6.10.0.tar.xz``
## and reference it via a ``file://`` URL.
##
## ## Version choice — 6.10.0 (current upstream stable in the 6.x line)
##
## Same lockstep ABI rationale as the sibling kconfig/ki18n recipes.
##
## sha256 = e0fa4943d7874287fd2c2c254f1ef21edf7e573b6b19354df5fdef8cbbefe74e
##  (computed locally over the vendored ``kwidgetsaddons-6.10.0.tar.xz``,
##  4,277,788 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## c_cpp_cmake convention (M9.K) — same as the sibling KF6 recipes.
##
## ## Library artifact
##
## kwidgetsaddons's CMake build emits a single shared library
## (``libKF6WidgetsAddons.so``) bundling the QtWidgets extensions
## listed above. We register the artifact under ``libKF6WidgetsAddons``
## (camelCased from the upstream SONAME ``KF6WidgetsAddons``).
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

package kwidgetsaddonsSource:
  ## From-source kwidgetsaddons — thirty-eighth M9.H/I/K production
  ## recipe and the THIRD recipe in the KF6 module-sweep batch. Ninth
  ## CMake-driven recipe and the FOURTH KF6 foundation module after
  ## kcoreaddons + kconfig + ki18n.
  ##
  ## Tier-2b c_cpp_cmake convention consumer. Single library artifact
  ## recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.kde.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kwidgetsaddons-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kwidgetsaddons"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable.
    ##
    ## sha256 was computed over the vendored 4,277,788-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/kwidgetsaddons/vendor/kwidgetsaddons-6.10.0.tar.xz"
    sha256: "e0fa4943d7874287fd2c2c254f1ef21edf7e573b6b19354df5fdef8cbbefe74e"
    extractStrip: 1

  uses:
    ## cmake is the build-system driver.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — kwidgetsaddons is C++17.
    "gcc >=11"
    ## qt6-base supplies QtCore / QtGui / QtWidgets which the
    ## kwidgetsaddons surface extends.
    "qt6-base >=6.6"
    ## qt6-tools supplies ``qhelpgenerator`` for QCH generation
    ## (disabled via ``BUILD_QCH=OFF`` but the ECM module still
    ## probes for the tool at configure time).
    "qt6-tools >=6.6"

  cmakeFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: CMake evaluates ``-D`` overrides
    ## left-to-right.
    "-DBUILD_TESTING=OFF"
    "-DBUILD_QCH=OFF"
    "-DBUILD_PYTHON_BINDINGS=OFF"
    "-DCMAKE_BUILD_TYPE=Release"

  library libKF6WidgetsAddons:
    ## ``libKF6WidgetsAddons.so`` — cross-cutting QtWidgets extensions
    ## (KMessageBox + KPasswordDialog + KSeparator + KColorButton +
    ## KPageWidget + KRichTextEdit + KToolBar extensions +
    ## KAssistantDialog + ...). v1 records the artifact only; the
    ## per-artifact build body lands in M9.L when the convention's
    ## ninja-spawn + install-glue closes.
    discard
