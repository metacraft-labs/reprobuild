## Source-from-tarball sddm recipe — the TWENTY-SECOND real from-source
## production recipe to exercise the M9.H/I/K trio and the CLOSING
## recipe in the Plasma stack batch (kcoreaddons / kwin /
## plasma-workspace / sddm).
##
## Prior twenty-one from-source recipes — fourteen meson, one make,
## four CMake (json-c, kcoreaddons, kwin, plasma-workspace), two
## autotools (expat, gdm) — collectively covered every M9.I
## flag-injection channel and every artifact-kind permutation. sddm is
## the FIFTH CMake-driven recipe and the FIRST recipe in the suite to
## ship THREE artifacts (two executables + one library) from a single
## ``package`` macro. Every prior multi-artifact recipe shipped either
## TWO artifacts (wayland's two libs, pango's two libs, mutter +
## gnome-shell + kwin + plasma-workspace's library+executable pairs,
## gdm's two executables) or FOUR (glib2's four libs). The unique
## coverage angle for this third-artifact-count recipe is the
## three-artifact cardinality + the mixed-kind (2 exec + 1 lib) split:
## a regression that collapsed the artifact-name partitioning would
## surface here, and a regression that mis-tagged any of the three
## individual kind discriminants (exec vs lib) would surface too.
##
## ## Why sddm matters for the v1 desktop story
##
## SDDM (Simple Desktop Display Manager) is the KDE-flavoured login
## manager — the analogue of gdm for the Plasma story. The standalone
## ``sddm`` binary is the long-running display-manager daemon owning
## the login VT; ``sddm-greeter`` is the PAM-authenticated greeter
## binary it spawns as the login-screen UI; ``libSDDMCommon.so`` is
## the shared library both binaries link against for theme loading +
## display-server-handshake + session-launcher glue. NDE-K1's
## ``sddm.service`` ``ExecStart``s the daemon directly. The
## from-source recipe lifts the NDE-K1 apt-jammy sddm .deb pin to a
## real ``sddm`` daemon + ``sddm-greeter`` greeter + ``libSDDMCommon.so``
## library artifact for the v2 Plasma story.
##
## ## sha256 strategy
##
## We vendor the upstream 0.21.0 .tar.gz at
## ``recipes/packages/source/sddm/vendor/sddm-0.21.0.tar.gz`` and
## reference it via a ``file://`` URL. The github.com release URL is
## recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's
## emitted fetch action is offline-reproducible.
##
## ## Version choice — 0.21.0 (current upstream stable)
##
## SDDM releases on github.com under tags of the form ``v<x.y.z>``.
## The ``v0.21.0`` tag is the current stable as of mid-2026 and the
## first cut to ship Qt6 support out of the box (the Plasma 6.x line
## requires the Qt6 build); prior 0.20.x cuts targeted Qt5.
##
## sha256 = f895de2683627e969e4849dbfbbb2b500787481ca5ba0de6d6dfdae5f1549abf
##  (computed locally over the vendored ``sddm-0.21.0.tar.gz``,
##  3,557,266 bytes; downloaded once from the upstream URL recorded in
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
##   4. install/output collection actions for the executable + greeter
##      executable + library artifacts (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ninja-spawn + install glue lands in M9.L; the recipe
## records the artifacts via two ``executable`` blocks + one
## ``library`` block so the M9.K artifact registry already knows what
## binaries + shared object to expect.
##
## ## Artifacts
##
## sddm's CMake build emits two standalone binaries + one shared
## library:
##
##   * ``sddm`` — the long-running display-manager daemon owning the
##                 login VT; NDE-K1's ``sddm.service`` ``ExecStart``s
##                 this binary directly.
##   * ``sddm-greeter`` — the PAM-authenticated greeter binary the
##                         daemon spawns as the login-screen UI; runs
##                         as the unprivileged ``sddm`` system user,
##                         displays the login form, hands off to the
##                         user session on successful authentication.
##   * ``libSDDMCommon.so`` — the shared library both binaries link
##                              against for theme loading + display-
##                              server-handshake + session-launcher
##                              glue.
##
## We register the daemon under the package-level identifier ``sddm``
## (kept verbatim — already a single lowercase word), the greeter
## under ``sddmGreeter`` (camelCased from the hyphenated upstream
## binary name ``sddm-greeter`` per the gdk-pixbuf precedent), and
## the library under ``libSddmCommon`` (camelCased from the upstream
## SONAME ``SDDMCommon`` — preserving the leading ``lib`` prefix and
## reducing the SDDM acronym to the more conventional ``Sddm`` Pascal
## chunk to match the kwin/libKWin precedent of brand-conventional
## casing in artifact identifiers).
##
## ## Configurables
##
## v1 ships NO configurables — the CMake options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``BUILD_TESTING=OFF``     — skip the upstream test suite to keep
##                                  the build hermetic + fast.
##   * ``BUILD_MAN_PAGES=OFF``   — skip man-page generation (heavy
##                                  docbook/xsltproc dep surface, not
##                                  needed at runtime).
##   * ``ENABLE_JOURNALD=OFF``   — drop the systemd-journal logging
##                                  integration (NDE-K1's manifest
##                                  layer drives logging via stdout
##                                  + the systemd-user-session unit
##                                  Journald-capture upstream of
##                                  this binary).
##   * ``CMAKE_BUILD_TYPE=Release`` — release-mode optimisation;
##                                     matches the sibling from-source
##                                     recipes' ``--buildtype=release``
##                                     meson option.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a developer variant that
## flips ``BUILD_TESTING=ON`` for CI bundles, or a Journald-supporting
## variant that flips ``ENABLE_JOURNALD=ON`` for journal-aware logging
## bundles).

