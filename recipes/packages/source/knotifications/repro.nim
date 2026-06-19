## Source-from-tarball knotifications recipe — the FORTY-FIFTH real from-
## source production recipe to exercise the M9.H/I/K trio and the
## THIRD recipe in the SECOND KF6 module-sweep batch (kservice /
## kglobalaccel / knotifications / plasma-framework).
##
## knotifications is the THIRTEENTH CMake-driven recipe and the EIGHTH
## KF6 foundation module after kcoreaddons + kconfig + ki18n +
## kwidgetsaddons + kxmlgui + kservice + kglobalaccel. It is the KF6
## desktop-notification dispatch layer that every KF6 application uses
## to surface popup notifications, sounds, and ``KNotificationAction``
## buttons through the freedesktop ``org.freedesktop.Notifications``
## D-Bus service (plasma-workspace's notification daemon) or fallback
## delivery channels (taskbar flash, sound bell).
##
## ## Why knotifications matters for the v1 desktop story
##
## knotifications (``libKF6Notifications.so``) supplies the
## ``KNotification`` API every KF6 application + Plasma component
## consumes to surface user-facing events (download finished, battery
## low, KMail new-message, KDEConnect device-paired, ...). plasma-
## workspace's plasma-shell notification applet + the org.kde.plasma.
## notifications service receive the dispatched notifications and
## render them in the panel.
##
## ## sha256 strategy
##
## We vendor the upstream 6.10.0 .tar.xz at
## ``recipes/packages/source/knotifications/vendor/knotifications-6.10.0.tar.xz``
## and reference it via a ``file://`` URL.
##
## ## Version choice — 6.10.0 (current upstream stable in the 6.x line)
##
## Same lockstep ABI rationale as the sibling KF6 recipes.
##
## sha256 = 36b7881d50400f37b4f3aeaa4c0a6a943e5783d35441e2b0cacdc6dad06af2a1
##  (computed locally over the vendored ``knotifications-6.10.0.tar.xz``,
##  2,335,588 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## c_cpp_cmake convention (M9.K) — same as the sibling KF6 recipes.
##
## ## Library artifact
##
## knotifications's CMake build emits a single shared library
## (``libKF6Notifications.so``) bundling the notification dispatch
## surface. We register the artifact under ``libKF6Notifications``
## (camelCased from the upstream SONAME ``KF6Notifications``).
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

package knotificationsSource:
  ## From-source knotifications — forty-fifth M9.H/I/K production
  ## recipe and the THIRD recipe in the SECOND KF6 module-sweep batch.
  ## Thirteenth CMake-driven recipe and the EIGHTH KF6 foundation
  ## module after kcoreaddons + kconfig + ki18n + kwidgetsaddons +
  ## kxmlgui + kservice + kglobalaccel.
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
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/knotifications-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/knotifications"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable.
    ##
    ## sha256 was computed over the vendored 2,335,588-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/knotifications/vendor/knotifications-6.10.0.tar.xz"
    sha256: "36b7881d50400f37b4f3aeaa4c0a6a943e5783d35441e2b0cacdc6dad06af2a1"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — knotifications is C++17.
    "gcc >=11"

  buildDeps:
    ## qt6-base supplies QtCore / QtDBus / QtGui / QtNetwork +
    ## QtMultimedia the knotifications surface consumes (action
    ## buttons, sound playback, popup widgets, fallback channels).
    "qt6-base >=6.6"
    ## qt6-tools supplies ``qhelpgenerator`` for QCH generation.
    "qt6-tools >=6.6"
    ## kconfig is the KF6 configuration-storage library knotifications
    ## uses to read per-application ``*.notifyrc`` files + persist
    ## user-overridden notification preferences.
    "kconfig >=6.0"
    ## kcoreaddons is the KF6 foundation library knotifications's
    ## ``KAboutData`` / ``KShell`` plumbing consumes.
    "kcoreaddons >=6.0"

  cmakeFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: CMake evaluates ``-D`` overrides
    ## left-to-right.
    "-DBUILD_TESTING=OFF"
    "-DBUILD_QCH=OFF"
    "-DBUILD_PYTHON_BINDINGS=OFF"
    "-DCMAKE_BUILD_TYPE=Release"

  library libKF6Notifications:
    ## ``libKF6Notifications.so`` — notification dispatch surface
    ## (KNotification + KNotificationAction + KNotificationPermission +
    ## freedesktop ``org.freedesktop.Notifications`` D-Bus proxy). v1
    ## records the artifact only; the per-artifact build body lands in
    ## M9.L when the convention's ninja-spawn + install-glue closes.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
