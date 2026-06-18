## Source-from-tarball harfbuzz recipe — the TWENTY-FOURTH real from-
## source production recipe to exercise the M9.H/I/K trio
## (fetch: + mesonOptions: + convention-layer fetch-action emission).
##
## Prior twenty-three from-source recipes — fifteen meson (dbus-broker,
## libdrm, wayland, wlroots, sway, libxkbcommon, pixman, libinput, cairo,
## pango, gdk-pixbuf, glib2, mutter, gnome-shell, freetype's sibling
## landed earlier this batch as autotools), one make (linux-kernel),
## five CMake (json-c, kcoreaddons, kwin, plasma-workspace, sddm),
## three autotools (expat, gdm, freetype this batch) — collectively
## covered every M9.I flag-injection channel. harfbuzz returns to the
## meson channel exercising the same lowering on the OpenType
## TEXT-SHAPING engine that complements freetype's glyph rasteriser.
##
## ## Why harfbuzz matters for the v1 desktop story
##
## harfbuzz is the OpenType text-shaping engine the entire complex-
## script rendering pipeline depends on: pango drives harfbuzz for
## Arabic / Hebrew / Devanagari / CJK script segmentation + glyph
## substitution + positioning; cairo / GTK / Qt6 (via QtGui) /
## Firefox / Chromium all consume harfbuzz as the second leg of
## "freetype rasterises glyphs, harfbuzz arranges them". The sibling
## ``pangoSource`` recipe pins ``harfbuzz >=4.0`` in its ``uses:``
## block, so this recipe is the upstream-source side of that
## dependency edge.
##
## ## sha256 strategy
##
## We vendor the upstream 10.1.0 .tar.xz at
## ``recipes/packages/source/harfbuzz/vendor/harfbuzz-10.1.0.tar.xz``
## and reference it via a ``file://`` URL. The github.com release URL
## is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 10.1.0 (current upstream stable)
##
## harfbuzz GitHub releases are at
## ``https://github.com/harfbuzz/harfbuzz/releases/`` and 10.1.0 is
## the current stable in the 10.x line as of mid-2026. The harfbuzz
## ABI compatibility has been very stable since the 2.x line — anything
## ``>=4.0`` covers pango consumption.
##
## sha256 = 6ce3520f2d089a33cef0fc48321334b8e0b72141f6a763719aaaecd2779ecb82
##  (computed locally over the vendored ``harfbuzz-10.1.0.tar.xz``,
##  17,922,136 bytes; downloaded once from the upstream URL recorded in
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
## records the library artifact via the ``library`` block so the M9.K
## artifact registry already knows what shared object to expect.
##
## ## Library artifact
##
## harfbuzz's meson build emits a primary shared library
## (``libharfbuzz.so``) bundling the OpenType layout + shaper + script
## + Unicode tables. We register the artifact under the package-level
## identifier ``libHarfbuzz`` (camelCased to follow the expat /
## freetype / gdk-pixbuf precedent of camelCasing the package-level
## artifact identifier).
##
## We intentionally do NOT register the auxiliary
## ``libharfbuzz-subset.so`` (font subsetting helper) or
## ``libharfbuzz-icu.so`` (ICU script-data adapter; we disable ICU
## anyway via ``-Dicu=disabled``) — the v1 desktop story consumes only
## the core shaping library through pango.
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``tests=disabled``         — skip the upstream test suite to
##                                   keep the build hermetic + fast.
##   * ``introspection=disabled`` — skip GObject Introspection (drops
##                                   the g-ir-scanner toolchain dep
##                                   the v1 desktop story doesn't
##                                   exercise; pango consumes harfbuzz
##                                   directly, not via gobject).
##   * ``docs=disabled``          — skip the gtk-doc HTML generation.
##   * ``gobject=disabled``       — skip the optional GObject wrapper
##                                   layer (pango uses harfbuzz's C
##                                   API directly).
##   * ``icu=disabled``           — skip the ICU script-data adapter
##                                   (harfbuzz bundles its own
##                                   Unicode tables which are
##                                   sufficient for pango's needs).
##   * ``--buildtype=release``    — release-mode optimisation; matches
##                                   the sibling from-source recipes.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a variant that flips
## ``-Dicu=enabled`` for legacy CJK bundles).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package harfbuzzSource:
  ## From-source harfbuzz — twenty-fourth M9.H/I/K production recipe.
  ## The OpenType text-shaping engine that complements freetype's glyph
  ## rasteriser; pango / cairo / GTK / Qt / browsers all consume it.
  ##
  ## Tier-2b c_cpp_meson convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``mesonOptions:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"meson"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right URL +
  ## hash + flags. Single library artifact recipe.

  defaultToolProvisioning "path"

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## github.com release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical GitHub project
    ## that hosts the harfbuzz source tree.
    "10.1.0":
      sourceRevision = "10.1.0"
      sourceUrl = "https://github.com/harfbuzz/harfbuzz/releases/download/10.1.0/harfbuzz-10.1.0.tar.xz"
      sourceRepository = "https://github.com/harfbuzz/harfbuzz"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network is
    ## unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 17,922,136-byte tarball
    ## downloaded once from the upstream URL recorded in ``versions:``
    ## above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/harfbuzz/vendor/harfbuzz-10.1.0.tar.xz"
    sha256: "6ce3520f2d089a33cef0fc48321334b8e0b72141f6a763719aaaecd2779ecb82"
    extractStrip: 1

  uses:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``. harfbuzz 10.x requires
    ## meson 0.55 for the modern option semantics.
    "meson >=0.55"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — harfbuzz is C++11 with light
    ## use of C++17 features in the OT layout layer.
    "gcc >=11"
    ## glib is consumed for the GObject wrapper (disabled) AND for the
    ## ``g_uchar_*`` helpers in non-gobject builds; meson can probe it
    ## via pkg-config even when gobject=disabled.
    "glib >=2.62"
    ## freetype is the glyph rasteriser harfbuzz consumes for the
    ## ``hb-ft.h`` FreeType integration layer (the canonical pairing
    ## downstream consumers go through). The sibling ``freetypeSource``
    ## recipe vendors 2.13.3 to match the >=2.10 floor.
    "freetype >=2.10"

  mesonOptions:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: meson evaluates options
    ## left-to-right and the ``--buildtype=release`` sentinel lives at
    ## the tail so any override (e.g. a future debug-build variant)
    ## can append ``--buildtype=debug`` later without re-ordering this
    ## block.
    ##
    ## ``tests=disabled`` skips the upstream test suite.
    ## ``introspection=disabled`` skips GObject Introspection.
    ## ``docs=disabled`` skips the gtk-doc HTML generation.
    ## ``gobject=disabled`` skips the optional GObject wrapper.
    ## ``icu=disabled`` skips the ICU script-data adapter.
    "-Dtests=disabled"
    "-Dintrospection=disabled"
    "-Ddocs=disabled"
    "-Dgobject=disabled"
    "-Dicu=disabled"
    "--buildtype=release"

  library libHarfbuzz:
    ## ``libharfbuzz.so`` — the OpenType layout + shaper + script +
    ## Unicode-tables core library. pango / cairo / GTK / Qt6 /
    ## Firefox / Chromium all link this transitively for complex-script
    ## text shaping. v1 records the artifact only; the per-artifact
    ## build body lands in M9.L when the convention's ninja-spawn +
    ## install-glue closes.
    discard