import std/[os, strutils]

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package sddmSource:
  ## From-source sddm — twenty-second M9.H/I/K production recipe and
  ## the CLOSING recipe in the Plasma stack batch. Fifth CMake-driven
  ## recipe after json-c + kcoreaddons + kwin + plasma-workspace, and
  ## the FIRST recipe in the suite to ship THREE artifacts (two
  ## executables + one library) from a single ``package`` macro.
  ##
  ## Tier-2b c_cpp_cmake convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``cmakeFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"cmake"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags. Two executables + one library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## github.com release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical GitHub project
    ## that hosts the sddm source tree.
    "0.21.0":
      sourceRevision = "v0.21.0"
      sourceUrl = "https://github.com/sddm/sddm/archive/refs/tags/v0.21.0.tar.gz"
      sourceRepository = "https://github.com/sddm/sddm"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 3,557,266-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://github.com/sddm/sddm/archive/refs/tags/v0.21.0.tar.gz"
    sha256: "f895de2683627e969e4849dbfbbb2b500787481ca5ba0de6d6dfdae5f1549abf"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver — the c_cpp_cmake convention's
    ## configure action invokes ``cmake -S <src> -B <build>``.
    ## sddm 0.21 requires cmake 3.16 for the modern Qt6 ``find_package``
    ## + ``add_library(... ALIAS ...)`` semantics.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux — the compile action
    ## invokes ``ninja`` (or ``cmake --build``) against the CMake build
    ## directory.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — sddm is C++17.
    "gcc >=11"

  buildDeps:
    ## qt6-base supplies QtCore / QtGui / QtDBus which the daemon +
    ## greeter consume for the base UI / D-Bus IPC surface. 6.6 is the
    ## minimum the sddm 0.21 line targets.
    "qt6-base >=6.6"
    ## M9.R.15f.6 — qt6-tools supplies lupdate / lrelease / qhelpgenerator
    ## tooling sddm's CMakeLists invoke (`find_package(Qt6 ...
    ## LinguistTools)`) at configure time for the translations build.
    "qt6-tools >=6.6"
    ## M9.R.15q.8.1 — qt6-declarative supplies QtQml + QtQuick which the
    ## QML-driven sddm greeter uses for its login-form UI surface.
    ## sddm's CMakeLists explicitly `find_package(Qt6 ... Qml Quick)`.
    "qt6-declarative >=6.6"
    ## pam is the authentication-stack library sddm's greeter consumes
    ## to authenticate logins against ``/etc/pam.d/sddm``.
    "pam >=1.5"
    ## M9.R.15q.8.1 — libxau supplies `xau.pc` which sddm's
    ## `pkg_check_modules(LIBXAU REQUIRED "xau")` probe consumes for
    ## the X11 authentication cookie generation in the greeter's
    ## display-server-handshake glue.
    "libxau >=1.0"
    ## M9.R.15q.8.4 — xorgproto supplies `xproto.pc` which `xau.pc`
    ## requires transitively (libxau's xau.pc declares
    ## `Requires: xproto`). Without xorgproto on PKG_CONFIG_PATH the
    ## libxau probe fails with "Package 'xproto', required by 'xau',
    ## not found".
    "xorgproto"
    ## M9.R.15q.8.1 — libxcb supplies XCB which sddm's
    ## `find_package(XCB REQUIRED)` consumes via ECM's `FindXCB.cmake`
    ## for the X11 display backend.
    "libxcb >=1.13"
    ## M9.R.15q.8.6 — libxdmcp supplies xdmcp.pc which libxcb.pc
    ## requires transitively (libxcb.pc declares
    ## `Requires.private: pthread-stubs xau xdmcp`).
    "libxdmcp"
    ## M9.R.15q.8.1 — libxkbcommon supplies XKB which sddm's
    ## `find_package(XKB REQUIRED)` consumes for keyboard layout
    ## handling in the greeter.
    "libxkbcommon >=1.0"

  config:
    ## No prefix lifted from `cmakeFlags:`; flags inlined in the `build:` block.
    discard
  executable sddm:
    ## ``/usr/bin/sddm`` — the long-running display-manager daemon
    ## owning the login VT. NDE-K1's ``sddm.service`` unit
    ## ``ExecStart``s this binary directly. v1 records the artifact
    ## only; the per-artifact build body lands in M9.L when the
    ## convention's ninja-spawn + install-glue closes.
    discard

  executable `sddm-greeter-qt6`:
    ## ``/usr/bin/sddm-greeter-qt6`` — the PAM-authenticated greeter
    ## binary sddm spawns as the login-screen UI; runs as the
    ## unprivileged ``sddm`` system user, displays the QML-driven
    ## login form, hands off to the user session on successful
    ## authentication.
    ##
    ## M9.R.15q.8.6 — the binary name is suffixed with the Qt major
    ## version (`sddm-greeter-qt6` under BUILD_WITH_QT6=ON, plain
    ## `sddm-greeter` under Qt5). sddm 0.21's
    ## ``src/greeter/CMakeLists.txt`` declares
    ## ``set(GREETER_TARGET sddm-greeter-qt${QT_MAJOR_VERSION})`` for
    ## the v2/Qt6 configuration. Recipe identifier matches the actual
    ## installed filename via the backticked quoted-form so the
    ## convention layer's stage-copy probe finds the executable at
    ## ``build/out/usr/bin/sddm-greeter-qt6``.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `cmake_package(...)` constructor.
    setCurrentOwningPackageOverride("sddmSource")
    try:
      let opts = @[
        # M9.R.15q.8.1 — sddm 0.21.0's top-level CMakeLists declares
        # `cmake_minimum_required(VERSION 3.0.2)`. CMake 4.x (the cache's
        # cmake-4.1.2) removed compatibility with CMake < 3.5 and
        # hard-errors at configure time. Set the policy-version-minimum
        # flag so the build proceeds against the modern CMake without
        # touching upstream sources.
        "CMAKE_POLICY_VERSION_MINIMUM=3.5",
        # M9.R.15q.8.6 — sddm 0.21's CMakeLists defaults to Qt5
        # (`option(BUILD_WITH_QT6 "Build with Qt 6" OFF)`); the
        # NDE-K1 v2 Plasma story requires Qt6, and the cache only
        # publishes qt6-base + qt6-tools + qt6-declarative (no Qt5).
        # Flip BUILD_WITH_QT6=ON so the find_package(Qt6 ...) probe
        # routes to the from-source Qt6 cache.
        "BUILD_WITH_QT6=ON",
        "BUILD_TESTING=OFF",
        "BUILD_MAN_PAGES=OFF",
        "ENABLE_JOURNALD=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      # M9.R.15q.8.2 — explicit PKG_CONFIG_PATH plumbing. sddm's
      # CMakeLists declares `pkg_check_modules(LIBXAU REQUIRED "xau")`
      # which consults pkg-config at configure time. The M9.R.14e
      # search-path channels populate PKG_CONFIG_PATH_FOR_TARGET via
      # the resolver but the cmake-bin configure action's actionEnv
      # has an empty pkgConfigSearchList (verified in
      # from-source-tool-identities.inspect.json) — the dep tool
      # identities have the right paths but they're not propagated to
      # the configure action's env.
      #
      # Threading the known-good paths explicitly via extraEnv mirrors
      # the kwin recipe's pattern (M9.R.15q.6.3): walk sibling source-
      # recipe install mirrors + glob /nix/store for libxau / libxcb /
      # libxkbcommon dev outputs supplied by the stdlib stubs.
      var pkgCfgDirs: seq[string] = @[]
      let recipeRoot = getEnv("REPROBUILD_RECIPE_ROOT",
        "/opt/repro/reprobuild/recipes/packages/source")
      # Sibling from-source pkg-config dirs.
      for sib in walkDir(recipeRoot, relative = false):
        if sib.kind == pcDir:
          let p = sib.path / ".repro" / "output" / "install" / "usr" / "lib" / "pkgconfig"
          if dirExists(p):
            pkgCfgDirs.add(p)
          let p64 = sib.path / ".repro" / "output" / "install" / "usr" / "lib64" / "pkgconfig"
          if dirExists(p64):
            pkgCfgDirs.add(p64)
          let pShare = sib.path / ".repro" / "output" / "install" / "usr" / "share" / "pkgconfig"
          if dirExists(pShare):
            pkgCfgDirs.add(pShare)
      # Nix-stub pkg-config dirs (libxau / libxcb dev outputs).
      # /nix/store is huge (~33k entries) so walkDir is prohibitively slow;
      # walkPattern only opens entries matching the glob.
      for store in walkPattern("/nix/store/*-libxau-*-dev"):
        if not dirExists(store): continue
        let pLib = store / "lib" / "pkgconfig"
        if dirExists(pLib):
          pkgCfgDirs.add(pLib)
      for store in walkPattern("/nix/store/*-libxcb-*-dev"):
        if not dirExists(store): continue
        let pLib = store / "lib" / "pkgconfig"
        if dirExists(pLib):
          pkgCfgDirs.add(pLib)
      # xcb-proto + libpthread-stubs are transitive deps of libxcb's .pc
      # (xcb-proto's "Requires" line references them via pcre/xcb-proto).
      for store in walkPattern("/nix/store/*-xcb-proto-*"):
        if not dirExists(store): continue
        let pLib = store / "lib" / "pkgconfig"
        if dirExists(pLib):
          pkgCfgDirs.add(pLib)
        let pShare = store / "share" / "pkgconfig"
        if dirExists(pShare):
          pkgCfgDirs.add(pShare)
      for store in walkPattern("/nix/store/*-libpthread-stubs-*"):
        if not dirExists(store): continue
        let pLib = store / "lib" / "pkgconfig"
        if dirExists(pLib):
          pkgCfgDirs.add(pLib)
      # libxdmcp ships xdmcp.pc which libxcb.pc requires transitively
      # (libxcb.pc declares "Requires.private: pthread-stubs xau xdmcp").
      # Without xdmcp on PKG_CONFIG_PATH the XCB find_package fails with
      # "Package 'xdmcp', required by 'xcb', not found".
      for store in walkPattern("/nix/store/*-libxdmcp-*-dev"):
        if not dirExists(store): continue
        let pLib = store / "lib" / "pkgconfig"
        if dirExists(pLib):
          pkgCfgDirs.add(pLib)
      # xorgproto ships xproto.pc which xau.pc requires transitively
      # (libxau-1.0.12/xau.pc: "Requires: xproto"). Without xorgproto on
      # PKG_CONFIG_PATH, pkg_check_modules(LIBXAU REQUIRED "xau") fails
      # with "Package 'xproto', required by 'xau', not found".
      for store in walkPattern("/nix/store/*-xorgproto-*"):
        let n = extractFilename(store)
        if n.endsWith(".drv") or n.endsWith(".tar.xz"):
          continue
        if not dirExists(store): continue
        let pShare = store / "share" / "pkgconfig"
        if dirExists(pShare):
          pkgCfgDirs.add(pShare)
        let pLib = store / "lib" / "pkgconfig"
        if dirExists(pLib):
          pkgCfgDirs.add(pLib)
      let pkgCfgPath = pkgCfgDirs.join(":")
      let env = @[
        ("PKG_CONFIG_PATH_FOR_TARGET", pkgCfgPath),
        ("PKG_CONFIG_PATH", pkgCfgPath),
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts,
                              extraEnv = env)
      discard pkg.executable("sddm")
      discard pkg.executable("sddm-greeter-qt6")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
