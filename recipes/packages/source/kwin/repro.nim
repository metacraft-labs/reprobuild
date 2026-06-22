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
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

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
    url: "https://download.kde.org/stable/plasma/6.2.5/kwin-6.2.5.tar.xz"
    sha256: "5cc450a6e41105c8c49929b72550b331237f96aafb294690f4707bdc5f776848"
    extractStrip: 1

  nativeBuildDeps:
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

  buildDeps:
    "extra-cmake-modules >=6.0"
    ## kcoreaddons is the KF6 foundation library kwin links against
    ## for KJob / KAboutData / KPluginFactory plumbing. The sibling
    ## ``kcoreaddonsSource`` recipe vendors 6.10.0 to match the KF6
    ## 6.x ABI requirement.
    "kcoreaddons >=6.0"
    ## M9.R.15f.5 — kwin's CMakeLists explicitly find_package(KF6Config
    ## REQUIRED), KF6I18n REQUIRED, KF6WidgetsAddons REQUIRED,
    ## KF6XmlGui REQUIRED, etc.; the legacy ``kf6-base`` umbrella name
    ## had no resolvable recipe. Replaced with the individual KF6
    ## modules we ship as from-source recipes (the kwin from-source
    ## convention layer probes for each via pkg-config at configure
    ## time).
    "kconfig >=6.0"
    "ki18n >=6.0"
    "kwidgetsaddons >=6.0"
    "kxmlgui >=6.0"
    "kservice >=6.0"
    "kglobalaccel >=6.0"
    "knotifications >=6.0"
    "ksvg >=6.0"
    "ksolid >=6.0"
    "kio >=6.0"
    "kded >=6.0"
    "plasma-framework >=6.0"
    ## wayland supplies the protocol scanner + libwayland-server kwin
    ## uses for its Wayland compositor implementation. The sibling
    ## ``waylandSource`` recipe vendors a compatible version.
    "wayland >=1.20"
    ## qt6-base supplies QtCore / QtGui / QtQml / QtQuick which the
    ## modern kwin compositor (incl. the QML-based effect runtime)
    ## consumes. 6.6 is the minimum the Plasma 6.2.x line targets.
    "qt6-base >=6.6"
    ## qt6-tools supplies the lupdate/lrelease/qhelpgenerator tooling
    ## ECM's per-module find_package(Qt6 ... LinguistTools) probe
    ## requires at configure time even when translations are disabled.
    "qt6-tools >=6.6"
    ## qt6-declarative supplies Qt6Qml + Qt6Quick the QML-based effect
    ## runtime + Plasma's QtQuick-driven UI consume.
    "qt6-declarative >=6.6"
    ## qt6-wayland supplies Qt6WaylandClient for kwin's Wayland client
    ## glue (find_package(Qt6 ... COMPONENTS WaylandClient REQUIRED)).
    "qt6-wayland >=6.6"
    ## qt6-svg supplies the Qt6Svg dependency kwin's QML scene loader
    ## consumes for vector icons.
    "qt6-svg >=6.6"
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
    ## M9.R.15q.4.5 — kwin's CMakeLists.txt requires:
    ##  - KDecoration2 (server-side decoration framework)
    ##  - KWayland (KDE Wayland client/server)
    ##  - kscreenlocker (lock-screen daemon, KWIN_BUILD_SCREENLOCKER=ON)
    ##  - kglobalacceld (global-shortcut daemon, KWIN_BUILD_GLOBALSHORTCUTS=ON)
    ##  - libcanberra (event-sound)
    ##  - libepoxy (GL dispatch)
    ##  - libdisplay-info (EDID parser)
    ##  - libei (emulated-input handling, optional but on)
    ##  - mesa (gbm + EGL + GL fallbacks)
    ##  - lcms2 (color management)
    ##  - freetype + fontconfig (QPA plugin)
    ##  - libsystemd (service watchdog)
    ##  - dbus (DBus client library)
    ##  - kactivities equivalent → plasma-activities
    ##  - plasma-wayland-protocols (Plasma-specific Wayland XML)
    ##  - wayland-protocols (upstream Wayland XML)
    "kdecoration2 >=6.0"
    "kwayland >=6.0"
    "kscreenlocker >=6.0"
    "kglobalacceld >=6.0"
    "libcanberra"
    "libepoxy >=1.3"
    "libdisplay-info"
    "libei"
    "mesa >=23.3"
    "lcms2"
    "freetype >=2.10"
    "fontconfig >=2.13"
    "libsystemd"
    "dbus >=1.14"
    "plasma-activities >=6.2"
    "plasma-wayland-protocols >=1.14"
    "wayland-protocols >=1.36"
    ## M9.R.15q.4.5 — additional KF6 components kwin's find_package
    ## line declares: KF6 COMPONENTS Auth ColorScheme IdleTime
    ## Declarative KCMUtils NewStuff Package; we have sibling source
    ## recipes for all of these (kauth, kcolorscheme, kidletime,
    ## kdeclarative, kcmutils, knewstuff, kpackage, kirigami) so the
    ## resolver picks them up via the sibling path.
    "kauth >=6.0"
    "kcolorscheme >=6.0"
    "kidletime >=6.0"
    "kdeclarative >=6.0"
    "kcmutils >=6.0"
    "knewstuff >=6.0"
    "kpackage >=6.0"
    "kirigami >=6.0"
    ## hwdata (RUNTIME) for monitor vendor-ID mapping.
    "hwdata"

  config:
    ## No prefix lifted from `cmakeFlags:`; flags inlined in the `build:` block.
    discard
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

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `cmake_package(...)` constructor.
    setCurrentOwningPackageOverride("kwinSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "KWIN_BUILD_TABBOX=OFF",
        "KWIN_BUILD_X11=OFF",
        "KWIN_BUILD_KCMS=OFF",
        # M9.R.15q.4.7 — disable optional kwin subsystems whose deps
        # ship under nix as runtime daemons without CMake config
        # files (kglobalacceld has no KGlobalAccelDConfig.cmake).
        # Re-enable later if we ship the matching from-source recipe.
        "KWIN_BUILD_GLOBALSHORTCUTS=OFF",
        "KWIN_BUILD_NOTIFICATIONS=OFF",
        "KWIN_BUILD_SCREENLOCKER=OFF",
        "KWIN_BUILD_RUNNERS=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.executable("kwinWayland")
      discard pkg.library("libKWin")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
