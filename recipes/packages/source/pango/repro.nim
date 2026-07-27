## Source-from-tarball pango recipe — the eleventh real from-source
## production recipe in the package corpus.
##
## Follows the dbus-broker (executables only), libdrm (libraries only),
## Wayland (mixed), wlroots (single library), Sway (multiple
## executables), linux-kernel (executable + files), libxkbcommon
## (balanced 1+1), pixman (single library), libinput (name-collision
## 1+1), and cairo (single library) precedents: a meson/ninja build
## of upstream pango fed by the canonical GNOME release tarball whose
## sha256 is pinned here. The content-addressed source cache makes
## subsequent builds independent of the network. pango emits TWO
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
## The ``versions:`` and live ``fetch:`` blocks both record the
## canonical download.gnome.org release URL. The fetch action verifies
## the exact upstream digest before extraction, and the
## content-addressed cache permits offline reuse after the source has
## been materialised once.
##
## ## Version choice - 1.56.4
##
## download.gnome.org publishes pango releases at
## ``https://download.gnome.org/sources/pango/``. The pango ABI
## has been stable for years — anything ``>=1.50`` covers the sway
## consumption.
##
## sha256 = 17065e2fcc5f5a5bdbffc884c956bfc7c451a96e8c4fb2f8ad837c6413cb5a01
##  (published alongside ``pango-1.56.4.tar.xz`` in GNOME's
##  ``pango-1.56.4.sha256sum``; independently verified over the
##  1,883,988-byte release payload).
##
## ## Build shape
##
## The package macro records the ``fetch:`` block, while the explicit
## ``build:`` body calls the typed ``meson_package`` constructor. They
## lower into:
##
##   1. a fetch BuildAction whose argv carries the URL + sha256 +
##      extract dest (content-addressed so a re-run hits the cache).
##   2. a typed ``meson setup`` BuildAction that depends on the fetch
##      action and passes every hardcoded option in declared order.
##   3. a ``meson compile`` BuildAction.
##   4. install/output collection actions for the library artifacts
##      emitted by ``meson_package``.
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
##   * ``introspection=enabled``  — emit the GIRs and typelibs needed
##                                   by GTK and GNOME Shell.
##   * ``documentation=false``    — skip documentation generation.
##   * ``build-testsuite=false``  — skip the upstream test suite to
##                                   keep the build hermetic + fast.
##
## ``meson_package`` also supplies its standard release build type.
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
  ## From-source pango recipe with two library artifacts.
  ##
  ## The registered ``fetch:`` pin feeds the explicit package-level
  ## ``build:`` body, whose typed ``meson_package`` call emits the
  ## configure, compile, and install actions.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.gnome.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream. The
    ## live ``fetch:`` block below uses the same canonical URL and
    ## checksum; the content-addressed cache supports offline reuse
    ## after the first successful materialisation.
    ##
    ## ``sourceRepository`` points at the upstream GNOME gitlab
    ## project --- pango's canonical home post-freedesktop-migration.
    "1.56.4":
      sourceRevision = "1.56.4"
      sourceUrl = "https://download.gnome.org/sources/pango/1.56/pango-1.56.4.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/pango"

  fetch:
    ## Canonical upstream tarball. The convention layer carries this
    ## URL and its independently pinned digest verbatim, so the engine
    ## rejects source drift and reuses the content-addressed payload
    ## without network access after its first materialisation.
    ##
    ## GNOME publishes this sha256 beside the release tarball; it was
    ## also independently verified over the 1,883,988-byte payload.
    url: "https://download.gnome.org/sources/pango/1.56/pango-1.56.4.tar.xz"
    sha256: "17065e2fcc5f5a5bdbffc884c956bfc7c451a96e8c4fb2f8ad837c6413cb5a01"
    extractStrip: 1

  nativeBuildDeps:
    "gobject-introspection"
    ## meson is the build-system driver. Pango 1.56.4 declares
    ## ``meson_version: >=1.2.0`` in its upstream ``meson.build``.
    "meson >=1.2.0"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — pango is plain C99 with light
    ## use of GLib-style autoconf macros via meson's gnome module.
    "gcc >=7"
    ## python3 runs at meson-setup time for pango's various scriptlet
    ## helpers (glib's gnome module invokes python). Same pattern as
    ## glib2 / harfbuzz / cairo.
    "python3"

  buildDeps:
    "gobject-introspection"
    "glib2-introspection"
    ## glib2 provides GObject + GIO that pango's text-layout objects
    ## subclass; pango is a GObject library at heart. Recipe name
    ## ``glib2`` matches the sibling source recipe. Pango 1.56.4
    ## requires GLib 2.82.
    "glib2 >=2.82"
    ## harfbuzz is the OpenType text-shaping engine pango drives for
    ## script + bidi handling. The upstream minimum is 8.4.0.
    "harfbuzz >=8.4.0"
    ## fribidi is the Unicode bidi-algorithm implementation pango
    ## consumes for RTL/LTR run-segmentation. The upstream minimum is
    ## 1.0.6.
    "fribidi >=1.0.6"
    ## freetype is the font-glyph rasteriser pango's FreeType backend
    ## consumes.
    "freetype >=2.10"
    ## fontconfig is the font-discovery + matching layer pango's
    ## font backend consumes to resolve font families to file paths.
    ## The upstream minimum is 2.15.0.
    "fontconfig >=2.15.0"
    ## cairo is the surface library the pangocairo binding emits to
    ## (and the sibling ``cairoSource`` recipe is the upstream-source
    ## side of that edge). The upstream minimum is 1.18.0.
    "cairo >=1.18.0"

  config:
    ## No user-overridable values yet; options are explicit in ``build:``.
    discard
  library libpango:
    ## ``libpango-1.0.so`` — the core text-layout + font + script +
    ## bidi engine consumed by GTK / GNOME shell / swaybar's text
    ## helpers. The package build slices this artifact from the Meson
    ## install result.
    discard

  library libpangocairo:
    ## ``libpangocairo-1.0.so`` — the pango/cairo surface binding that
    ## lets cairo surfaces render pango layouts; the sibling
    ## ``cairoSource`` recipe is the upstream-source side of this
    ## edge. The package build slices this artifact from the Meson
    ## install result.
    discard

  build:
    ## Explicit package-level build with inlined options, using the
    ## high-level typed ``meson_package`` constructor.
    setCurrentOwningPackageOverride("pangoSource")
    try:
      let opts = @[
        # pango 1.54 renamed ``gtk_doc`` to ``documentation``
        # and dropped ``man-pages`` entirely (the man pages now live in
        # the documentation pipeline). Use the new option name; the
        # broader ``build-testsuite=false`` keeps the build minimal.
        "introspection=enabled",
        "documentation=false",
        "build-testsuite=false",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts,
        extraEnv = @[("GI_GIR_PATH",
          "/opt/repro/reprobuild/recipes/packages/source/glib2-introspection/.repro/output/install/usr/share/gir-1.0:" &
          "/opt/repro/reprobuild/recipes/packages/source/harfbuzz/.repro/output/install/usr/share/gir-1.0")])
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
