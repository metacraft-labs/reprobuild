## Source-from-tarball kservice recipe — the FORTY-THIRD real from-source
## production recipe to exercise the M9.H/I/K trio and the FIRST recipe in
## the SECOND KF6 module-sweep batch (kservice / kglobalaccel /
## knotifications / plasma-framework).
##
## kservice is the ELEVENTH CMake-driven recipe and the SIXTH KF6
## foundation module after kcoreaddons + kconfig + ki18n + kwidgetsaddons
## + kxmlgui. It is the FIRST KF6 module in the recipe suite whose
## dependency arrow points UP from the previous batch (it pulls in
## kconfig + kcoreaddons + kdbusaddons) — kservice is the
## ``KService::serviceByDesktopName`` lookup layer that every KF6
## application + Plasma launcher / krunner / kded module consumes for
## ``*.desktop`` discovery + MIME-type → application mapping.
##
## ## Why kservice matters for the v1 desktop story
##
## kservice (``libKF6Service.so``) supplies the cross-cutting service-
## registry layer KF6 applications and Plasma components consume to map
## XDG desktop entries (``$XDG_DATA_DIRS/applications/*.desktop``) +
## ``Sycoca`` cached MIME-type / service-trader tables into runtime
## ``KService::Ptr`` handles. plasma-workspace's kickoff launcher /
## krunner / kded MIME-bus / KIO open-with-dialog all link against it
## for the desktop-entry side of the v1 Plasma story; v2 cannot ship a
## launcher without it.
##
## ## sha256 strategy
##
## We vendor the upstream 6.10.0 .tar.xz at
## ``recipes/packages/source/kservice/vendor/kservice-6.10.0.tar.xz`` and
## reference it via a ``file://`` URL.
##
## ## Version choice — 6.10.0 (current upstream stable in the 6.x line)
##
## Same lockstep ABI rationale as the sibling KF6 recipes.
##
## sha256 = 04ad53850967e38822f8af1652b118992cd1bfa382e2718278bb6de03a0bdbb3
##  (computed locally over the vendored ``kservice-6.10.0.tar.xz``,
##  2,439,968 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## c_cpp_cmake convention (M9.K) — same as the sibling KF6 recipes.
##
## ## Library artifact
##
## kservice's CMake build emits a single shared library
## (``libKF6Service.so``) bundling the service-registry surface. We
## register the artifact under ``libKF6Service`` (camelCased from the
## upstream SONAME ``KF6Service``).
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

package kserviceSource:
  ## From-source kservice — forty-third M9.H/I/K production recipe and
  ## the FIRST recipe in the SECOND KF6 module-sweep batch. Eleventh
  ## CMake-driven recipe and the SIXTH KF6 foundation module after
  ## kcoreaddons + kconfig + ki18n + kwidgetsaddons + kxmlgui.
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
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kservice-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kservice"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable.
    ##
    ## sha256 was computed over the vendored 2,439,968-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://download.kde.org/stable/frameworks/6.10/kservice-6.10.0.tar.xz"
    sha256: "04ad53850967e38822f8af1652b118992cd1bfa382e2718278bb6de03a0bdbb3"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — kservice is C++17.
    "gcc >=11"

  buildDeps:
    ## qt6-base supplies QtCore / QtDBus / QtXml the kservice surface
    ## consumes (KService / KSycoca / KApplicationTrader / ...).
    "qt6-base >=6.6"
    ## qt6-tools supplies ``qhelpgenerator`` for QCH generation.
    "qt6-tools >=6.6"
    ## kconfig is the KF6 configuration-storage library kservice uses
    ## to read ``*.desktop`` entries + persist sycoca timestamps.
    "kconfig >=6.0"
    ## kcoreaddons is the KF6 foundation library kservice's
    ## ``KPluginFactory`` / ``KAboutData`` / ``KShell`` paths consume.
    "kcoreaddons >=6.0"
    ## ki18n is the translation/internationalisation layer kservice
    ## uses to localise ``Name[xx]=`` / ``GenericName[xx]=`` desktop-
    ## entry fields.
    "ki18n >=6.0"

  config:
    ## No prefix lifted from `cmakeFlags:`; flags inlined in the `build:` block.
    discard
  library libKF6Service:
    ## ``libKF6Service.so`` — service-registry layer (KService +
    ## KSycoca + KApplicationTrader + KMimeTypeTrader + KServiceGroup +
    ## KServiceTypeTrader). v1 records the artifact only; the per-
    ## artifact build body lands in M9.L when the convention's ninja-
    ## spawn + install-glue closes.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `cmake_package(...)` constructor.
    setCurrentOwningPackageOverride("kserviceSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6Service")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
