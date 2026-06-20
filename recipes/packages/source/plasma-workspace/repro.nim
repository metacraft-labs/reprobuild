## Source-from-tarball plasma-workspace recipe — the TWENTY-FIRST real
## from-source production recipe to exercise the M9.H/I/K trio and the
## THIRD recipe in the Plasma stack batch (kcoreaddons / kwin /
## plasma-workspace / sddm).
##
## Prior twenty from-source recipes — fourteen meson, one make, three
## CMake (json-c, kcoreaddons, kwin), two autotools (expat, gdm) —
## collectively covered every M9.I flag-injection channel and every
## artifact-kind permutation. plasma-workspace is the FOURTH CMake-
## driven recipe and the FIRST CMake recipe to combine BOTH a
## multi-word-kebab package name (``plasma-workspace`` ->
## ``plasmaWorkspaceSource``) AND a mixed-kind artifact set (library +
## executable). The gnome-shell precedent exercised the same shape on
## the meson channel; this is the CMake-side analogue, so a regression
## that fumbled the multi-word kebab-to-camel translation specifically
## on the CMake channel would surface here.
##
## ## Why plasma-workspace matters for the v1 desktop story
##
## plasma-workspace is the KDE Plasma user-session UI — the analogue
## of gnome-shell for the Plasma story. The standalone ``plasmashell``
## binary is the user-session leader: it owns the task bar, system
## tray, application launcher, activities, lock screen, and global
## notifications. ``libPlasmaWorkspace.so`` is the Plasma workspace
## library third-party Plasma widgets + applets link against to
## register UI contributions. NDE-K1's
## ``startplasma-wayland`` chain-execs into ``plasmashell`` after kwin
## hands off the Wayland compositor. The from-source recipe lifts the
## NDE-K1 apt-jammy plasma-workspace .deb pin to a real
## ``plasmashell`` binary + ``libPlasmaWorkspace.so`` library artifact
## for the v2 Plasma story.
##
## ## sha256 strategy
##
## We vendor the upstream 6.2.5 .tar.xz at
## ``recipes/packages/source/plasma-workspace/vendor/plasma-workspace-6.2.5.tar.xz``
## and reference it via a ``file://`` URL. The download.kde.org release
## URL is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 6.2.5 (matches the sibling kwin pin)
##
## download.kde.org publishes KDE Plasma releases at
## ``https://download.kde.org/stable/plasma/<x.y.z>/``. plasma-workspace
## 6.2.5 is the current stable matching the sibling ``kwinSource``
## 6.2.5 pin (the Plasma 6.x point releases ship as a coordinated set
## so plasma-workspace + kwin minor lines MUST stay in lockstep).
##
## sha256 = b82511e46f62e1b8f60b969c828c8d8d32fc7928401a70cc28c29f85f46c412f
##  (computed locally over the vendored ``plasma-workspace-6.2.5.tar.xz``,
##  19,136,676 bytes; downloaded once from the upstream URL recorded in
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
## plasma-workspace's CMake build emits one shared library + one
## standalone binary (among many others — we only register the v1
## artifacts the NDE-K1 desktop entry depends on):
##
##   * ``libPlasmaWorkspace.so`` — the Plasma workspace library third-
##                                  party Plasma widgets + applets link
##                                  against to register UI
##                                  contributions.
##   * ``plasmashell`` — the standalone shell binary that drives the
##                       Plasma user-session UI (task bar, system
##                       tray, application launcher, activities, lock
##                       screen, notifications). NDE-K1's
##                       ``startplasma-wayland`` chain-execs into
##                       this after kwin hands off the Wayland
##                       compositor.
##
## We register the library under the package-level identifier
## ``libPlasmaWorkspace`` (camelCased from the upstream hyphenated
## package name ``plasma-workspace`` per the gdk-pixbuf precedent of
## kebab-to-PascalCase + preserved ``lib`` prefix), and the executable
## under ``plasmashell`` (kept verbatim — the upstream binary name is
## already a single lowercase word, no kebab segments to camelCase).
##
## ## Configurables
##
## v1 ships NO configurables — the CMake options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``BUILD_TESTING=OFF``  — skip the upstream test suite to keep
##                                the build hermetic + fast.
##   * ``KWIN_BUILD_X11=OFF`` — skip the X11/XWayland session support
##                                (the v1 Plasma story is pure-Wayland;
##                                the NDE-K1 spec pins only
##                                ``plasma.desktop``, not
##                                ``plasmax11.desktop``). The flag
##                                propagates through plasma-workspace's
##                                kwin-integration sub-build to keep
##                                this recipe in lockstep with the
##                                sibling ``kwinSource`` recipe's
##                                identical ``-DKWIN_BUILD_X11=OFF``.
##   * ``CMAKE_BUILD_TYPE=Release`` — release-mode optimisation;
##                                     matches the sibling from-source
##                                     recipes' ``--buildtype=release``
##                                     meson option.
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

