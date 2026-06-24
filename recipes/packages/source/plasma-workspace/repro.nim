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
    ## M9.R.15q.9.8 — additional REQUIRED KF6 components from
    ## plasma-workspace's
    ## ``find_package(KF6 ... REQUIRED COMPONENTS Auth Parts Runner
    ## Notifications NotifyConfig NewStuff Wallet IdleTime Svg
    ## Declarative I18n KCMUtils TextWidgets Crash GlobalAccel
    ## DBusAddons CoreAddons KIO Prison Package GuiAddons Archive
    ## ItemModels IconThemes UnitConversion TextEditor
    ## StatusNotifierItem)`` probe.  Sibling from-source recipes for
    ## the components we already ship + stdlib stubs for the rest.
    "extra-cmake-modules >=6.0"
    "kauth >=6.0"
    "kidletime >=6.0"
    "kdeclarative >=6.0"
    "kcmutils >=6.0"
    "knewstuff >=6.0"
    "kpackage >=6.0"
    "kitemmodels >=6.0"
    "kcrash >=6.0"
    "kunitconversion >=6.0"
    ## M9.R.15q.10.5 — ktexteditor dropped because its only consumer in
    ## plasma-workspace is the ``interactiveconsole`` Plasma-script
    ## debug widget (loads katepart via KPluginFactory). That widget is
    ## not a v1 desktop-runtime path, and ktexteditor's transitive deps
    ## (qt6-speech ← qt6-multimedia ← ...) inflate the recipe count
    ## beyond what the M9.R.15q.10 4-hour budget can absorb.  The
    ## ``srcPatches`` field on the cmake_package call drops the
    ## TextEditor component from the umbrella probe AND skips the
    ## interactiveconsole subdir so the ``find_package(KF6 ...
    ## REQUIRED COMPONENTS ... TextEditor ...)`` no longer fails.
    "kstatusnotifieritem >=6.0"
    ## M9.R.15q.9.9 — sonnet is ktextwidgets's transitive
    ## find_package dep; without it the KF6TextWidgets find_package
    ## probe sets KF6TextWidgets_FOUND=FALSE.
    "sonnet >=6.0"
    ## M9.R.15q.9.8 — Plasma framework family (PlasmaActivities +
    ## PlasmaWaylandProtocols + KWayland surface through these source
    ## recipes; PlasmaQuick is part of plasma-framework).
    "plasma-activities >=6.0"
    "plasma-wayland-protocols >=1.14"
    "kwayland >=6.0"
    ## M9.R.15q.9.8 — X11 transitive deps for KF6KIO ->
    ## KF6WindowSystem find_package probe at configure time. Even
    ## though plasma-workspace is pure-Wayland at runtime, the
    ## ``find_package(KF6WindowSystem)`` config-time probe (driven
    ## by KIO's CMake config) verifies X11 client libs are reachable.
    "xorgproto"
    "libx11"
    "libxcb"
    "libxau"
    "libxdmcp"
    "xcb-util-keysyms"
    "xcb-util-wm"
    "libxext"
    "libxfixes"
    "libxrender"
    ## qt6-base supplies QtCore / QtGui / QtWidgets / QtConcurrent /
    ## QtNetwork / QtDBus which the Plasma shell uses for its base UI +
    ## IPC surface.
    "qt6-base >=6.6"
    ## qt6-tools supplies the lupdate/lrelease/qhelpgenerator tooling
    ## ECM's per-module find_package(Qt6 ... LinguistTools) probe
    ## requires at configure time even when translations are disabled.
    "qt6-tools >=6.6"
    ## M9.R.15q.8.3 — plasma-workspace's CMakeLists explicitly
    ## `find_package(Qt6 ... COMPONENTS Svg Widgets Quick QuickWidgets
    ## Concurrent Network Core5Compat DBus ShaderTools Positioning)`.
    ## The components beyond qt6-base + qt6-tools split across these
    ## sibling Qt6 from-source recipes:
    ##   * qt6-svg          - Qt6Svg
    ##   * qt6-declarative  - Qt6Qml + Qt6Quick + Qt6QuickWidgets
    ##   * qt6-5compat      - Qt6Core5Compat
    ##   * qt6-shadertools  - Qt6ShaderTools
    ##   * qt6-wayland      - Qt6WaylandCompositor + Qt6WaylandClient
    ##   * qt6-positioning  - Qt6Positioning (M9.R.15q.9.1)
    "qt6-svg >=6.6"
    "qt6-declarative >=6.6"
    "qt6-5compat >=6.6"
    "qt6-shadertools >=6.6"
    "qt6-wayland >=6.6"
    "qt6-positioning >=6.6"
    ## M9.R.15q.9.2 — plasma-workspace's CMakeLists.txt pulls a long
    ## tail of KF6 + Plasma + Qt6 modules via find_package probes
    ## (QCoro6, KF6Parts, KF6Runner, KF6NotifyConfig, KF6Wallet,
    ## KF6Prison, KF6TextWidgets, KSysGuard, LayerShellQt, Phonon4Qt6,
    ## Plasma5Support, PlasmaActivitiesStats, KScreen, Breeze).
    ## Each maps to a sibling stdlib stub registered through the
    ## kf6_qt6_modules aggregator; --tool-provisioning=nix surfaces
    ## the prebuilt nixpkgs derivation for each.
    "qcoro6 >=0.10"
    "kparts >=6.0"
    "krunner >=6.0"
    "knotifyconfig >=6.0"
    "kwallet >=6.0"
    "kprison >=6.0"
    "ktextwidgets >=6.0"
    "ksysguard >=6.0"
    "layer-shell-qt >=6.0"
    "phonon4qt6 >=4.12"
    "plasma5support >=6.0"
    "plasma-activities-stats >=6.0"
    "kscreen >=6.0"
    "breeze >=6.0"
    ## M9.R.15q.4.5 wave — Plasma session-leader deps already lifted
    ## in earlier stubs (kpipewire / kglobalacceld / kscreenlocker).
    "kpipewire >=6.0"
    "kglobalacceld >=6.0"
    "kscreenlocker >=6.0"

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

  executable startplasmaWayland:
    ## M9.R.32.1 — ``/usr/bin/startplasma-wayland`` is the Plasma
    ## Wayland session entry-point.  SDDM's autologin chain ultimately
    ## exec's this binary, which sets up the XDG environment, launches
    ## kwin_wayland, then chain-exec's plasmashell.  The CMake target
    ## lives in ``src/CMakeLists.txt``'s ``add_subdirectory(startkde)``
    ## (restored below in ``srcPatches``) and emits the binary under
    ## ``build/startkde/startplasma-wayland`` -> ``usr/bin/startplasma-
    ## wayland`` in the install-mirror.  The DSL identifier
    ## ``startplasmaWayland`` kebabs to ``startplasma-wayland`` via
    ## the stage-copy probe.
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
        # M9.R.15q.12.10 — plasma-workspace's top-level CMakeLists
        # declares ``option(WITH_X11 ... ON)`` with WITH_X11 ON by
        # default, which gates the X11 ``find_package(XCB ... COMPONENTS
        # XCB RANDR IMAGE)`` REQUIRED probe. We don't ship xcb-image as
        # a from-source recipe (libxcb covers the base XCB but not the
        # IMAGE component), and the v1 Plasma path is pure-Wayland.
        # Disable to take the no-X11 branch.
        "WITH_X11=OFF",
        # M9.R.15q.12.13 — disable glibc locale-gen integration. The
        # plasma-workspace ``regional & language`` KCM ships an
        # SUID-style ``localegen`` helper that uses PolkitQt6-1 +
        # glibc's locale-gen tool to dynamically install OS locales.
        # ``GLIBC_LOCALE_GEN`` defaults ON; flipping it OFF skips the
        # ``REGION_LANG_GENERATE_LOCALE_HELPER`` branch which in turn
        # skips the ``find_package(PolkitQt6-1 ... REQUIRED)`` probe.
        # We don't ship PolkitQt6-1 as a from-source sibling; the v1
        # Plasma session uses statically-installed locales (set via
        # /etc/locale.conf / LANG env vars). A future fullbuild
        # milestone can add PolkitQt6-1 + restore the helper.
        "GLIBC_LOCALE_GEN=OFF",
        "CMAKE_BUILD_TYPE=Release",
        # M9.R.15q.13.6 — disable cmake's multithreaded AUTOGEN to work
        # around a cmake 4.1 bug where ``cmake -E cmake_autogen`` keeps
        # the moc-pipe write end open in the parent after forking moc
        # children, then blocks forever on a read(7) when moc exits.
        # Empirically the wedge fires non-deterministically (different
        # autogen target each run), creates 6+ moc zombies, and stalls
        # the build past the WSL killer timeout.  Serialising autogen
        # (1 moc at a time) prevents the multi-pipe race that triggers
        # the bug.  CMAKE_AUTOGEN_PARALLEL=1 forces sequential moc
        # invocation per target; the rest of the build still parallelises
        # at the make/--parallel level so the impact on wall-time is
        # bounded.
        "CMAKE_AUTOGEN_PARALLEL=1",
      ]
      # M9.R.15q.7.1 — cap cmake's internal compile parallelism to match
      # the build engine's standard ``compile=8`` pool budget (mirrors
      # the kwin recipe; same template-heavy KDE C++ memory profile).
      # Without this, cmake's bare ``--parallel`` defers to nproc and on
      # a 32-core / 64 GiB WSL host the resulting cc1plus stampede OOMs
      # the VM mid-compile (M9.R.15q.7 wsl-crash observation, see kwin).
      #
      # M9.R.15q.7.4 — env-var alone is insufficient (ninja ignores it);
      # the recipe activates the M9.R.15q.7.3 cmake_package opt-in
      # ``--parallel <N>`` bake via the same env-var entry below.
      let env = @[
        ("CMAKE_BUILD_PARALLEL_LEVEL", "8"),
      ]
      # M9.R.15q.10.5 — drop the ``TextEditor`` umbrella component +
      # the ``add_subdirectory(interactiveconsole)`` glue.
      # interactiveconsole is the only consumer of KF6::TextEditor in
      # plasma-workspace's source tree and is a debug widget that loads
      # katepart at runtime; v1 ships without it so the umbrella probe
      # doesn't need ktexteditor (which in turn requires qt6-speech +
      # qt6-multimedia, neither yet a from-source recipe).
      let patches = @[
        "sed -i 's/ TextEditor StatusNotifierItem/ StatusNotifierItem/' src/CMakeLists.txt",
        "sed -i 's|^add_subdirectory(interactiveconsole)$|# M9.R.15q.10.5: dropped — needs ktexteditor / qt6-speech\\n# add_subdirectory(interactiveconsole)|' src/CMakeLists.txt",
        # M9.R.15q.12.9 — drop the libqalculate REQUIRED probe. The
        # only consumer is the calculator-runner KRunner plugin
        # (``src/runners/calculator/``) which is wrapped in
        # ``if (QALCULATE_FOUND)`` at the runners CMakeLists, so
        # dropping the top-level probe simply skips the runner
        # subdir at configure time. v1 ships without the calculator
        # KRunner; users get other Plasma calculators (e.g. KCalc
        # standalone). A future fullbuild milestone can add
        # libqalculate as an explicit from-source recipe + restore
        # the runner.
        "sed -i 's|^pkg_check_modules(QALCULATE libqalculate>2.0 REQUIRED IMPORTED_TARGET)$|# M9.R.15q.12.9: dropped — libqalculate not in from-source corpus|' src/CMakeLists.txt",
        # M9.R.15q.12.10 — wrap ``add_subdirectory(ksmserver)`` in
        # ``if(WITH_X11)``. ksmserver (the KDE session manager) uses
        # X11_ICE_LIB via ``check_library_exists`` at the top of its
        # CMakeLists; the variable resolves to NOTFOUND when WITH_X11
        # is OFF (which we set above). We don't ship libICE/libSM as
        # from-source siblings (they're part of the legacy X11
        # session-management protocol, not load-bearing for a pure-
        # Wayland Plasma session). Skip the subdir entirely; the
        # plasmashell + libPlasmaWorkspace artifacts the recipe
        # registers don't depend on ksmserver targets.
        "sed -i 's|^add_subdirectory(ksmserver)$|if(WITH_X11)\\n    add_subdirectory(ksmserver)\\nendif()|' src/CMakeLists.txt",
        # M9.R.15q.12.11 — wrap ``ecm_optional_add_subdirectory(xembed-
        # sni-proxy)`` in ``if(WITH_X11)``. xembed-sni-proxy bridges
        # legacy XEmbed system-tray icons into the Plasma system tray;
        # it ``find_package(XCB ... COMPONENTS UTIL IMAGE REQUIRED)``
        # at the top of its CMakeLists. We don't ship xcb-util / xcb-
        # util-image and a pure-Wayland v1 session doesn't load XEmbed
        # legacy tray icons (the modern path is the StatusNotifierItem
        # D-Bus interface).
        "sed -i 's|^ecm_optional_add_subdirectory(xembed-sni-proxy)$|if(WITH_X11)\\n    ecm_optional_add_subdirectory(xembed-sni-proxy)\\nendif()|' src/CMakeLists.txt",
        # M9.R.15q.12.13 — relax the ICU package TYPE from REQUIRED to
        # OPTIONAL. ICU is used by Kicker (application-launcher applet)
        # for better-localised group names and by clock applets for
        # timezone display; both gracefully fall back when ICU is
        # absent (the code is wrapped in ``if(HAVE_ICU)``). The
        # feature_summary FATAL_ON_MISSING_REQUIRED_PACKAGES at the
        # bottom of CMakeLists fails the configure when ICU is marked
        # REQUIRED-but-missing. We don't ship ICU as a from-source
        # sibling; flipping it to OPTIONAL keeps the build going +
        # users get C-locale group names (a soft degradation).
        "sed -i '/^find_package(ICU/,/^)$/{s|TYPE REQUIRED|TYPE OPTIONAL|}' src/CMakeLists.txt",
        # M9.R.15q.12.14 — the digital-clock plugin's
        # ``target_link_libraries`` unconditionally links ``ICU::i18n``
        # + ``ICU::uc``; cmake fails the Generate step with
        # ``Target "digitalclockplugin" links to: ICU::i18n but the
        # target was not found`` when ICU is absent. Strip the two ICU
        # link entries — the timezonesi18n.h code in the digital-clock
        # plugin uses ICU only for some country-name pretty-printing
        # in tooltips, which silently degrades to bare en_US strings
        # when the ICU symbols aren't linked (the QtCore i18n stack
        # provides a fallback).
        "sed -i '/^        ICU::i18n$/d; /^        ICU::uc$/d' src/applets/digital-clock/plugin/CMakeLists.txt",
        # M9.R.15q.12.15 — bracket the X11OutputOrderWatcher method
        # definitions (ctor + refresh + nativeEventFilter + roundtrip,
        # lines 134-312 in upstream 6.2.5) with ``#if HAVE_X11`` /
        # ``#endif``.  The upstream source has the class declaration
        # in the header gated by HAVE_X11 + has the factory branch in
        # the .cpp gated (line 88), but the four method definitions
        # below the WaylandOutputOrderWatcher factory branch are NOT
        # guarded, which trips compile with ``'X11OutputOrderWatcher'
        # does not name a type`` when WITH_X11=OFF.
        # Insert ``#if HAVE_X11`` right BEFORE the X11OutputOrderWatcher
        # ctor and ``#endif`` right BEFORE the WaylandOutputOrder-
        # Watcher ctor; these are stable anchors in 6.2.5.
        "sed -i 's|^X11OutputOrderWatcher::X11OutputOrderWatcher(QObject \\*parent)$|#if HAVE_X11\\nX11OutputOrderWatcher::X11OutputOrderWatcher(QObject *parent)|' src/libkworkspace/outputorderwatcher.cpp",
        "sed -i 's|^WaylandOutputOrderWatcher::WaylandOutputOrderWatcher(QObject \\*parent)$|#endif // HAVE_X11\\nWaylandOutputOrderWatcher::WaylandOutputOrderWatcher(QObject *parent)|' src/libkworkspace/outputorderwatcher.cpp",
        # M9.R.15q.12.16 — drop the digital-clock and kicker applet
        # subdirs; both ``#include`` ICU's ``<unicode/*.h>`` headers
        # (kicker for transliteration in search-result matching; the
        # digital-clock plugin for timezone-name i18n). We don't ship
        # ICU as a from-source sibling and patching out the include +
        # call sites in each TU is more invasive than the v1 surface
        # justifies. Both are Plasma applets (per-applet QML packages
        # that plasmashell loads at runtime). plasmashell itself +
        # libPlasmaWorkspace.so (the two artifacts this recipe ships)
        # build + ship without them; users get a Plasma session with
        # fewer panel applets out of the box. A future plasma-
        # fullbuild milestone can add ICU + restore both applets.
        "sed -i 's|^add_subdirectory(digital-clock)$|# M9.R.15q.12.16: dropped — needs ICU (unicode/tznames.h)|' src/applets/CMakeLists.txt",
        "sed -i 's|^add_subdirectory(kicker)$|# M9.R.15q.12.16: dropped — needs ICU (unicode/translit.h)|' src/applets/CMakeLists.txt",
        # M9.R.15q.13.3 — gate gmenu-dbusmenu-proxy on WITH_X11. The
        # gmenu-dbusmenu-proxy menuproxy.h #includes <xcb/xcb_atom.h>
        # (from xcb-util) which we don't ship as a from-source sibling;
        # the subdir also unconditionally find_package(XCB REQUIRED).
        # Plasma's modern Wayland menu path is the StatusNotifierItem /
        # Plasma::Menu QML; the gmenu-dbusmenu-proxy bridge only
        # surfaces GTK-app global menus for X11 sessions.
        "sed -i 's|^ecm_optional_add_subdirectory(gmenu-dbusmenu-proxy)$|if(WITH_X11)\\n    ecm_optional_add_subdirectory(gmenu-dbusmenu-proxy)\\nendif()|' src/CMakeLists.txt",
        # M9.R.15q.13.5 — drop the kcm_users sub-target.  kcm_users links
        # against libcrypt for /etc/shadow password hashing in the
        # account-management KCM; we don't ship libxcrypt as a from-
        # source sibling and the v1 Plasma session doesn't need the
        # user-management KCM at the shell layer (users can change
        # passwords via ``passwd`` from a terminal, or distributions can
        # add the kcm_users glue in a fullbuild milestone with libxcrypt
        # added).  Drop the add_subdirectory(users) entry from the kcms
        # umbrella CMakeLists.
        "sed -i 's|^add_subdirectory(users)$|# M9.R.15q.13.5: dropped — needs libcrypt (kcm_users links -lcrypt)|' src/kcms/CMakeLists.txt",
        # M9.R.15q.13.8 — drop the kcm_fonts sub-target.  kxftconfig.cpp
        # ``#include <private/qtx11extras_p.h>`` (a Qt5 X11 compat
        # header) which we don't ship as a from-source sibling (qt6 base
        # ships qtx11extras only when QT_FEATURE_xcb is enabled, which
        # is off in our qt6-base recipe to avoid pulling in libX11/libxcb
        # at the Qt layer).  v1 Plasma session can run with system
        # fontconfig defaults; the fonts-KCM (font-rendering tweaks /
        # subpixel hinting UI) can be restored when qt6-base picks up
        # the xcb private headers in a fullbuild milestone.
        "sed -i 's|^    add_subdirectory( fonts )$|    # M9.R.15q.13.8: dropped — needs Qt6 private/qtx11extras_p.h|' src/kcms/CMakeLists.txt",
        # M9.R.15q.13.9 — drop krdb. kcms/krdb/krdb.cpp #includes
        # ``<X11/Xlib.h>`` + ``<private/qtx11extras_p.h>`` and links
        # against ``X11::X11``. krdb is the legacy X11 resource-database
        # KCM that propagated X11-resource colour/font settings; modern
        # Plasma session uses fontconfig + Qt theming. Drop the subdir;
        # the plasmashell target doesn't link against libkrdb.
        "sed -i 's|^add_subdirectory(krdb)$|# M9.R.15q.13.9: dropped — needs X11/Xlib.h + qtx11extras|' src/kcms/CMakeLists.txt",
        # M9.R.15q.13.10 — drop cursortheme.  kcmcursortheme.cpp #includes
        # ``<X11/Xlib.h>`` + ``<X11/Xcursor/Xcursor.h>`` for X11 cursor
        # propagation; the umbrella gate ``if(X11_Xcursor_FOUND)`` is
        # supposed to skip it but X11_Xcursor_FOUND may resolve via the
        # cmake transitive walk even with WITH_X11=OFF.  Pre-emptive
        # skip.  Plasma Wayland session uses XDG cursor themes; the
        # cursortheme KCM can be restored when xcb/X11 are added.
        "sed -i 's|^    add_subdirectory(cursortheme)$|    # M9.R.15q.13.10: dropped — needs X11/Xcursor|' src/kcms/CMakeLists.txt",
        # M9.R.15q.13.11 — drop kcm_style + kcm_colors.  Both
        # #include ``krdb.h`` from the dropped krdb library (M9.R.15q.13.9).
        # These are theme-preference KCMs that propagate the chosen
        # style/color scheme into X11 resources via the krdb helper;
        # Plasma Wayland session uses QStyle + Qt theming directly and
        # doesn't need the X11-resource bridge.  Restore in fullbuild
        # when krdb's X11 dependency is satisfied.
        "sed -i 's|^add_subdirectory(style)$|# M9.R.15q.13.11: dropped — needs krdb (X11 resources)|' src/kcms/CMakeLists.txt",
        "sed -i 's|^add_subdirectory(colors)$|# M9.R.15q.13.11: dropped — needs krdb (X11 resources)|' src/kcms/CMakeLists.txt",
        # M9.R.15q.13.12 — drop the lookandfeel KCM since its kcm.cpp
        # ``#include "krdb.h"`` and we already dropped krdb (13.9).
        # plasmashell doesn't depend on the lookandfeel KCM at runtime.
        "sed -i 's|^add_subdirectory(lookandfeel)$|# M9.R.15q.13.12: dropped — needs krdb (X11 resources)|' src/kcms/CMakeLists.txt",
        # M9.R.15q.13.13 — wrap m_previousWId = 0 in clearPreviousWindow
        # in HAVE_X11 (the field is gated on HAVE_X11 in the header but
        # the bare assignment in the .cpp isn't).
        "sed -i 's|^    m_previousWId = 0;$|#if HAVE_X11\\n    m_previousWId = 0;\\n#endif|' src/shell/shellcorona.cpp",
        # M9.R.32.1 — restore ``add_subdirectory(startkde)`` so the
        # startplasma-wayland binary is produced.  Without it, the
        # Plasma Wayland session entry-point is missing and the live
        # ISO falls through to a console.  Below patches strip the
        # lookandfeelmanager dependency from startplasma.cpp +
        # startkde/CMakeLists.txt so the build no longer needs the
        # dropped lookandfeel KCM library (M9.R.15q.13.12 dropped
        # the lookandfeel KCM itself; that decision stands — only the
        # session-launcher's compile dependency on its header is
        # surgically removed here).
        #
        # The LookAndFeelManager-using code in startplasma.cpp's
        # ``setupPlasmaEnvironment()`` reapplies the user's
        # look-and-feel package (color scheme, cursor theme,
        # default Plasma layout) on session start when the active
        # package changed since last login.  Stripping it makes
        # session start use the kdedefaults already on disk + any
        # KConfig overrides — a soft degradation users can recover
        # from by re-applying the look-and-feel KCM in a fullbuild
        # milestone that ships PolkitQt6-1 + krdb + libcrypt + ICU
        # + qtx11extras.
        "sed -i 's|^#include \"../kcms/lookandfeel/lookandfeelmanager.h\"$|// M9.R.32.1: dropped — lookandfeel KCM not built (see M9.R.15q.13.12)|' src/startkde/startplasma.cpp",
        # Replace the LookAndFeelManager-using block inside
        # setupPlasmaEnvironment() with a no-op marker, then re-close
        # the function.  We use a sed range delete anchored on the
        # ``const KConfig globals;`` line (start) and the final closing
        # brace of setupPlasmaEnvironment (last ``    }`` line before
        # ``cleanupPlasmaEnvironment``).  After the delete we re-add a
        # bare ``}`` so the function terminates cleanly.
        #
        # The delete range:
        #   FROM:  /^    const KConfig globals;$/
        #   TO:    /^void cleanupPlasmaEnvironment/
        # captures the entire tail (both lookandfeel blocks + the
        # implicit setupPlasmaEnvironment close brace + the blank
        # line) up to but NOT including the next function header.
        # We then insert a single ``}\n\n`` before
        # cleanupPlasmaEnvironment to restore the function close.
        "sed -i '/^    const KConfig globals;$/,/^void cleanupPlasmaEnvironment/{ /^void cleanupPlasmaEnvironment/!d; }' src/startkde/startplasma.cpp",
        "sed -i 's|^void cleanupPlasmaEnvironment|}\\n\\nvoid cleanupPlasmaEnvironment|' src/startkde/startplasma.cpp",
        # Drop the ``lookandfeelmanager`` entry from the startplasma
        # OBJECT lib's target_link_libraries.  The startkde
        # CMakeLists block:
        #
        #     target_link_libraries(startplasma PUBLIC
        #         Qt::Core
        #         ...
        #         lookandfeelmanager
        #     )
        #
        # becomes the same block minus the final library name.
        "sed -i '/^    lookandfeelmanager$/d' src/startkde/CMakeLists.txt",
        # M9.R.32.1 — gate the startplasma-x11 target on WITH_X11.  The
        # target links X11::X11 + kcheckrunning.cpp which both need the
        # X11 client libraries we don't ship.  startplasma-wayland is
        # the v1 path and stays unconditional.  Delete the four
        # x11-target lines (add_executable, target_link_libraries
        # block, install TARGETS).
        "sed -i '/^add_executable(startplasma-x11/d' src/startkde/CMakeLists.txt",
        "sed -i '/^target_link_libraries(startplasma-x11 PRIVATE$/,/^)$/d' src/startkde/CMakeLists.txt",
        "sed -i '/^install(TARGETS startplasma-x11/d' src/startkde/CMakeLists.txt",
        # M9.R.15q.13.15 — drop kcm_autostart since its unit.cpp
        # #includes systemd/sd-journal.h which trips -Werror=undef on
        # __STDC_VERSION__ in C++ mode.  v1 plasmashell does not depend
        # on the autostart KCM at runtime.
        "sed -i 's|^add_subdirectory(autostart)$|# M9.R.15q.13.15: dropped — systemd sd-id128.h -Werror=undef|' src/kcms/CMakeLists.txt",
        # M9.R.15q.13.7 — bracket the X11-only KX11Extras calls in
        # panelconfigview.cpp with ``#if HAVE_X11`` / ``#endif``.  The
        # KX11Extras include at the top is already gated on HAVE_X11
        # (line 27-28), but the runtime-X11 ``if (KWindowSystem::
        # isPlatformX11()) { KX11Extras::setType(...); KX11Extras::set
        # State(...); }`` block on lines 107-110 is NOT gated, which
        # trips the compile with ``KX11Extras has not been declared``
        # when WITH_X11=OFF.  Wrap the inner KX11Extras calls (NOT the
        # outer ``isPlatformX11()`` if-statement, which is still
        # conceptually correct as a runtime no-op when X11 is unbuilt).
        "sed -i 's|^        KX11Extras::setType(winId(), NET::Dock);$|#if HAVE_X11\\n        KX11Extras::setType(winId(), NET::Dock);|' src/shell/panelconfigview.cpp",
        "sed -i 's|^        KX11Extras::setState(winId(), NET::KeepAbove);$|        KX11Extras::setState(winId(), NET::KeepAbove);\\n#endif|' src/shell/panelconfigview.cpp",
      ]
      # M9.R.33.2 — the M9.R.32.1.2 recipe-local CMAKE_MODULE_PATH +
      # GLESv2 hint block was lifted to the M9.R.33.2 walker
      # (``m9r33Collect2Qt6CmakeModulePathDirs`` +
      # ``m9r33Emit2MesaGlesv2CacheVars``) so every qt6-* consumer
      # (plasma-workspace + every KF6 module + every Plasma component)
      # gets the fresh-configure fix automatically.  The walker emits
      # the same dirs + hints whenever a qt6-* dep is declared AND the
      # corresponding install-mirror is present on disk.
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts,
                              extraEnv = env, srcPatches = patches)
      discard pkg.executable("plasmashell")
      discard pkg.executable("startplasmaWayland")
      discard pkg.library("libPlasmaWorkspace")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
