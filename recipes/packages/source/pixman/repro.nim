## Source-from-tarball pixman recipe — the EIGHTH real from-source
## production recipe to exercise the M9.H/I/K trio
## (fetch: + mesonOptions: + convention-layer fetch-action emission).
##
## Follows the dbus-broker (executables only), libdrm (libraries only),
## Wayland (mixed), wlroots (single library), Sway (multiple
## executables), linux-kernel (executable + files), and libxkbcommon
## (balanced 1+1) precedents: a meson/ninja build of upstream pixman
## fed by a vendored tarball whose sha256 is pinned here for
## deterministic offline test reproduction. pixman emits a SINGLE
## library artifact (``libpixman-1.so``) — the second single-library
## recipe (wlroots was the first), exercising the minimal artifact
## shape against a different upstream + meson option set.
##
## ## Why pixman matters for the NDE-H Sway / NDE-G1 GNOME / NDE-K1
## ## Plasma desktop stories
##
## pixman is the 2D pixel-manipulation library every modern Wayland
## compositor consumes for software-renderer fallback + scene-graph
## damage tracking. The sibling ``wlrootsSource`` recipe pins
## ``pixman >=0.42`` in its ``uses:`` block, so this recipe is the
## upstream-source side of that dependency edge. Cairo, X11 servers,
## and many image-processing toolkits also link against pixman, but
## the v1 desktop story is anchored on the wlroots consumption.
##
## ## sha256 strategy
##
## We vendor the upstream 0.46.4 .tar.gz at
## ``recipes/packages/source/pixman/vendor/pixman-0.46.4.tar.gz`` and
## reference it via a ``file://`` URL. The upstream cairographics.org
## release URL is recorded as ``sourceUrl`` in the ``versions:`` block
## for documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's
## emitted fetch action is offline-reproducible.
##
## ## Version choice — 0.46.4 (current upstream stable)
##
## cairographics.org publishes pixman releases at
## ``https://www.cairographics.org/releases/`` and 0.46.4 is the
## current stable as of mid-2026. The pixman ABI has been stable for
## decades — anything ``>=0.42`` covers the wlroots consumption — so
## tracking current stable is straightforward.
##
## sha256 = d09c44ebc3bd5bee7021c79f922fe8fb2fb57f7320f55e97ff9914d2346a591c
##  (computed locally over the vendored ``pixman-0.46.4.tar.gz``,
##  827,198 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_meson convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``mesonOptions:`` block off this package's
## registries and lowers them into:
##
##   1. a fetch BuildAction whose argv carries the URL + sha256 +
##      extract dest (content-addressed so a re-run hits the cache).
##   2. a ``meson setup`` configure BuildAction that depends on the
##      fetch action and passes every flag in ``mesonOptions:`` to
##      ``meson setup``, in declared order.
##   3. a ``ninja`` compile BuildAction (M9.L).
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
## pixman's meson build emits a single shared library
## (``libpixman-1.so``) bundling all 2D-pixel-manipulation
## fastpaths. The per-arch SIMD code (SSE2, NEON, AVX2) and the
## software-blit fastpaths are auto-detected at build time and link
## into the same .so. No per-arch artifact split.
##
## We register the artifact under the package-level identifier
## ``libpixman1`` (matching the ``libpixman-1.so`` SONAME upstream
## ships with — the ``-1`` is part of the ABI versioning convention,
## not a separate artifact).
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``tests=disabled``   — skip the upstream test suite to keep
##                            the build hermetic + fast (matches the
##                            other from-source siblings).
##   * ``demos=disabled``   — skip the demo applications
##                            (``radial-test`` et al); not consumed
##                            at runtime by any downstream package.
##   * ``--buildtype=release`` — release-mode optimisation; matches
##                              the sibling from-source recipes.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a developer variant that
## flips tests on for upstream contributions).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package pixmanSource:
  ## From-source pixman — eighth M9.H/I/K production recipe.
  ##
  ## Tier-2b c_cpp_meson convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``mesonOptions:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"meson"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags. Single library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## cairographics.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream cairographics.org
    ## gitlab project --- pixman's canonical home.
    "0.46.4":
      sourceRevision = "pixman-0.46.4"
      sourceUrl = "https://www.cairographics.org/releases/pixman-0.46.4.tar.gz"
      sourceRepository = "https://gitlab.freedesktop.org/pixman/pixman"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 827,198-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/pixman/vendor/pixman-0.46.4.tar.gz"
    sha256: "d09c44ebc3bd5bee7021c79f922fe8fb2fb57f7320f55e97ff9914d2346a591c"
    extractStrip: 1

  nativeBuildDeps:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``.
    "meson >=0.59"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — pixman is plain C99 with
    ## per-arch SIMD intrinsics.
    "gcc >=7"

  config:
    ## No prefix lifted from `mesonOptions:`; flags inlined in the `build:` block.
    discard
  library libpixman1:
    ## ``libpixman-1.so`` — the 2D pixel-manipulation library used by
    ## wlroots' software renderer + scene-graph damage tracking and
    ## by Cairo / X11 server. The ``-1`` is the ABI-version suffix
    ## upstream maintains; we record the artifact as ``libpixman1``
    ## (no dash) to stay within Nim identifier conventions.
    ## v1 records the artifact only; the per-artifact build body
    ## lands in M9.L when the convention's ninja-spawn + install-glue
    ## closes.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `meson_package(...)` constructor.
    setCurrentOwningPackageOverride("pixmanSource")
    try:
      let opts = @[
        "-Dtests=disabled",
        "-Ddemos=disabled",
        "--buildtype=release",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libpixman1")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
