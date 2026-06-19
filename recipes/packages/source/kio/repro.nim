## Source-from-tarball kio recipe — the FIFTY-SEVENTH real from-source
## production recipe to exercise the M9.H/I/K trio and the THIRD
## recipe in the THIRD KF6 module-sweep batch (ksvg / ksolid / kio /
## kded).
##
## kio is the FIFTEENTH CMake-driven recipe and the ELEVENTH KF6
## foundation module after kcoreaddons + kconfig + ki18n +
## kwidgetsaddons + kxmlgui + kservice + kglobalaccel + knotifications
## + ksvg + ksolid.
##
## ## Why kio matters for the v1 desktop story
##
## kio (``libKF6Kio.so``) supplies the KIO transparent-network-IO layer
## every KF6 application (Dolphin, KMail, Okular, KDevelop, …)
## consumes for cross-protocol URL access (``smb://``, ``sftp://``,
## ``http(s)://``, ``trash:/``, ``recently:/``, ``man:/``). It is the
## LARGEST KF6 framework by source-size and pulls in the widest
## dependency set: kbookmarks + kcompletion + kconfigwidgets + kjobwidgets
## + kservice + ksolid + kwallet + kwidgetsaddons + kwindowsystem +
## ki18n + kcrash + kdbusaddons + kdoctools + kguiaddons + kiconthemes
## + kitemviews. plasma-workspace's kded MIME-bus + Dolphin's whole
## file-manager surface + Plasma's open-with-dialog all link against
## it.
##
## ## sha256 strategy
##
## We vendor the upstream 6.10.0 .tar.xz at
## ``recipes/packages/source/kio/vendor/kio-6.10.0.tar.xz`` and
## reference it via a ``file://`` URL.
##
## ## Version choice — 6.10.0 (current upstream stable in the 6.x line)
##
## Same lockstep ABI rationale as the sibling KF6 recipes.
##
## sha256 = 7eb454438f149e7ed513c3bbd526b67e3e3ecfe32ae7c986168baa59600b699c
##  (computed locally over the vendored ``kio-6.10.0.tar.xz``,
##  3,423,932 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
##
## ## Build shape
##
## c_cpp_cmake convention (M9.K) — same as the sibling KF6 recipes.
##
## ## Library artifact
##
## kio's CMake build emits a single shared library
## (``libKF6Kio.so``) bundling the KIO transparent-network-IO surface.
## We register the artifact under ``libKF6Kio`` (camelCased from the
## upstream SONAME ``KF6KIO``) — the ``KIO`` acronym is reduced to
## ``Kio`` to match the kxmlgui / libKF6XmlGui precedent of brand-
## conventional casing in artifact identifiers (``Xml``, ``Kio``,
## ``Svg``, ``Service`` — never ``XML``, ``KIO``, ``SVG``, ``SERVICE``).
##
## ## Configurables
##
## v1 ships NO configurables — same modern-desktop baseline as the
## sibling KF6 recipes (``BUILD_TESTING=OFF`` + ``BUILD_QCH=OFF`` +
## ``BUILD_PYTHON_BINDINGS=OFF`` + ``CMAKE_BUILD_TYPE=Release``).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package kioSource:
  ## From-source kio — fifty-seventh M9.H/I/K production recipe and
  ## the THIRD recipe in the THIRD KF6 module-sweep batch (ksvg /
  ## ksolid / kio / kded). Fifteenth CMake-driven recipe and the
  ## ELEVENTH KF6 foundation module.
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
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kio-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kio"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable.
    ##
    ## sha256 was computed over the vendored 3,423,932-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/kio/vendor/kio-6.10.0.tar.xz"
    sha256: "7eb454438f149e7ed513c3bbd526b67e3e3ecfe32ae7c986168baa59600b699c"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — kio is C++17.
    "gcc >=11"

  buildDeps:
    ## qt6-base supplies QtCore / QtDBus / QtGui / QtNetwork / QtWidgets
    ## / QtXml the kio surface consumes for protocol slaves +
    ## file-dialog UI.
    "qt6-base >=6.6"
    ## qt6-tools supplies ``qhelpgenerator`` for QCH generation.
    "qt6-tools >=6.6"
    ## kconfig is the KF6 configuration-storage library kio uses to
    ## persist per-protocol settings + bookmark catalogues.
    "kconfig >=6.0"
    ## kcoreaddons is the KF6 foundation library kio's KJob +
    ## KPluginFactory + KShell paths consume.
    "kcoreaddons >=6.0"
    ## ki18n is the translation/internationalisation layer kio uses
    ## to localise protocol-error messages + file-dialog prompts.
    "ki18n >=6.0"
    ## kservice is the desktop-entry / sycoca cache kio uses for
    ## open-with-dialog application discovery (kioSource's reason for
    ## linking against the sibling ``kserviceSource`` recipe's
    ## library artifact).
    "kservice >=6.0"
    ## ksolid supplies the hardware-abstraction layer kio's
    ## ``trash:/`` + removable-storage codepaths consume.
    "ksolid >=6.0"
    ## kwidgetsaddons supplies the QtWidgets extensions kio's
    ## file-dialog + open-with-dialog wrap.
    "kwidgetsaddons >=6.0"
    ## kwindowsystem supplies X11 / Wayland window-manager hints kio's
    ## file-dialog uses for parent-window transient association.
    "kwindowsystem >=6.0"
    ## kcompletion supplies the line-edit history backing the file-
    ## dialog's path-completion popup.
    "kcompletion >=6.0"
    ## kjobwidgets supplies the QtWidgets KJob progress-dialog surface
    ## kio's transfer-jobs report through.
    "kjobwidgets >=6.0"
    ## kbookmarks supplies the XBEL-format bookmark catalogue kio's
    ## file-dialog sidebar reads.
    "kbookmarks >=6.0"
    ## kcrash supplies the SIGSEGV/SIGABRT handler kio's slave
    ## processes install at startup.
    "kcrash >=6.0"
    ## kdbusaddons supplies the QtDBus extensions kio uses for slave-
    ## process lifecycle management.
    "kdbusaddons >=6.0"
    ## kiconthemes supplies the icon-resolution layer kio's file-
    ## dialog + open-with-dialog consume for MIME-type icons.
    "kiconthemes >=6.0"
    ## kitemviews supplies the QtWidgets model/view extensions kio's
    ## file-dialog list / icon / tree views consume.
    "kitemviews >=6.0"

  config:
    ## No prefix lifted from `cmakeFlags:`; flags inlined in the `build:` block.
    discard
  library libKF6Kio:
    ## ``libKF6Kio.so`` — KIO transparent-network-IO surface (KIO::Job
    ## + KIO::CopyJob + KIO::FileCopyJob + KIO::TransferJob + KFileItem
    ## + KFileWidget + KDirOperator + KUrlNavigator + the ``smb://`` /
    ## ``sftp://`` / ``trash:/`` / ``recently:/`` / ``man:/`` slave
    ## dispatch table). v1 records the artifact only; the per-
    ## artifact build body lands in M9.L when the convention's
    ## ninja-spawn + install-glue closes.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `cmake_package(...)` constructor.
    setCurrentOwningPackageOverride("kioSource")
    try:
      let opts = @[
        "-DBUILD_TESTING=OFF",
        "-DBUILD_QCH=OFF",
        "-DBUILD_PYTHON_BINDINGS=OFF",
        "-DCMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6Kio")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
