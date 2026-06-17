## Source-from-tarball cairo recipe — the TENTH real from-source
## production recipe to exercise the M9.H/I/K trio
## (fetch: + mesonOptions: + convention-layer fetch-action emission).
##
## Follows the dbus-broker (executables only), libdrm (libraries only),
## Wayland (mixed), wlroots (single library), Sway (multiple
## executables), linux-kernel (executable + files), libxkbcommon
## (balanced 1+1), pixman (single library), and libinput
## (library/executable name collision) precedents: a meson/ninja build
## of upstream cairo fed by a vendored tarball whose sha256 is pinned
## here for deterministic offline test reproduction. cairo emits a
## SINGLE library artifact (``libcairo.so``) — the third single-library
## recipe (wlroots + pixman were the first two), exercising the
## minimal artifact shape against a different upstream + meson option
## set.
##
## ## Why cairo matters for the NDE-H Sway / NDE-G1 GNOME / NDE-K1
## ## Plasma desktop stories
##
## cairo is the 2D vector-graphics library that underpins GTK's
## rendering and pango's text-shaping output surface. The sibling
## ``swaySource`` recipe pins ``cairo >=1.16`` in its ``uses:`` block
## via its swaybar / swaybg / sway-status helpers, so this recipe is
## the upstream-source side of that dependency edge. Mutter (GNOME)
## and most modern GUI toolkits also link against cairo.
##
## ## sha256 strategy
##
## We vendor the upstream 1.18.4 .tar.xz at
## ``recipes/packages/source/cairo/vendor/cairo-1.18.4.tar.xz`` and
## reference it via a ``file://`` URL. The upstream cairographics.org
## release URL is recorded as ``sourceUrl`` in the ``versions:`` block
## for documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's
## emitted fetch action is offline-reproducible.
##
## ## Version choice — 1.18.4 (current upstream stable)
##
## cairographics.org publishes cairo releases at
## ``https://www.cairographics.org/releases/`` and 1.18.4 is the
## current stable in the 1.18.x line as of mid-2026. The cairo ABI
## has been stable since 1.0 — anything ``>=1.16`` covers the sway
## consumption — so tracking current stable is straightforward.
##
## sha256 = 445ed8208a6e4823de1226a74ca319d3600e83f6369f99b14265006599c32ccb
##  (computed locally over the vendored ``cairo-1.18.4.tar.xz``,
##  32,578,804 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
##
## ## Tarball-size caveat — cairo 1.18 ships a large source tree
##
## At ~32 MB compressed, cairo-1.18.4 is the largest source tarball
## in the from-source corpus to date (the prior nine all sit between
## 0.8 MB and 12 MB). The tarball bundles test fixtures (~20 MB of
## reference-image .ref.png files under ``test/reference/``) that the
## ``-Dtests=disabled`` flag below skips at build time but cannot be
## stripped from the upstream source archive itself. This is the same
## tarball nixpkgs's ``pkgs/development/libraries/cairo/default.nix``
## consumes.
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
## cairo's meson build emits a single shared library
## (``libcairo.so``) bundling all 2D vector-graphics primitives. The
## per-backend code (image, png, ps, pdf, svg) and the font subsystem
## link into the same .so. We intentionally do NOT register the
## auxiliary ``libcairo-script-interpreter`` or ``libcairo-trace``
## libraries — neither is consumed by the v1 desktop story.
##
## We register the artifact under the package-level identifier
## ``libcairo`` (matching the ``libcairo.so`` SONAME upstream ships
## with).
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``tests=disabled``  — skip the upstream test suite (heaviest
##                            portion of the build, not needed at
##                            runtime; matches the other from-source
##                            siblings).
##   * ``xlib=disabled``   — skip the X11 native backend (the v1
##                            desktop story is pure-Wayland and the
##                            xlib backend pulls libX11 + libXrender
##                            into the dependency surface).
##   * ``xcb=disabled``    — skip the XCB native backend for the same
##                            reason as xlib (pulls libxcb +
##                            libxcb-render into the dependency
##                            surface; Wayland-only baseline).
##   * ``--buildtype=release`` — release-mode optimisation; matches
##                              the sibling from-source recipes.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. an X11-enabled variant
## for legacy desktop bundles).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package cairoSource:
  ## From-source cairo — tenth M9.H/I/K production recipe.
  ##
  ## Tier-2b c_cpp_meson convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``mesonOptions:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"meson"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags. Single library artifact recipe.

  defaultToolProvisioning "path"

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## cairographics.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream freedesktop.org
    ## gitlab project --- cairo's canonical home.
    "1.18.4":
      sourceRevision = "1.18.4"
      sourceUrl = "https://www.cairographics.org/releases/cairo-1.18.4.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/cairo/cairo"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 32,578,804-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/cairo/vendor/cairo-1.18.4.tar.xz"
    sha256: "445ed8208a6e4823de1226a74ca319d3600e83f6369f99b14265006599c32ccb"
    extractStrip: 1

  uses:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``. cairo 1.18 requires
    ## meson 0.64 for the ``--buildtype=release`` semantics it relies
    ## on.
    "meson >=0.64"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — cairo is C99 with light C++ in
    ## the test harness (skipped via ``-Dtests=disabled``).
    "gcc >=7"
    ## pixman is cairo's per-pixel software-rasteriser backend; the
    ## sibling ``pixmanSource`` recipe is the upstream-source side of
    ## this edge.
    "pixman >=0.42"
    ## freetype is the font-glyph rasteriser cairo's font backends
    ## consume.
    "freetype >=2.10"
    ## fontconfig is the font-discovery + matching layer cairo's
    ## font backends consume to resolve font families to file paths.
    "fontconfig >=2.13"
    ## zlib is required for PNG + PDF + PS backend compression.
    "zlib >=1.2"
    ## libpng is required for the image backend's PNG IO.
    "libpng >=1.6"

  mesonOptions:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: meson evaluates options
    ## left-to-right and the ``--buildtype=release`` sentinel lives at
    ## the tail so any override (e.g. a future debug-build variant)
    ## can append ``--buildtype=debug`` later without re-ordering this
    ## block.
    ##
    ## ``tests=disabled`` skips the upstream test suite (heaviest
    ## portion of the build, not needed at runtime).
    ## ``xlib=disabled`` skips the X11 native backend (Wayland-only
    ## baseline keeps the dependency surface tight).
    ## ``xcb=disabled`` skips the XCB native backend for the same
    ## reason as xlib.
    "-Dtests=disabled"
    "-Dxlib=disabled"
    "-Dxcb=disabled"
    "--buildtype=release"

  library libcairo:
    ## ``libcairo.so`` — the 2D vector-graphics library used by GTK,
    ## sway helpers (swaybar / swaybg), and pango's surface backends.
    ## v1 records the artifact only; the per-artifact build body
    ## lands in M9.L when the convention's ninja-spawn + install-glue
    ## closes.
    discard
