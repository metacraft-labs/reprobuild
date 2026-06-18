## Source-from-tarball kwin recipe — the TWENTIETH real from-source
## production recipe to exercise the M9.H/I/K trio and the SECOND
## recipe in the Plasma stack batch (kcoreaddons / kwin /
## plasma-workspace / sddm).
##
## Prior nineteen from-source recipes — fourteen meson (dbus-broker,
## libdrm, wayland, wlroots, sway, libxkbcommon, pixman, libinput,
## cairo, pango, gdk-pixbuf, glib2, mutter, gnome-shell), one make
## (linux-kernel), two CMake (json-c, kcoreaddons), two autotools
## (expat, gdm) — collectively covered every M9.I flag-injection
## channel and every artifact-kind permutation. kwin is the THIRD
## CMake-driven recipe and the FIRST KWin compositor in the recipe
## suite. The unique coverage angle for this recipe is that it's the
## FIRST CMake recipe to ship BOTH a library AND an executable from
## the same ``package`` macro (json-c shipped a library, kcoreaddons
## shipped a library; this is the first CMake mixed-kind recipe). The
## mutter/gnome-shell precedents are meson; this is the CMake-side
## analogue, exercising the M3 artifact registry's mixed-kind
## partitioning from the opposite build-system channel.
##
## ## Why kwin matters for the v1 desktop story
##
## kwin is the KDE Plasma Wayland compositor — the analogue of mutter
## for the GNOME story. The standalone ``kwin_wayland`` binary is the
## display-server process the user-session leader spawns to host
## Wayland clients (the Plasma shell, all native + XWayland-bridged X11
## clients). ``libkwin.so`` is the compositor library plasma-workspace
## (NDE-K1's session leader) links against to register window-
## management hooks + effect plugins. NDE-K1's manifest layer pins the
## apt-jammy kwin .deb for v1 stubs; this from-source recipe lifts that
## pin to a real ``kwin_wayland`` binary + ``libkwin.so`` library
## artifact for the v2 Plasma story.
##
## ## sha256 strategy
##
## We vendor the upstream 6.2.5 .tar.xz at
## ``recipes/packages/source/kwin/vendor/kwin-6.2.5.tar.xz`` and
## reference it via a ``file://`` URL. The download.kde.org release URL
## is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 6.2.5 (current upstream stable in the 6.2.x line)
##
## download.kde.org publishes KDE Plasma releases at
## ``https://download.kde.org/stable/plasma/<x.y.z>/`` and 6.2.5 is the
## current stable in the 6.2.x line as of mid-2026. The Plasma 6.2.x
## series consumes the KF6 6.x frameworks ABI line that ``kcoreaddons``
## 6.10.0 sits in, so the four Plasma-batch recipes stay in lockstep.
##
## sha256 = 5cc450a6e41105c8c49929b72550b331237f96aafb294690f4707bdc5f776848
##  (computed locally over the vendored ``kwin-6.2.5.tar.xz``, 8,563,352
##  bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
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
##   3. a ``ninja`` (or ``cmake --build``) compile BuildAction (M9.L).
##   4. install/output collection actions for the library + executable
##      artifacts (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ninja-spawn + install glue lands in M9.L; the recipe
## records the artifacts via one ``library`` block + one
## ``executable`` block so the M9.K artifact registry already knows
## what shared object + binary to expect.
##
## ## Artifacts
##
## kwin's CMake build emits one shared library + one standalone binary:
##
##   * ``libkwin.so`` — the compositor library plasma-workspace links
##                       against to register window-management hooks +
##                       effect plugins (third-party kwin effects also
##                       link against this for their UI plugin
##                       contracts).
##   * ``kwin_wayland`` — the standalone Wayland compositor binary that
##                         hosts the Wayland display server + spawns
##                         the user session. NDE-K1's
##                         ``plasma.desktop`` Wayland session entry
##                         ``Exec``s ``startplasma-wayland`` which
##                         chain-execs into ``kwin_wayland`` for the
##                         Wayland-side, but the binary itself is
##                         exposed as ``kwin_wayland``.
##
## We register the library under the package-level identifier
## ``libKWin`` (camelCased from the upstream SONAME ``kwin`` per the
## json-c precedent — preserving the leading lib + the uppercase
## ``KWin`` brand-casing, the same shape as ``libKF6CoreAddons``), and
## the executable under ``kwinWayland`` (camelCased from the upstream
## binary name ``kwin_wayland`` per the same convention).
##
## ## Configurables
##
## v1 ships NO configurables — the CMake options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``BUILD_TESTING=OFF``     — skip the upstream test suite to keep
##                                  the build hermetic + fast.
##   * ``KWIN_BUILD_TABBOX=OFF`` — skip the legacy task-switcher tab-box
##                                  UI (modern Plasma uses the
##                                  KWin-scripted task switcher
##                                  instead).
##   * ``KWIN_BUILD_X11=OFF``    — skip the X11/XWayland session
##                                  support (the v1 Plasma story is
##                                  pure-Wayland; the NDE-K1 spec
##                                  pins only ``plasma.desktop``,
##                                  not ``plasmax11.desktop``).
##   * ``KWIN_BUILD_KCMS=OFF``   — skip the System Settings ``kcm``
##                                  modules (the v1 minimal Plasma
##                                  variant ships no Settings GUI;
##                                  user-config is driven by NDE-K1's
##                                  ``configFile`` emissions
##                                  directly).
##   * ``CMAKE_BUILD_TYPE=Release`` — release-mode optimisation;
##                                  matches the sibling from-source
##                                  recipes' ``--buildtype=release``
##                                  meson option.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. an X11-supporting variant
## that flips ``KWIN_BUILD_X11=ON`` for legacy bundles).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package kwinSource:
  ## From-source kwin — twentieth M9.H/I/K production recipe and the
  ## SECOND recipe in the Plasma stack batch. Third CMake-driven
  ## recipe after json-c + kcoreaddons and the FIRST CMake recipe to
  ## ship a library + an executable from the same ``package`` macro
  ## (the mutter/gnome-shell precedents are meson; this is the
  ## CMake-side analogue).
  ##
  ## Tier-2b c_cpp_cmake convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``cmakeFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"cmake"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags. Library + executable artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.kde.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream KDE invent.kde.org
    ## project --- kwin's canonical home.
    "6.2.5":
      sourceRevision = "v6.2.5"
      sourceUrl = "https://download.kde.org/stable/plasma/6.2.5/kwin-6.2.5.tar.xz"
      sourceRepository = "https://invent.kde.org/plasma/kwin"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 8,563,352-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/kwin/vendor/kwin-6.2.5.tar.xz"
    sha256: "5cc450a6e41105c8c49929b72550b331237f96aafb294690f4707bdc5f776848"
    extractStrip: 1

  uses:
    ## cmake is the build-system driver — the c_cpp_cmake convention's
    ## configure action invokes ``cmake -S <src> -B <build>``.
    ## kwin 6.x requires cmake 3.16 for the modern ECM + Qt6
    ## ``find_package`` semantics the Plasma 6.x ABI line depends on.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux — the compile action
    ## invokes ``ninja`` (or ``cmake --build``) against the CMake build
    ## directory.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — kwin is C++20.
    "gcc >=11"
    ## kcoreaddons is the KF6 foundation library kwin links against
    ## for KJob / KAboutData / KPluginFactory plumbing. The sibling
    ## ``kcoreaddonsSource`` recipe vendors 6.10.0 to match the KF6
    ## 6.x ABI requirement.
    "kcoreaddons >=6.0"
    ## kf6-base is the umbrella KF6 frameworks package (kconfig,
    ## ki18n, kwidgetsaddons, kcompletion, kxmlgui, kservice,
    ## knotifications, etc.) kwin's compositor + window-management
    ## logic consumes.
    "kf6-base >=6.0"
    ## wayland supplies the protocol scanner + libwayland-server kwin
    ## uses for its Wayland compositor implementation. The sibling
    ## ``waylandSource`` recipe vendors a compatible version.
    "wayland >=1.20"
    ## qt6-base supplies QtCore / QtGui / QtQml / QtQuick which the
    ## modern kwin compositor (incl. the QML-based effect runtime)
    ## consumes. 6.6 is the minimum the Plasma 6.2.x line targets.
    "qt6-base >=6.6"
    ## libdrm is the kernel DRM client library kwin's DRM backend uses
    ## to drive direct-rendering on tty consoles. The sibling
    ## ``libdrmSource`` recipe vendors a compatible version.
    "libdrm >=2.4"
    ## libinput is the input-event library kwin uses to handle
    ## evdev / libinput-mediated keyboard / mouse / touchpad / tablet
    ## events on the Wayland session.
    "libinput >=1.20"
    ## libxkbcommon is the keyboard-keymap library kwin uses to handle
    ## layout switching / hotkey binding / compose-key sequences.
    "libxkbcommon >=1.5"
    ## pixman is the software 2D rendering backend kwin's
    ## compositor uses for fallback paths.
    "pixman >=0.40"

  cmakeFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: CMake evaluates ``-D`` overrides
    ## left-to-right and the ``CMAKE_BUILD_TYPE=Release`` sentinel
    ## lives at the tail so any override (e.g. a future debug-build
    ## variant) can append ``-DCMAKE_BUILD_TYPE=Debug`` later without
    ## re-ordering this block.
    ##
    ## ``BUILD_TESTING=OFF`` skips the upstream test suite.
    ## ``KWIN_BUILD_TABBOX=OFF`` skips the legacy task-switcher tab-box.
    ## ``KWIN_BUILD_X11=OFF`` skips X11/XWayland session support
    ## (v1 Plasma is pure-Wayland).
    ## ``KWIN_BUILD_KCMS=OFF`` skips the System Settings ``kcm`` modules
    ## (v1 minimal Plasma ships no Settings GUI).
    "-DBUILD_TESTING=OFF"
    "-DKWIN_BUILD_TABBOX=OFF"
    "-DKWIN_BUILD_X11=OFF"
    "-DKWIN_BUILD_KCMS=OFF"
    "-DCMAKE_BUILD_TYPE=Release"

  executable kwinWayland:
    ## ``/usr/bin/kwin_wayland`` — the standalone Wayland compositor
    ## binary kwin ships. Hosts the Wayland display server + runs the
    ## user-session compositor for Plasma sessions. NDE-K1's
    ## ``plasma.desktop`` Wayland session entry chain-execs into this
    ## via ``startplasma-wayland``. v1 records the artifact only; the
    ## per-artifact build body lands in M9.L when the convention's
    ## ninja-spawn + install-glue closes.
    discard

  library libKWin:
    ## ``libkwin.so`` — the compositor library plasma-workspace links
    ## against to register window-management hooks + effect plugins.
    ## Third-party kwin effects also link against this for their UI
    ## plugin contracts. v1 records the artifact only.
    discard
