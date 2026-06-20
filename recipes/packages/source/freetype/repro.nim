## Source-from-tarball freetype recipe — the TWENTY-THIRD real from-
## source production recipe to exercise the M9.H/I/K trio
## (fetch: + configureFlags: + convention-layer fetch-action emission).
##
## Prior twenty-two from-source recipes — fourteen meson (dbus-broker,
## libdrm, wayland, wlroots, sway, libxkbcommon, pixman, libinput, cairo,
## pango, gdk-pixbuf, glib2, mutter, gnome-shell), one make
## (linux-kernel), five CMake (json-c, kcoreaddons, kwin,
## plasma-workspace, sddm), two autotools (expat, gdm) — collectively
## covered every M9.I flag-injection channel. freetype is the THIRD
## autotools-driven recipe, joining expat + gdm as autotools exemplars
## and exercising the ``configureFlags:`` channel for the FONT-RENDERING
## foundation of the v1 desktop story.
##
## ## Why freetype matters for the v1 desktop story
##
## freetype is the font-glyph rasteriser the entire Linux desktop UI
## stack depends on: pango's font backend, fontconfig's font matcher,
## harfbuzz's complex-script shaper, cairo's font rendering, GTK +
## Qt + every browser. The sibling ``pangoSource`` recipe pins
## ``freetype >=2.10`` in its ``uses:`` block, so this recipe is the
## upstream-source side of that dependency edge. fontconfig + harfbuzz
## are the other immediate downstream consumers landing in the same
## batch.
##
## ## sha256 strategy
##
## We vendor the upstream 2.13.3 .tar.xz at
## ``recipes/packages/source/freetype/vendor/freetype-2.13.3.tar.xz``
## and reference it via a ``file://`` URL. The download.savannah.gnu.org
## release URL is recorded as ``sourceUrl`` in the ``versions:`` block
## for documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 2.13.3 (current upstream stable)
##
## savannah.gnu.org publishes freetype releases at
## ``https://download.savannah.gnu.org/releases/freetype/`` and 2.13.3
## is the current stable in the 2.13.x line as of mid-2026. The
## freetype ABI has been stable for many years — anything ``>=2.10``
## covers pango/harfbuzz/fontconfig consumption.
##
## sha256 = 0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289
##  (computed locally over the vendored ``freetype-2.13.3.tar.xz``,
##  2,617,564 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``configureFlags:`` block off this package's
## registries and lowers them into:
##
##   1. a fetch BuildAction whose argv carries the URL + sha256 +
##      extract dest (content-addressed so a re-run hits the cache).
##   2. a ``./configure`` BuildAction that depends on the fetch action
##      and passes every flag in ``configureFlags:`` to the upstream
##      configure script, in declared order.
##   3. a ``make`` compile BuildAction (M9.L).
##   4. install/output collection actions for the library artifact
##      (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ``make`` + install glue lands in M9.L; the recipe records
## the library artifact via the ``library`` block so the M9.K artifact
## registry already knows what shared object to expect.
##
## ## Library artifact
##
## freetype's autotools build emits a single shared library
## (``libfreetype.so``) bundling the TrueType / OpenType / Type1 /
## CFF / WOFF font-format loaders + the glyph rasteriser + the FreeType
## hinting / autohinting engine. We register the artifact under the
## package-level identifier ``libFreetype`` (camelCased to follow the
## expat / json-c / gdk-pixbuf precedent of camelCasing the
## package-level artifact identifier).
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``--disable-static``    — skip the static archive (not used by
##                                the v1 desktop story; cuts build time
##                                + cache size). Matches the
##                                ``BUILD_STATIC_LIBS=OFF`` json-c
##                                precedent and the expat
##                                ``--disable-static`` precedent.
##   * ``--without-zlib=auto`` — let the autotools probe decide whether
##                                to link the host zlib (used for WOFF
##                                font decompression); falls back to
##                                freetype's bundled zlib.
##   * ``--without-bzip2``     — skip the optional bzip2 dependency
##                                (only used for compressed PCF bitmap
##                                fonts which the v1 desktop story
##                                doesn't ship).
##   * ``--without-png=auto``  — let the autotools probe decide whether
##                                to link libpng (used for color-emoji
##                                bitmap fonts).
##   * ``--without-harfbuzz``  — break the freetype <-> harfbuzz
##                                dependency cycle (freetype is the
##                                LOWER layer; harfbuzz consumes
##                                freetype, not the other way around;
##                                only the optional auto-hinting
##                                feedback path uses harfbuzz which we
##                                disable here).
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a variant that flips
## ``--with-harfbuzz`` for advanced auto-hinting bundles).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package freetypeSource:
  ## From-source freetype — twenty-third M9.H/I/K production recipe and
  ## THIRD autotools-driven recipe (expat + gdm precedents). The font
  ## rasteriser foundation that pango / harfbuzz / fontconfig / cairo /
  ## every Linux UI toolkit links against.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right URL +
  ## hash + flags. Single library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.savannah.gnu.org release tarball URL so a future
    ## maintainer running ``repro update-source`` can re-fetch from
    ## upstream; the live ``fetch:`` block below points at the vendored
    ## copy for deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream savannah.nongnu.org
    ## git mirror — freetype's canonical home.
    "2.13.3":
      sourceRevision = "VER-2-13-3"
      sourceUrl = "https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/freetype/freetype"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network is
    ## unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 2,617,564-byte tarball
    ## downloaded once from the upstream URL recorded in ``versions:``
    ## above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/freetype/vendor/freetype-2.13.3.tar.xz"
    sha256: "0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac``.
    "autoconf"
    ## automake provides the upstream ``Makefile.in`` templates the
    ## release tarball pre-generates.
    "automake"
    ## libtool provides the ``./libtool`` shim the autotools build
    ## drives for ``--disable-static`` to honour the shared-only build
    ## semantics correctly.
    "libtool"
    ## make is the build-system driver — the c_cpp_autotools
    ## convention's compile action invokes ``make`` after
    ## ``./configure``.
    "make"
    ## gcc is the host C toolchain — freetype is plain C99 with light
    ## use of autoconf macros.
    "gcc >=11"
    ## pkg-config is used by the configure script to probe for optional
    ## zlib / libpng dependencies that the ``=auto`` flag values enable
    ## when present on the host.
    "pkg-config"

  config:
    ## No prefix lifted from `configureFlags:`; flags inlined in the `build:` block.
    discard
  library libFreetype:
    ## ``libfreetype.so`` — the TrueType / OpenType / Type1 / CFF /
    ## WOFF font-format loader + glyph rasteriser + hinting /
    ## autohinting engine. Every Linux UI toolkit (GTK, Qt, browsers,
    ## terminal emulators) links against this transitively via pango +
    ## harfbuzz + fontconfig + cairo. v1 records the artifact only; the
    ## per-artifact build body lands in M9.L when the convention's
    ## make-spawn + install-glue closes.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `autotools_package(...)` constructor.
    setCurrentOwningPackageOverride("freetypeSource")
    try:
      let opts = @[
        "--disable-static",
        "--without-zlib=auto",
        "--without-bzip2",
        "--without-png=auto",
        "--without-harfbuzz",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libFreetype")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
