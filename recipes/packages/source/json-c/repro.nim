## Source-from-tarball json-c recipe — the THIRTEENTH real from-source
## production recipe to exercise the M9.H/I/K trio and the FIRST recipe
## to drive the ``cmakeFlags:`` channel instead of ``mesonOptions:``.
##
## Prior twelve from-source recipes (dbus-broker, libdrm, wayland,
## wlroots, sway, linux-kernel, libxkbcommon, pixman, libinput, cairo,
## pango, gdk-pixbuf) all use either ``mesonOptions:`` (eleven of them)
## or ``makeFlags:`` (the kernel). json-c is the first CMake-driven
## upstream in the recipe suite, so it pins the M9.I per-channel
## isolation property from the OPPOSITE side from the meson recipes: a
## regression that misroutes a CMake flag onto the meson channel would
## surface in the dedicated channel-isolation pin in
## ``test_json_c_source.nim``.
##
## ## Why json-c matters for the v1 desktop story
##
## json-c is a C JSON parser + serialiser library used by a wide swath
## of system-level tooling (e.g. swayipc helpers, sway's wallpaper-
## config helpers, NetworkManager, BlueZ, PolicyKit). It is a
## transitive dependency of every JSON-aware desktop component and is
## consumed by the sway ecosystem for IPC message construction. The
## sibling ``swaySource`` recipe pins ``json-c >=0.17`` in its
## ``uses:`` block (added when the desktop story closes), so this
## recipe is the upstream-source side of that dependency edge.
##
## ## sha256 strategy
##
## We vendor the upstream 0.18-20240915 .tar.gz at
## ``recipes/packages/source/json-c/vendor/json-c-0.18-20240915.tar.gz``
## and reference it via a ``file://`` URL. The github.com release URL
## is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's
## emitted fetch action is offline-reproducible.
##
## ## Version choice — 0.18-20240915 (current upstream stable)
##
## json-c releases are dated snapshots cut on the GitHub repository
## under tags of the form ``json-c-<api-version>-<YYYYMMDD>``. The
## ``0.18-20240915`` tag is the current stable in the 0.18.x line as
## of mid-2026 and the ABI is stable since the 0.17 cut — anything
## ``>=0.17`` covers the sway consumption.
##
## sha256 = 3112c1f25d39eca661fe3fc663431e130cc6e2f900c081738317fba49d29e298
##  (computed locally over the vendored
##  ``json-c-0.18-20240915.tar.gz``, 401,874 bytes; downloaded once
##  from the upstream URL recorded in ``versions:`` above).
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
##   4. install/output collection actions for the library artifact
##      (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ninja-spawn + install glue lands in M9.L; the recipe
## records the library artifact via the ``library`` block so the
## M9.K artifact registry already knows what shared object to expect.
##
## ## Library artifact
##
## json-c's CMake build emits a single shared library
## (``libjson-c.so``) bundling the JSON parser + writer + tree
## walker + tokener + utility helpers. We register the artifact under
## the package-level identifier ``libJsonC`` (the kebab-cased
## ``-c`` suffix is stripped from the artifact identifier and the
## camel-case mapping follows the gdk-pixbuf precedent of
## kebab-to-camel for ``json-c`` -> ``jsonCSource``).
##
## ## Configurables
##
## v1 ships NO configurables — the CMake options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``BUILD_SHARED_LIBS=ON``    — build the shared object (consumed
##                                    by sway helpers + NetworkManager
##                                    + BlueZ + PolicyKit).
##   * ``BUILD_STATIC_LIBS=OFF``   — skip the static archive (not used
##                                    by the v1 desktop story; cuts
##                                    build time + cache size).
##   * ``BUILD_TESTING=OFF``       — skip the upstream test suite to
##                                    keep the build hermetic + fast.
##   * ``BUILD_APPS=OFF``          — skip the bundled apps
##                                    (``json_parse`` + ``test_*``)
##                                    that are not needed at runtime.
##   * ``CMAKE_BUILD_TYPE=Release`` — release-mode optimisation;
##                                    matches the sibling from-source
##                                    recipes' ``--buildtype=release``
##                                    meson option.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a developer variant that
## flips ``BUILD_TESTING=ON`` for CI bundles).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package jsonCSource:
  ## From-source json-c — thirteenth M9.H/I/K production recipe and
  ## FIRST CMake-driven from-source recipe (every prior recipe used
  ## meson or make).
  ##
  ## Tier-2b c_cpp_cmake convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``cmakeFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"cmake"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags. Single library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## github.com release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical GitHub project
    ## that hosts the json-c source tree.
    "0.18-20240915":
      sourceRevision = "json-c-0.18-20240915"
      sourceUrl = "https://github.com/json-c/json-c/archive/refs/tags/json-c-0.18-20240915.tar.gz"
      sourceRepository = "https://github.com/json-c/json-c"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 401,874-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/json-c/vendor/json-c-0.18-20240915.tar.gz"
    sha256: "3112c1f25d39eca661fe3fc663431e130cc6e2f900c081738317fba49d29e298"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver — the c_cpp_cmake convention's
    ## configure action invokes ``cmake -S <src> -B <build>``.
    ## json-c 0.18 requires cmake 3.9 for the
    ## ``BUILD_SHARED_LIBS=ON`` + ``BUILD_STATIC_LIBS=OFF`` separation
    ## semantics (older CMake collapsed the two into one option).
    "cmake >=3.9"
    ## ninja is CMake's preferred backend on Linux — the compile
    ## action invokes ``ninja`` (or ``cmake --build``) against the
    ## CMake build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — json-c is plain C99.
    "gcc >=11"

  cmakeFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: CMake evaluates ``-D`` overrides
    ## left-to-right and the ``CMAKE_BUILD_TYPE=Release`` sentinel
    ## lives at the tail so any override (e.g. a future debug-build
    ## variant) can append ``-DCMAKE_BUILD_TYPE=Debug`` later without
    ## re-ordering this block.
    ##
    ## ``BUILD_SHARED_LIBS=ON`` builds the shared object consumed by
    ## sway helpers + NetworkManager + BlueZ + PolicyKit.
    ## ``BUILD_STATIC_LIBS=OFF`` skips the static archive (not used by
    ## the v1 desktop story).
    ## ``BUILD_TESTING=OFF`` skips the upstream test suite.
    ## ``BUILD_APPS=OFF`` skips the bundled apps.
    "-DBUILD_SHARED_LIBS=ON"
    "-DBUILD_STATIC_LIBS=OFF"
    "-DBUILD_TESTING=OFF"
    "-DBUILD_APPS=OFF"
    "-DCMAKE_BUILD_TYPE=Release"

  library libJsonC:
    ## ``libjson-c.so`` — the C JSON parser + serialiser consumed by
    ## the sway ecosystem (swayipc helpers), NetworkManager, BlueZ,
    ## PolicyKit, and a wide swath of system-level desktop tooling.
    ## v1 records the artifact only; the per-artifact build body
    ## lands in M9.L when the convention's ninja-spawn + install-glue
    ## closes.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