package plasmaWorkspaceSource:
  ## From-source plasma-workspace — twenty-first M9.H/I/K production
  ## recipe and the THIRD recipe in the Plasma stack batch. Fourth
  ## CMake-driven recipe after json-c + kcoreaddons + kwin, and the
  ## FIRST CMake recipe to combine BOTH a multi-word-kebab package
  ## name (``plasma-workspace`` -> ``plasmaWorkspaceSource``) AND a
  ## mixed-kind artifact set.
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
    ## project --- plasma-workspace's canonical home.
    "6.2.5":
      sourceRevision = "v6.2.5"
      sourceUrl = "https://download.kde.org/stable/plasma/6.2.5/plasma-workspace-6.2.5.tar.xz"
      sourceRepository = "https://invent.kde.org/plasma/plasma-workspace"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 19,136,676-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://download.kde.org/stable/plasma/6.2.5/plasma-workspace-6.2.5.tar.xz"
    sha256: "b82511e46f62e1b8f60b969c828c8d8d32fc7928401a70cc28c29f85f46c412f"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver — the c_cpp_cmake convention's
    ## configure action invokes ``cmake -S <src> -B <build>``.
    ## plasma-workspace 6.x requires cmake 3.16 for the modern ECM +
    ## Qt6 ``find_package`` semantics the Plasma 6.x ABI line depends
    ## on.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux — the compile action
    ## invokes ``ninja`` (or ``cmake --build``) against the CMake build
    ## directory.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — plasma-workspace is C++20.
    "gcc >=11"

  buildDeps:
    ## kwin is the Wayland compositor plasma-workspace's session leader
    ## chain-execs into after the Plasma session bootstraps. The
    ## sibling ``kwinSource`` recipe vendors 6.2.5 to match the
    ## Plasma 6.2.x point-release coordination.
    "kwin >=6.2"
    ## M9.R.15f.5 — the legacy ``kf6-base`` umbrella name had no
    ## resolvable recipe. Replaced with the individual KF6 modules we
    ## ship as from-source recipes (plasma-workspace's CMakeLists
    ## explicitly find_package(KF6CoreAddons REQUIRED), KF6Config
    ## REQUIRED, KF6I18n REQUIRED, etc.).
    "kcoreaddons >=6.0"
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
    ## qt6-base supplies QtCore / QtGui / QtQml / QtQuick which the
    ## QML-driven Plasma shell uses for its entire UI surface.
    "qt6-base >=6.6"
    ## qt6-tools supplies the lupdate/lrelease/qhelpgenerator tooling
    ## ECM's per-module find_package(Qt6 ... LinguistTools) probe
    ## requires at configure time even when translations are disabled.
    "qt6-tools >=6.6"

  config:
    ## No prefix lifted from `cmakeFlags:`; flags inlined in the `build:` block.
    discard
  executable plasmashell:
    ## ``/usr/bin/plasmashell`` — the standalone shell binary that
    ## drives the Plasma user-session UI (task bar, system tray,
    ## application launcher, activities, lock screen, notifications).
    ## NDE-K1's ``startplasma-wayland`` chain-execs into this after
    ## kwin hands off the Wayland compositor. v1 records the artifact
    ## only; the per-artifact build body lands in M9.L when the
    ## convention's ninja-spawn + install-glue closes.
    discard

  library libPlasmaWorkspace:
    ## ``libPlasmaWorkspace.so`` — the Plasma workspace library
    ## third-party Plasma widgets + applets link against to register
    ## UI contributions. The kebab-cased upstream package name
    ## ``plasma-workspace`` is camelCased to ``libPlasmaWorkspace``
    ## per the gdk-pixbuf precedent + preserved ``lib`` prefix.
    ## v1 records the artifact only.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `cmake_package(...)` constructor.
    setCurrentOwningPackageOverride("plasmaWorkspaceSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "KWIN_BUILD_X11=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.executable("plasmashell")
      discard pkg.library("libPlasmaWorkspace")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
