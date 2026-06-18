## Source-from-tarball kded recipe — the FIFTY-EIGHTH real from-source
## production recipe to exercise the M9.H/I/K trio and the CLOSING
## (FOURTH) recipe in the THIRD KF6 module-sweep batch (ksvg / ksolid
## / kio / kded).
##
## kded is the SIXTEENTH CMake-driven recipe and the TWELFTH KF6
## foundation module after kcoreaddons + kconfig + ki18n +
## kwidgetsaddons + kxmlgui + kservice + kglobalaccel + knotifications
## + ksvg + ksolid + kio.
##
## ## Why kded matters for the v1 desktop story
##
## kded (``libKF6Ded.so`` + ``kded6`` daemon binary) is the central
## KF6 module-host daemon every Plasma session spawns once: it loads
## ``.desktop`` modules from ``$XDG_DATA_DIRS/kded6/`` and keeps them
## alive across application launches. The MIME-bus / KIO sycoca
## refresher / device-notifier / ksysguard host / kded-modules
## (solidautoeject, networkmanagement, …) all live behind this
## binary; without it Plasma's autostart sequence stalls in the
## ``solidautoeject`` warm-up. The library ``libKF6Ded.so`` exposes
## the ``KDEDModule`` base class downstream modules subclass.
##
## ## Unique recipe shape — TWO artifacts (library + executable)
##
## kded is the FIRST KF6 module-sweep recipe to ship TWO artifacts
## (a library + an executable) from a single ``package`` macro. The
## sddm precedent (THREE artifacts: ``sddm`` + ``sddmGreeter`` +
## ``libSddmCommon``) and the gdm precedent (TWO executables:
## ``gdm`` + ``gdmFlexiserver``) cover the M9.K artifact registry's
## multi-artifact-per-package path. kded's unique angle is a SINGLE
## library + a SINGLE executable, complementing both precedents.
##
## ## sha256 strategy
##
## We vendor the upstream 6.10.0 .tar.xz at
## ``recipes/packages/source/kded/vendor/kded-6.10.0.tar.xz`` and
## reference it via a ``file://`` URL.
##
## ## Version choice — 6.10.0 (current upstream stable in the 6.x line)
##
## Same lockstep ABI rationale as the sibling KF6 recipes.
##
## sha256 = 5601d9dbfdc9507feaf17f4774bb7d12d38c7e19724ae8b987639a16ff0e6a8e
##  (computed locally over the vendored ``kded-6.10.0.tar.xz``,
##  34,976 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## c_cpp_cmake convention (M9.K) — same as the sibling KF6 recipes.
##
## ## Artifacts
##
##   * ``libKF6Ded`` — the ``KDEDModule`` base class library
##     downstream kded modules link against. Camel-cased from the
##     upstream SONAME ``KF6Ded``. (Internal SONAME may differ —
##     M9.L install glue resolves the on-disk shared-object filename.)
##   * ``kded6`` — the long-running module-host daemon binary. The
##     digit suffix mirrors the upstream binary name (``kded5`` for
##     KF5; ``kded6`` for KF6) and is preserved verbatim per the
##     gdm + sddm precedent of keeping the digit in the artifact
##     identifier when it carries ABI-line information.
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

package kdedSource:
  ## From-source kded — fifty-eighth M9.H/I/K production recipe and
  ## the CLOSING (FOURTH) recipe in the THIRD KF6 module-sweep batch
  ## (ksvg / ksolid / kio / kded). Sixteenth CMake-driven recipe and
  ## the TWELFTH KF6 foundation module. FIRST KF6-batch recipe to
  ## ship a library + executable pair from a single package.
  ##
  ## Tier-2b c_cpp_cmake convention consumer. Two artifacts (one
  ## library + one executable).

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.kde.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kded-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kded"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable.
    ##
    ## sha256 was computed over the vendored 34,976-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/kded/vendor/kded-6.10.0.tar.xz"
    sha256: "5601d9dbfdc9507feaf17f4774bb7d12d38c7e19724ae8b987639a16ff0e6a8e"
    extractStrip: 1

  uses:
    ## cmake is the build-system driver.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — kded is C++17.
    "gcc >=11"
    ## qt6-base supplies QtCore / QtDBus / QtNetwork the kded daemon
    ## consumes for the IPC service-bus + sycoca refresher loop.
    "qt6-base >=6.6"
    ## qt6-tools supplies ``qhelpgenerator`` for QCH generation.
    "qt6-tools >=6.6"
    ## kconfig is the KF6 configuration-storage library kded uses to
    ## persist per-module enable/disable settings under
    ## ``$XDG_CONFIG_HOME/kded6rc``.
    "kconfig >=6.0"
    ## kcoreaddons is the KF6 foundation library kded's
    ## ``KPluginFactory`` / ``KAboutData`` / ``KShell`` paths consume.
    "kcoreaddons >=6.0"
    ## kdbusaddons supplies the QtDBus session-bus single-instance
    ## guard kded uses to prevent double-spawn under autostart.
    "kdbusaddons >=6.0"
    ## ki18n is the translation/internationalisation layer kded uses
    ## to localise startup diagnostics + module-failure popups.
    "ki18n >=6.0"
    ## kservice supplies the sycoca cache kded refreshes on demand +
    ## the ``KService::Ptr`` handle the module-loader resolves
    ## ``.desktop`` IDs through.
    "kservice >=6.0"
    ## kcrash supplies the SIGSEGV/SIGABRT handler kded installs at
    ## startup so a faulting kded module produces a usable backtrace.
    "kcrash >=6.0"

  cmakeFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: CMake evaluates ``-D`` overrides
    ## left-to-right.
    "-DBUILD_TESTING=OFF"
    "-DBUILD_QCH=OFF"
    "-DBUILD_PYTHON_BINDINGS=OFF"
    "-DCMAKE_BUILD_TYPE=Release"

  library libKF6Ded:
    ## ``libKF6Ded.so`` — ``KDEDModule`` base class library downstream
    ## kded modules (solidautoeject, networkmanagement, kfilemetadata,
    ## ksysguard, …) link against. Camel-cased from the upstream
    ## SONAME ``KF6Ded``. v1 records the artifact only; the per-
    ## artifact build body lands in M9.L when the convention's
    ## ninja-spawn + install-glue closes.
    discard

  executable kded6:
    ## ``/usr/bin/kded6`` — the long-running KF6 module-host daemon
    ## the Plasma session spawns at autostart-phase 1. Loads every
    ## ``.desktop`` module under ``$XDG_DATA_DIRS/kded6/`` whose
    ## ``X-KDE-Kded-autoload`` field evaluates true and keeps them
    ## alive until session logout. The digit suffix (``6``) mirrors
    ## the upstream binary name and is preserved verbatim per the
    ## gdm / sddm precedent of retaining ABI-line digits in the
    ## artifact identifier. v1 records the artifact only; the per-
    ## artifact build body lands in M9.L when the convention's
    ## ninja-spawn + install-glue closes.
    discard
