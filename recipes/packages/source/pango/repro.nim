## Source-from-tarball pango recipe — the ELEVENTH real from-source
## production recipe to exercise the M9.H/I/K trio
## (fetch: + mesonOptions: + convention-layer fetch-action emission).
##
## Follows the dbus-broker (executables only), libdrm (libraries only),
## Wayland (mixed), wlroots (single library), Sway (multiple
## executables), linux-kernel (executable + files), libxkbcommon
## (balanced 1+1), pixman (single library), libinput (name-collision
## 1+1), and cairo (single library) precedents: a meson/ninja build
## of upstream pango fed by a vendored tarball whose sha256 is pinned
## here for deterministic offline test reproduction. pango emits TWO
## library artifacts (``libpango-1.0.so`` + ``libpangocairo-1.0.so``)
## — the first multi-library single-package shape in the from-source
## corpus where both artifacts share the same SONAME prefix but ship
## distinct ABIs (pango core vs pango cairo-surface binding).
##
## ## Why pango matters for the NDE-H Sway / NDE-G1 GNOME / NDE-K1
## ## Plasma desktop stories
##
## pango is the text-layout and font-rendering library underpinning
## GTK + GNOME's text-shaping pipeline. The sibling ``swaySource``
## recipe pins ``pango >=1.50`` in its ``uses:`` block via its
## swaybar / swaybg / sway-status helpers that render text via the
## pangocairo surface binding, so this recipe is the upstream-source
## side of that dependency edge. Mutter (GNOME) and most modern GUI
## toolkits also link against pango.
##
## ## sha256 strategy
##
## We vendor the upstream 1.54.0 .tar.xz at
## ``recipes/packages/source/pango/vendor/pango-1.54.0.tar.xz`` and
## reference it via a ``file://`` URL. The download.gnome.org release
## URL is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's
## emitted fetch action is offline-reproducible.
##
## ## Version choice — 1.54.0 (current upstream stable)
##
## download.gnome.org publishes pango releases at
## ``https://download.gnome.org/sources/pango/`` and 1.54.0 is the
## current stable in the 1.54.x line as of mid-2026. The pango ABI
## has been stable for years — anything ``>=1.50`` covers the sway
## consumption.
##
## sha256 = 8a9eed75021ee734d7fc0fdf3a65c3bba51dfefe4ae51a9b414a60c70b2d1ed8
##  (computed locally over the vendored ``pango-1.54.0.tar.xz``,
##  1,963,180 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
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
##   4. install/output collection actions for the library artifacts
##      (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ninja-spawn + install glue lands in M9.L; the recipe
## records both library artifacts via the ``library`` blocks so the
## M9.K artifact registry already knows what shared objects to expect.
##
## ## Library artifacts
##
## pango's meson build emits two shared libraries that the v1 desktop
## story consumes:
##
##   * ``libpango-1.0.so``       — the core text-layout + font + script
##                                  + bidi engine.
##   * ``libpangocairo-1.0.so``  — the pango/cairo surface binding
##                                  that lets cairo surfaces render
##                                  pango layouts; consumed by
##                                  swaybar / GTK / GNOME shell.
##
## We intentionally do NOT register the auxiliary
## ``libpangoft2-1.0.so`` (FreeType-only backend without cairo) —
## consumers we care about always go through pangocairo.
##
## We register the artifacts under the package-level identifiers
## ``libpango`` and ``libpangocairo`` (the ``-1.0`` ABI-version suffix
## is stripped to stay within Nim identifier conventions, matching
## the pixman precedent of ``libpixman1`` -> ``libpixman-1.so``).
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``introspection=disabled`` — skip GObject Introspection (drops
##                                   the g-ir-scanner toolchain dep
##                                   the v1 desktop story doesn't
##                                   exercise).
##   * ``gtk_doc=false``          — skip gtk-doc HTML generation.
##   * ``man-pages=false``        — skip man-page generation.
##   * ``build-testsuite=false``  — skip the upstream test suite to
##                                   keep the build hermetic + fast.
##   * ``--buildtype=release``    — release-mode optimisation; matches
##                                   the sibling from-source recipes.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a developer variant that
## flips introspection on for GNOME-shell developer bundles).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package pangoSource:
  ## From-source pango — eleventh M9.H/I/K production recipe.
  ##
  ## Tier-2b c_cpp_meson convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``mesonOptions:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"meson"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags. Two-library single-package recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.gnome.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream GNOME gitlab
    ## project --- pango's canonical home post-freedesktop-migration.
    "1.54.0":
      sourceRevision = "1.54.0"
      sourceUrl = "https://download.gnome.org/sources/pango/1.54/pango-1.54.0.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/pango"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 1,963,180-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/pango/vendor/pango-1.54.0.tar.xz"
    sha256: "8a9eed75021ee734d7fc0fdf3a65c3bba51dfefe4ae51a9b414a60c70b2d1ed8"
    extractStrip: 1

  nativeBuildDeps:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``. pango 1.54 requires
    ## meson 0.64 for the upstream build's option semantics.
    "meson >=0.64"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — pango is plain C99 with light
    ## use of GLib-style autoconf macros via meson's gnome module.
    "gcc >=7"

  buildDeps:
    ## glib provides GObject + GIO that pango's text-layout objects
    ## subclass; pango is a GObject library at heart.
    "glib >=2.62"
    ## harfbuzz is the OpenType text-shaping engine pango drives for
    ## script + bidi handling.
    "harfbuzz >=4.0"
    ## fribidi is the Unicode bidi-algorithm implementation pango
    ## consumes for RTL/LTR run-segmentation.
    "fribidi >=1.0"
    ## freetype is the font-glyph rasteriser pango's FreeType backend
    ## consumes.
    "freetype >=2.10"
    ## fontconfig is the font-discovery + matching layer pango's
    ## font backend consumes to resolve font families to file paths.
    "fontconfig >=2.13"
    ## cairo is the surface library the pangocairo binding emits to
    ## (and the sibling ``cairoSource`` recipe is the upstream-source
    ## side of that edge).
    "cairo >=1.16"

  config:
    ## No prefix lifted from `mesonOptions:`; flags inlined in the `build:` block.
    discard
  library libpango:
    ## ``libpango-1.0.so`` — the core text-layout + font + script +
    ## bidi engine consumed by GTK / GNOME shell / swaybar's text
    ## helpers. v1 records the artifact only; the per-artifact build
    ## body lands in M9.L when the convention's ninja-spawn +
    ## install-glue closes.
    discard

  library libpangocairo:
    ## ``libpangocairo-1.0.so`` — the pango/cairo surface binding that
    ## lets cairo surfaces render pango layouts; the sibling
    ## ``cairoSource`` recipe is the upstream-source side of this
    ## edge. v1 records the artifact only.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `meson_package(...)` constructor.
    setCurrentOwningPackageOverride("pangoSource")
    try:
      let opts = @[
        "-Dintrospection=disabled",
        "-Dgtk_doc=false",
        "-Dman-pages=false",
        "-Dbuild-testsuite=false",
        "--buildtype=release",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libpango")
      discard pkg.library("libpangocairo")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
