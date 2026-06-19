## Source-from-tarball kglobalaccel recipe — the FORTY-FOURTH real from-
## source production recipe to exercise the M9.H/I/K trio and the
## SECOND recipe in the SECOND KF6 module-sweep batch (kservice /
## kglobalaccel / knotifications / plasma-framework).
##
## kglobalaccel is the TWELFTH CMake-driven recipe and the SEVENTH KF6
## foundation module after kcoreaddons + kconfig + ki18n +
## kwidgetsaddons + kxmlgui + kservice. It is the KF6 global-shortcut
## broker every KF6 application + Plasma component uses to register
## desktop-wide keyboard accelerators that survive focus changes
## (``KGlobalAccel::self()->setShortcut(...)``); the runtime side talks
## to ``kglobalacceld`` over D-Bus and stores per-user binding state
## under ``$XDG_DATA_HOME/kglobalaccel/``.
##
## ## Why kglobalaccel matters for the v1 desktop story
##
## kglobalaccel (``libKF6GlobalAccel.so``) supplies the global-shortcut
## registration + dispatch surface that plasma-workspace's khotkeys /
## kded / plasma-shell consume to bind Meta / Ctrl-Alt / hardware
## media keys to actions across all running applications. Without it
## the v1 Plasma session has no Meta-key launcher trigger and no media-
## key dispatch into mpris targets.
##
## ## sha256 strategy
##
## We vendor the upstream 6.10.0 .tar.xz at
## ``recipes/packages/source/kglobalaccel/vendor/kglobalaccel-6.10.0.tar.xz``
## and reference it via a ``file://`` URL.
##
## ## Version choice — 6.10.0 (current upstream stable in the 6.x line)
##
## Same lockstep ABI rationale as the sibling KF6 recipes.
##
## sha256 = 05b0ec6a44d43ce7a9cfd6cd70c8d07dca5c5f6216968af8128fe9a5ed9b1928
##  (computed locally over the vendored ``kglobalaccel-6.10.0.tar.xz``,
##  2,294,700 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## c_cpp_cmake convention (M9.K) — same as the sibling KF6 recipes.
##
## ## Library artifact
##
## kglobalaccel's CMake build emits a single shared library
## (``libKF6GlobalAccel.so``) bundling the global-shortcut surface.
## We register the artifact under ``libKF6GlobalAccel`` (camelCased
## from the upstream SONAME ``KF6GlobalAccel``).
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

package kglobalaccelSource:
  ## From-source kglobalaccel — forty-fourth M9.H/I/K production recipe
  ## and the SECOND recipe in the SECOND KF6 module-sweep batch.
  ## Twelfth CMake-driven recipe and the SEVENTH KF6 foundation module
  ## after kcoreaddons + kconfig + ki18n + kwidgetsaddons + kxmlgui +
  ## kservice.
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
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kglobalaccel-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kglobalaccel"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable.
    ##
    ## sha256 was computed over the vendored 2,294,700-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/kglobalaccel/vendor/kglobalaccel-6.10.0.tar.xz"
    sha256: "05b0ec6a44d43ce7a9cfd6cd70c8d07dca5c5f6216968af8128fe9a5ed9b1928"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — kglobalaccel is C++17.
    "gcc >=11"

  buildDeps:
    ## qt6-base supplies QtCore / QtDBus / QtGui the kglobalaccel
    ## client + daemon proxy classes consume.
    "qt6-base >=6.6"
    ## qt6-tools supplies ``qhelpgenerator`` for QCH generation.
    "qt6-tools >=6.6"
    ## kconfig is the KF6 configuration-storage library kglobalaccel
    ## uses to read/write per-component shortcut bindings.
    "kconfig >=6.0"
    ## kcoreaddons is the KF6 foundation library kglobalaccel's
    ## ``KAboutData`` / ``KShortcut`` plumbing consumes.
    "kcoreaddons >=6.0"

  cmakeFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: CMake evaluates ``-D`` overrides
    ## left-to-right.
    "-DBUILD_TESTING=OFF"
    "-DBUILD_QCH=OFF"
    "-DBUILD_PYTHON_BINDINGS=OFF"
    "-DCMAKE_BUILD_TYPE=Release"

  library libKF6GlobalAccel:
    ## ``libKF6GlobalAccel.so`` — global-shortcut registration +
    ## dispatch surface (KGlobalAccel + KGlobalShortcutInfo +
    ## KGlobalAccelComponent + kglobalacceld D-Bus proxy). v1 records
    ## the artifact only; the per-artifact build body lands in M9.L
    ## when the convention's ninja-spawn + install-glue closes.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
