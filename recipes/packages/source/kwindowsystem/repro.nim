## Source-from-tarball kwindowsystem recipe — M9.R.15h.9 KF6 cascade
## module. kwindowsystem is Tier-1 KDE Frameworks: WM-level helpers
## (KWindowInfo, KX11Extras, KWindowSystem::activeWindow); the
## abstraction over X11 / Wayland window-management every Plasma
## component depends on.
##
## sha256 = 046b7aa2247811323e48b629884b824a6ffec475df2316256e7ff0b9df677944
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  kwindowsystem-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kwindowsystemSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kwindowsystem-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kwindowsystem"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kwindowsystem-6.10.0.tar.xz"
    sha256: "046b7aa2247811323e48b629884b824a6ffec475df2316256e7ff0b9df677944"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"
    "wayland-scanner >=1.22"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "wayland >=1.22"
    ## M9.R.15o.4 — qt6-declarative supplies Qt6Qml which kwindowsystem
    ## uses for its QML compatibility surface (KWindowSystem.qml).
    "qt6-declarative >=6.6"
    ## M9.R.15p.1.5 — qt6-wayland supplies Qt6WaylandClient which
    ## kwindowsystem's ``find_package(Qt6WaylandClient REQUIRED)`` resolves
    ## against when ``KWINDOWSYSTEM_WAYLAND=ON`` (the default for v1's
    ## Wayland-only desktop story).
    "qt6-wayland >=6.6"
    ## M9.R.15p.1.5 — wayland-protocols supplies the upstream Wayland
    ## protocol XML descriptions kwindowsystem's wayland backend
    ## consumes through wayland-scanner. ``find_package(WaylandProtocols
    ## 1.21 REQUIRED)``.
    "wayland-protocols >=1.21"
    ## M9.R.15p.1.5 — plasma-wayland-protocols supplies the
    ## Plasma-specific Wayland protocol XML descriptions (org_kde_kwin_*,
    ## org_kde_plasma_*) kwindowsystem's wayland backend uses for
    ## KDE-specific window-manager hints. ``find_package(
    ## PlasmaWaylandProtocols REQUIRED)``.
    "plasma-wayland-protocols >=1.10"
    ## M9.R.15p.0.2 — libxkbcommon + mesa are auto-injected by the
    ## package macro for every qt6-* consumer (see
    ## ``m9r15pAutoInjectQt6Transitive``); the explicit per-recipe
    ## declarations M9.R.15o.4 added are retired.
    ## M9.R.15q.4.2 — X11 backend re-enabled (KWINDOWSYSTEM_X11=ON
    ## restored below) so KX11Extras ships for plasma-framework's
    ## unconditional include. Each X11 client lib resolves through
    ## the M9.R.15q.4.1 stdlib stubs (^*-multi-output nix channels).
    "libx11"
    "libxcb"
    "xcb-util-keysyms"
    "libxext"
    "libxfixes"
    "libxrender"

  config:
    discard

  library libKF6WindowSystem:
    discard

  build:
    setCurrentOwningPackageOverride("kwindowsystemSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
        # M9.R.15q.4.2: KWINDOWSYSTEM_X11=ON — re-enable the X11
        # backend so ``KX11Extras`` ships, unblocking plasma-framework's
        # unconditional ``#include <KX11Extras>`` (which the
        # WITHOUT_X11 toggle does NOT suppress; only the optional X11
        # link surface is gated by that). The X11 client libs
        # (libX11 + libxcb + xcb-util-keysyms + libXfixes + libXrender +
        # libXext) come via the M9.R.15q.4.1 stdlib stubs registered in
        # buildDeps above.
        "KWINDOWSYSTEM_X11=ON",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6WindowSystem")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
