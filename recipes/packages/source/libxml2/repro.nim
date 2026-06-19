## Source-from-tarball libxml2 recipe — the TWENTY-EIGHTH real
## from-source production recipe to exercise the M9.H/I/K trio. The
## SIXTH autotools-driven recipe after expat, gdm, freetype, fontconfig,
## and (in this batch) zlib. libxml2 is the canonical full-DOM + SAX
## XML parser for the Linux desktop; it pairs with the stream-oriented
## expat recipe (which most desktop infrastructure uses for fast SAX
## parsing) by providing the heavyweight tree-based + XPath + XSLT
## entry points GNOME / KDE settings systems consume.
##
## ## Why libxml2 matters for the v1 desktop story
##
## libxml2 is consumed by virtually every modern Linux desktop component
## that needs an XML DOM or XPath traversal: gsettings schemas
## (gschema XML), polkit policies (``/usr/share/polkit-1/actions/*.xml``),
## the at-spi accessibility framework's introspection trees, Plasma's
## KConfigXT type-system code-generation, every GTK application's
## ``.glade`` / ``.ui`` builder XML, and the libsoup HTTP / HTTP2
## client's WSDL parser. Sibling consumers pinning ``libxml2 >=2.10``
## include glib2 (GResource schema XML), qt6-base (QtXml fallback when
## Qt's own XML reader isn't sufficient — typically QXmlStreamReader),
## and the GNOME / Plasma stacks transitively via gsettings.
##
## ## sha256 strategy
##
## We vendor the upstream 2.13.5 .tar.xz at
## ``recipes/packages/source/libxml2/vendor/libxml2-2.13.5.tar.xz`` and
## reference it via a ``file://`` URL. The download.gnome.org release
## URL is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 2.13.5 (current upstream stable)
##
## libxml2 releases are cut on download.gnome.org under
## ``https://download.gnome.org/sources/libxml2/`` and 2.13.5 is the
## current stable in the 2.13.x line as of mid-2026. The ABI has been
## stable since the 2.10 cut — anything ``>=2.10`` covers the
## glib2 / qt6-base / GNOME / Plasma consumption.
##
## sha256 = 74fc163217a3964257d3be39af943e08861263c4231f9ef5b496b6f6d4c7b2b6
##  (computed locally over the vendored ``libxml2-2.13.5.tar.xz``,
##  2,586,872 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
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
## libxml2's autotools build emits a single shared library
## (``libxml2.so``) bundling the tree-based DOM API, the SAX parser
## (alternative to expat), the XPath + XPointer evaluators, and the
## (optionally-included) HTTP/FTP I/O helpers. We register the artifact
## under the package-level identifier ``libXml2`` (PascalCased from the
## upstream SONAME ``xml2``, matching the libGlib2 / libExpat precedent
## of preserving the canonical ``lib`` prefix while PascalCasing the
## SONAME body).
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static``   — skip the static archive (not used by
##                               the v1 desktop story; cuts build time
##                               + cache size). Matches the
##                               ``--disable-static`` expat / gdm
##                               precedent.
##   * ``--without-python``   — skip the Python bindings (the v1
##                               desktop story consumes the C library
##                               directly via glib2's GResource layer +
##                               qt6-base's QtXml fallback).
##   * ``--without-history``  — skip the readline-driven interactive
##                               XML shell.
##   * ``--without-html``     — skip the HTML parser side of libxml2
##                               (the v1 desktop story uses pure XML
##                               only; the HTML parser pulls in
##                               additional state-machine code that
##                               increases binary size for unused
##                               functionality).
##   * ``--without-debug``    — skip the debug-mode XML tree introspection
##                               helpers (saves binary size at runtime).
##   * ``--without-mem-debug`` — skip the memory-allocation debug
##                               instrumentation.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a developer variant that
## flips ``--with-debug`` for the at-spi accessibility debug bundle).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package libxml2Source:
  ## From-source libxml2 — twenty-eighth M9.H/I/K production recipe
  ## and the SIXTH autotools-driven from-source recipe (expat, gdm,
  ## freetype, fontconfig, zlib precedents).
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
  ## right URL + hash + flags. Single library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.gnome.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream GNOME gitlab
    ## project --- libxml2's canonical home post-freedesktop-migration.
    "2.13.5":
      sourceRevision = "v2.13.5"
      sourceUrl = "https://download.gnome.org/sources/libxml2/2.13/libxml2-2.13.5.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/libxml2"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 2,586,872-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/libxml2/vendor/libxml2-2.13.5.tar.xz"
    sha256: "74fc163217a3964257d3be39af943e08861263c4231f9ef5b496b6f6d4c7b2b6"
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
    ## gcc is the host C toolchain — libxml2 is C89 / C99 with light
    ## use of autoconf macros.
    "gcc >=11"

  buildDeps:
    ## zlib is consumed by libxml2's gzip-compressed XML stream
    ## reader (libxml2 transparently decompresses ``.xml.gz`` and
    ## gzip-encoded HTTP responses). The sibling ``zlibSource`` recipe
    ## vendors a compatible version.
    "zlib >=1.2.11"

  configureFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: the ``./configure`` script
    ## evaluates options left-to-right and the ``--without-mem-debug``
    ## sentinel lives at the tail so any override (e.g. a future
    ## debug-build variant) can append ``--with-mem-debug`` later
    ## without re-ordering this block.
    ##
    ## ``--disable-static`` skips the static archive.
    ## ``--without-python`` skips the Python bindings.
    ## ``--without-history`` skips the readline interactive XML shell.
    ## ``--without-html`` skips the HTML parser side of libxml2.
    ## ``--without-debug`` skips the debug-mode tree introspection
    ## helpers.
    ## ``--without-mem-debug`` skips the memory-allocation debug
    ## instrumentation.
    "--disable-static"
    "--without-python"
    "--without-history"
    "--without-html"
    "--without-debug"
    "--without-mem-debug"

  library libXml2:
    ## ``libxml2.so`` — the canonical full-DOM + SAX XML parser
    ## consumed by gsettings schema validation, polkit policy parsing,
    ## the at-spi accessibility framework, Plasma's KConfigXT code-
    ## generation, and every GTK application's ``.glade`` / ``.ui``
    ## builder XML. The upstream SONAME ``xml2`` is PascalCased to
    ## ``libXml2`` per the libGlib2 / libExpat precedent of preserving
    ## the canonical ``lib`` prefix while PascalCasing the SONAME body.
    ## v1 records the artifact only; the per-artifact build body lands
    ## in M9.L when the convention's make-spawn + install-glue closes.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
