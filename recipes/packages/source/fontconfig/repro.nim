## Source-from-tarball fontconfig recipe — the TWENTY-FIFTH real from-
## source production recipe to exercise the M9.H/I/K trio
## (fetch: + configureFlags: + convention-layer fetch-action emission).
##
## Prior twenty-four from-source recipes — sixteen meson (dbus-broker,
## libdrm, wayland, wlroots, sway, libxkbcommon, pixman, libinput, cairo,
## pango, gdk-pixbuf, glib2, mutter, gnome-shell, harfbuzz this batch),
## one make (linux-kernel), five CMake (json-c, kcoreaddons, kwin,
## plasma-workspace, sddm), three autotools (expat, gdm, freetype this
## batch) — collectively covered every M9.I flag-injection channel.
## fontconfig is the FOURTH autotools-driven recipe, exercising the
## ``configureFlags:`` channel with the FONT-DISCOVERY + matching layer
## that sits above freetype's rasteriser to resolve font families to
## actual files on disk.
##
## ## Why fontconfig matters for the v1 desktop story
##
## fontconfig is the font-discovery + matching layer the entire Linux
## desktop UI stack depends on: pango asks fontconfig "find me a sans-
## serif with cyrillic + arabic coverage at 12pt regular" and gets back
## a list of /usr/share/fonts/.../X.ttf paths; freetype then opens
## those files and rasterises glyphs; harfbuzz arranges them. The
## sibling ``pangoSource`` recipe pins ``fontconfig >=2.13`` in its
## ``uses:`` block, so this recipe is the upstream-source side of that
## dependency edge. fontconfig also consumes libexpat (sibling
## ``expatSource`` recipe) for parsing its ``fonts.conf`` XML config
## file, closing a dependency triangle: expat -> fontconfig -> pango.
##
## ## sha256 strategy
##
## We vendor the upstream 2.16.0 .tar.xz at
## ``recipes/packages/source/fontconfig/vendor/fontconfig-2.16.0.tar.xz``
## and reference it via a ``file://`` URL. The freedesktop.org release
## URL is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 2.16.0 (current upstream stable)
##
## freedesktop.org publishes fontconfig releases at
## ``https://www.freedesktop.org/software/fontconfig/release/`` and
## 2.16.0 is the current stable in the 2.16.x line as of mid-2026.
## The fontconfig ABI has been stable for many years — anything
## ``>=2.13`` covers pango consumption.
##
## sha256 = 6a33dc555cc9ba8b10caf7695878ef134eeb36d0af366041f639b1da9b6ed220
##  (computed locally over the vendored ``fontconfig-2.16.0.tar.xz``,
##  1,294,156 bytes; downloaded once from the upstream URL recorded in
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
## fontconfig's autotools build emits a single shared library
## (``libfontconfig.so``) bundling the font-discovery + matching engine
## + the XML-config parser + the FreeType-backed font-property scanner.
## We register the artifact under the package-level identifier
## ``libFontconfig`` (camelCased to follow the expat / freetype /
## gdk-pixbuf precedent of camelCasing the package-level artifact
## identifier).
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``--disable-static``    — skip the static archive (not used by
##                                the v1 desktop story; cuts build time
##                                + cache size). Matches the
##                                ``--disable-static`` expat + freetype
##                                precedents.
##   * ``--disable-docs``      — skip the documentation build (heavy
##                                docbook2x / xsltproc dependency
##                                surface, not needed at runtime).
##   * ``--enable-libxml2``    — use libxml2 INSTEAD of expat for the
##                                fonts.conf XML parser. The v1 desktop
##                                story already ships libxml2 (mutter +
##                                GNOME settings pull it in) so this
##                                reuses the existing dep rather than
##                                pulling expat in for fontconfig's
##                                XML-parsing slot. (expat is still
##                                independently vendored for dbus-broker
##                                introspection-XML use.)
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. an expat-XML variant that
## flips to ``--disable-libxml2`` for legacy bundles).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package fontconfigSource:
  ## From-source fontconfig — twenty-fifth M9.H/I/K production recipe
  ## and FOURTH autotools-driven recipe (expat, gdm, freetype precedents).
  ## The font-discovery + matching layer that sits above freetype's
  ## rasteriser; pango / cairo / GTK / Qt / browsers all consume it.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right URL +
  ## hash + flags. Single library artifact recipe.

  defaultToolProvisioning "path"

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## freedesktop.org release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream freedesktop.org
    ## gitlab project — fontconfig's canonical home.
    "2.16.0":
      sourceRevision = "2.16.0"
      sourceUrl = "https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.16.0.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/fontconfig/fontconfig"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network is
    ## unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 1,294,156-byte tarball
    ## downloaded once from the upstream URL recorded in ``versions:``
    ## above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/fontconfig/vendor/fontconfig-2.16.0.tar.xz"
    sha256: "6a33dc555cc9ba8b10caf7695878ef134eeb36d0af366041f639b1da9b6ed220"
    extractStrip: 1

  uses:
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
    ## gcc is the host C toolchain — fontconfig is plain C99.
    "gcc >=11"
    ## pkg-config is used by the configure script to probe for the
    ## freetype + libxml2 dependencies.
    "pkg-config"
    ## freetype is the font-glyph loader fontconfig uses to scan TTF /
    ## OTF font properties (family name, weight, slant, charset, etc.)
    ## when building its font cache. The sibling ``freetypeSource``
    ## recipe vendors 2.13.3.
    "freetype >=2.10"
    ## libxml2 is the XML parser fontconfig consumes via the
    ## ``--enable-libxml2`` configure flag for parsing the
    ## ``fonts.conf`` config file. (expat is the alternative; we pick
    ## libxml2 because the rest of the GNOME stack already depends on
    ## it.)
    "libxml2 >=2.9"

  configureFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: the ``./configure`` script
    ## evaluates options left-to-right and the ``--enable-libxml2``
    ## sentinel lives at the tail so any override (e.g. a future
    ## expat-XML variant) can append ``--disable-libxml2`` later
    ## without re-ordering this block.
    ##
    ## ``--disable-static`` skips the static archive.
    ## ``--disable-docs`` skips the docbook2x / xsltproc-driven docs.
    ## ``--enable-libxml2`` uses libxml2 instead of expat for XML.
    "--disable-static"
    "--disable-docs"
    "--enable-libxml2"

  library libFontconfig:
    ## ``libfontconfig.so`` — the font-discovery + matching engine +
    ## XML-config parser + FreeType-backed font-property scanner.
    ## pango / cairo / GTK / Qt6 / Firefox / Chromium all link this
    ## transitively to resolve font families to actual files on disk.
    ## v1 records the artifact only; the per-artifact build body lands
    ## in M9.L when the convention's make-spawn + install-glue closes.
    discard
