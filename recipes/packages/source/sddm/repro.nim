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
    url: "file:///metacraft/reprobuild/recipes/packages/source/sddm/vendor/sddm-0.21.0.tar.gz"
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
    ## qt6-base supplies QtCore / QtGui / QtQml / QtQuick which the
    ## QML-driven sddm greeter uses for its login-form UI surface.
    ## 6.6 is the minimum the sddm 0.21 line targets.
    "qt6-base >=6.6"
    ## pam is the authentication-stack library sddm's greeter consumes
    ## to authenticate logins against ``/etc/pam.d/sddm``.
    "pam >=1.5"

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

  executable sddmGreeter:
    ## ``/usr/lib/sddm/sddm-greeter`` — the PAM-authenticated greeter
    ## binary sddm spawns as the login-screen UI; runs as the
    ## unprivileged ``sddm`` system user, displays the QML-driven
    ## login form, hands off to the user session on successful
    ## authentication. The hyphenated upstream binary name
    ## ``sddm-greeter`` is camelCased to ``sddmGreeter`` per the
    ## gdk-pixbuf precedent.
    discard

  library libSddmCommon:
    ## ``libSDDMCommon.so`` — the shared library both binaries link
    ## against for theme loading + display-server-handshake +
    ## session-launcher glue. The upstream SONAME ``SDDMCommon`` is
    ## camelCased to ``libSddmCommon`` — preserving the leading
    ## ``lib`` prefix and reducing the SDDM acronym to ``Sddm`` to
    ## match the kwin/libKWin precedent of brand-conventional casing
    ## in artifact identifiers.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `cmake_package(...)` constructor.
    setCurrentOwningPackageOverride("sddmSource")
    try:
      let opts = @[
        "-DBUILD_TESTING=OFF",
        "-DBUILD_MAN_PAGES=OFF",
        "-DENABLE_JOURNALD=OFF",
        "-DCMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.executable("sddm")
      discard pkg.executable("sddmGreeter")
      discard pkg.library("libSddmCommon")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
