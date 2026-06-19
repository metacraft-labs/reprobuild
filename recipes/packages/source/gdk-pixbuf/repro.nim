## Source-from-tarball gdk-pixbuf recipe — the TWELFTH real from-source
## production recipe to exercise the M9.H/I/K trio
## (fetch: + mesonOptions: + convention-layer fetch-action emission).
##
## Follows the dbus-broker (executables only), libdrm (libraries only),
## Wayland (mixed), wlroots (single library), Sway (multiple
## executables), linux-kernel (executable + files), libxkbcommon
## (balanced 1+1), pixman (single library), libinput (name-collision
## 1+1), cairo (single library), and pango (two-library single-package)
## precedents: a meson/ninja build of upstream gdk-pixbuf fed by a
## vendored tarball whose sha256 is pinned here for deterministic
## offline test reproduction. gdk-pixbuf emits a SINGLE library
## artifact (``libgdk_pixbuf-2.0.so``) — the fourth single-library
## recipe (wlroots + pixman + cairo were the first three), exercising
## the package-identifier kebab-to-camel mapping shape
## (``gdk-pixbuf`` -> ``gdkPixbufSource``) against the M3 artifact
## registry's identifier hygiene.
##
## ## Why gdk-pixbuf matters for the NDE-H Sway / NDE-G1 GNOME / NDE-K1
## ## Plasma desktop stories
##
## gdk-pixbuf is the image-loading and pixel-buffer library underpinning
## GTK + GNOME's icon-loading and image-decode pipelines. It is a
## transitive dependency of every GTK-based desktop application and is
## consumed by sway's swaybg helper for wallpaper image decoding. The
## sibling ``swaySource`` recipe pins ``gdk-pixbuf >=2.40`` in its
## ``uses:`` block, so this recipe is the upstream-source side of that
## dependency edge.
##
## ## sha256 strategy
##
## We vendor the upstream 2.42.12 .tar.xz at
## ``recipes/packages/source/gdk-pixbuf/vendor/gdk-pixbuf-2.42.12.tar.xz``
## and reference it via a ``file://`` URL. The download.gnome.org
## release URL is recorded as ``sourceUrl`` in the ``versions:`` block
## for documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's
## emitted fetch action is offline-reproducible.
##
## ## Version choice — 2.42.12 (current upstream stable)
##
## download.gnome.org publishes gdk-pixbuf releases at
## ``https://download.gnome.org/sources/gdk-pixbuf/`` and 2.42.12 is
## the current stable in the 2.42.x line as of mid-2026. The
## gdk-pixbuf ABI has been stable since the 2.40 cut — anything
## ``>=2.40`` covers the sway consumption.
##
## sha256 = b9505b3445b9a7e48ced34760c3bcb73e966df3ac94c95a148cb669ab748e3c7
##  (computed locally over the vendored ``gdk-pixbuf-2.42.12.tar.xz``,
##  6,525,072 bytes; downloaded once from the upstream URL recorded
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
## gdk-pixbuf's meson build emits a single shared library
## (``libgdk_pixbuf-2.0.so``) bundling the pixbuf core + the built-in
## image-format loaders (PNG, JPEG, ICO, BMP, GIF, ANI, PNM, QTIF,
## TGA, TIFF, XBM, XPM). Additional loaders are emitted as plug-in
## ``.so`` modules in ``loaders/`` and are loaded at runtime via the
## ``gdk-pixbuf-loaders.cache`` — they are NOT registered as separate
## artifacts because they are content-addressed plug-ins discovered
## at install time, not link-time dependencies of the v1 desktop story.
##
## We register the artifact under the package-level identifier
## ``libgdkPixbuf`` (the ``-2.0`` ABI-version suffix is stripped and
## the underscore in the SONAME is camelCased to stay within Nim
## identifier conventions, matching the pixman / pango precedents).
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``tests=false``           — skip the upstream test suite to
##                                  keep the build hermetic + fast.
##   * ``man=false``             — skip man-page generation.
##   * ``gtk_doc=false``         — skip gtk-doc HTML generation.
##   * ``introspection=disabled`` — skip GObject Introspection (drops
##                                   the g-ir-scanner toolchain dep
##                                   the v1 desktop story doesn't
##                                   exercise).
##   * ``--buildtype=release``   — release-mode optimisation; matches
##                                  the sibling from-source recipes.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a developer variant that
## flips introspection on for GNOME-shell developer bundles).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package gdkPixbufSource:
  ## From-source gdk-pixbuf — twelfth M9.H/I/K production recipe.
  ##
  ## Tier-2b c_cpp_meson convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``mesonOptions:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"meson"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags. Single library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.gnome.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream GNOME gitlab
    ## project --- gdk-pixbuf's canonical home post-freedesktop-migration.
    "2.42.12":
      sourceRevision = "2.42.12"
      sourceUrl = "https://download.gnome.org/sources/gdk-pixbuf/2.42/gdk-pixbuf-2.42.12.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/gdk-pixbuf"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 6,525,072-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/gdk-pixbuf/vendor/gdk-pixbuf-2.42.12.tar.xz"
    sha256: "b9505b3445b9a7e48ced34760c3bcb73e966df3ac94c95a148cb669ab748e3c7"
    extractStrip: 1

  nativeBuildDeps:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``. gdk-pixbuf 2.42
    ## requires meson 0.62 for the upstream build's option semantics.
    "meson >=0.62"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — gdk-pixbuf is plain C99 with
    ## light use of GLib-style autoconf macros via meson's gnome
    ## module.
    "gcc >=7"

  buildDeps:
    ## glib provides GObject + GIO that gdk-pixbuf's loader objects
    ## subclass; gdk-pixbuf is a GObject library at heart.
    "glib >=2.62"
    ## libpng is required for the PNG loader (the most-used image
    ## format on the v1 desktop story).
    "libpng >=1.6"
    ## libjpeg is required for the JPEG loader.
    "libjpeg >=2.0"
    ## libtiff is required for the TIFF loader.
    "libtiff >=4.0"
    ## shared-mime-info is the runtime MIME-database gdk-pixbuf
    ## consumes to dispatch loaders by MIME type.
    "shared-mime-info >=2.0"

  mesonOptions:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: meson evaluates options
    ## left-to-right and the ``--buildtype=release`` sentinel lives at
    ## the tail so any override (e.g. a future debug-build variant)
    ## can append ``--buildtype=debug`` later without re-ordering this
    ## block.
    ##
    ## ``tests=false`` skips the upstream test suite to keep the
    ## build hermetic + fast.
    ## ``man=false`` skips man-page generation.
    ## ``gtk_doc=false`` skips gtk-doc HTML generation.
    ## ``introspection=disabled`` skips GObject Introspection (drops
    ## the g-ir-scanner toolchain dep).
    "-Dtests=false"
    "-Dman=false"
    "-Dgtk_doc=false"
    "-Dintrospection=disabled"
    "--buildtype=release"

  library libgdkPixbuf:
    ## ``libgdk_pixbuf-2.0.so`` — the image-loading + pixel-buffer
    ## library consumed by GTK / GNOME shell / swaybg. v1 records
    ## the artifact only; the per-artifact build body lands in M9.L
    ## when the convention's ninja-spawn + install-glue closes.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
