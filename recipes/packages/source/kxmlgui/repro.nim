## Source-from-tarball kxmlgui recipe — the THIRTY-NINTH real from-
## source production recipe to exercise the M9.H/I/K trio and the
## CLOSING recipe in the KF6 module-sweep batch (kconfig / ki18n /
## kwidgetsaddons / kxmlgui).
##
## kxmlgui is the TENTH CMake-driven recipe and the FIFTH KF6 foundation
## module after kcoreaddons + kconfig + ki18n + kwidgetsaddons.
##
## ## Why kxmlgui matters for the v1 desktop story
##
## kxmlgui (``libKF6XmlGui.so``) supplies the action / menu / toolbar
## management layer KF6 applications consume to wire user-facing
## ``KAction`` / ``KStandardAction`` / ``KActionCollection`` instances
## into ``QMenuBar`` / ``QToolBar`` / ``QStatusBar`` via XML-described
## UI declarations (``*ui.rc`` files). plasma-workspace's krunner /
## system-settings / kickoff-launcher all pull this in for their
## panel + window-frame UI plumbing.
##
## ## sha256 strategy
##
## We vendor the upstream 6.10.0 .tar.xz at
## ``recipes/packages/source/kxmlgui/vendor/kxmlgui-6.10.0.tar.xz`` and
## reference it via a ``file://`` URL.
##
## ## Version choice — 6.10.0 (current upstream stable in the 6.x line)
##
## Same lockstep ABI rationale as the sibling KF6 recipes.
##
## sha256 = 561fa755638da16cae204b670f62fab70156b9121b9313612238ca9c9e8e1292
##  (computed locally over the vendored ``kxmlgui-6.10.0.tar.xz``,
##  2,915,712 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## c_cpp_cmake convention (M9.K) — same as the sibling KF6 recipes.
##
## ## Library artifact
##
## kxmlgui's CMake build emits a single shared library
## (``libKF6XmlGui.so``) bundling the action/menu/toolbar XML-driven
## UI surface. We register the artifact under ``libKF6XmlGui``
## (camelCased from the upstream SONAME ``KF6XmlGui``).
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

package kxmlguiSource:
  ## From-source kxmlgui — thirty-ninth M9.H/I/K production recipe and
  ## the CLOSING recipe in the KF6 module-sweep batch. Tenth CMake-
  ## driven recipe and the FIFTH KF6 foundation module after
  ## kcoreaddons + kconfig + ki18n + kwidgetsaddons.
  ##
  ## Tier-2b c_cpp_cmake convention consumer. Single library artifact
  ## recipe.

  defaultToolProvisioning "path"

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.kde.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kxmlgui-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kxmlgui"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable.
    ##
    ## sha256 was computed over the vendored 2,915,712-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/kxmlgui/vendor/kxmlgui-6.10.0.tar.xz"
    sha256: "561fa755638da16cae204b670f62fab70156b9121b9313612238ca9c9e8e1292"
    extractStrip: 1

  uses:
    ## cmake is the build-system driver.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — kxmlgui is C++17.
    "gcc >=11"
    ## qt6-base supplies QtCore / QtGui / QtWidgets / QtXml / QtNetwork
    ## the kxmlgui surface consumes.
    "qt6-base >=6.6"
    ## qt6-tools supplies ``qhelpgenerator`` for QCH generation.
    "qt6-tools >=6.6"
    ## kconfig is the KF6 configuration-storage library kxmlgui uses
    ## to read ``*ui.rc`` files + persist menu/toolbar customisations
    ## under ``$XDG_CONFIG_HOME``. The sibling ``kconfigSource`` recipe
    ## vendors a compatible 6.x version.
    "kconfig >=6.0"
    ## kcoreaddons is the KF6 foundation library kxmlgui's actions
    ## consume for ``KAboutData`` / ``KShell`` / ``KSignalHandler``
    ## plumbing.
    "kcoreaddons >=6.0"
    ## ki18n is the translation/internationalisation layer kxmlgui
    ## uses to localise menu strings + toolbar tooltips.
    "ki18n >=6.0"
    ## kwidgetsaddons supplies the QtWidgets extensions
    ## (KMessageBox / KSeparator / KColorButton / ...) kxmlgui's
    ## action presenters wrap.
    "kwidgetsaddons >=6.0"

  cmakeFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: CMake evaluates ``-D`` overrides
    ## left-to-right.
    "-DBUILD_TESTING=OFF"
    "-DBUILD_QCH=OFF"
    "-DBUILD_PYTHON_BINDINGS=OFF"
    "-DCMAKE_BUILD_TYPE=Release"

  library libKF6XmlGui:
    ## ``libKF6XmlGui.so`` — action/menu/toolbar XML-driven UI surface
    ## (KAction + KStandardAction + KActionCollection + KMainWindow +
    ## KXmlGuiWindow + ``*ui.rc`` reader). v1 records the artifact
    ## only; the per-artifact build body lands in M9.L when the
    ## convention's ninja-spawn + install-glue closes.
    discard
