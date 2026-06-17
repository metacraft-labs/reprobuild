## Source-from-tarball expat recipe — the FOURTEENTH real from-source
## production recipe to exercise the M9.H/I/K trio and the FIRST recipe
## to drive the ``configureFlags:`` channel (autotools-style
## ``./configure``).
##
## Prior thirteen from-source recipes — eleven meson (dbus-broker,
## libdrm, wayland, wlroots, sway, libxkbcommon, pixman, libinput,
## cairo, pango, gdk-pixbuf), one make (linux-kernel), one CMake
## (json-c) — collectively covered three of the five M9.I flag-injection
## channels (``mesonOptions:`` + ``makeFlags:`` + ``cmakeFlags:``).
## expat is the first autotools-driven upstream in the recipe suite,
## so it pins the M9.I per-channel isolation property from a third
## convention angle: a regression that misroutes a ``./configure``
## flag onto the meson or CMake channel would surface in the
## cross-channel-isolation pin in ``test_expat_source.nim``.
##
## ## Why expat matters for the v1 desktop story
##
## expat is a fast, stream-oriented C XML parser used as the canonical
## XML backend by a wide swath of desktop infrastructure: D-Bus's
## introspection XML parser, fontconfig's font-cache XML reader,
## shared-mime-info's MIME-database parser, and the GNOME accessibility
## stack's at-spi XML message decoder. It is a transitive dependency
## of every modern Linux desktop. The sibling ``dbusBrokerSource`` +
## ``fontconfig`` consumers pin ``expat >=2.6`` in their ``uses:``
## blocks (added when the desktop story closes), so this recipe is the
## upstream-source side of those dependency edges.
##
## ## sha256 strategy
##
## We vendor the upstream 2.7.0 .tar.xz at
## ``recipes/packages/source/expat/vendor/expat-2.7.0.tar.xz`` and
## reference it via a ``file://`` URL. The github.com release URL is
## recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's
## emitted fetch action is offline-reproducible.
##
## ## Version choice — 2.7.0 (current upstream stable)
##
## libexpat releases are cut on GitHub under tags of the form
## ``R_<major>_<minor>_<patch>``. The ``R_2_7_0`` tag is the current
## stable in the 2.7.x line as of mid-2026 and the ABI is stable
## since the 2.6 cut — anything ``>=2.6`` covers the dbus-broker +
## fontconfig + shared-mime-info consumption.
##
## sha256 = 25df13dd2819e85fb27a1ce0431772b7047d72af81ae78dc26b4c6e0805f48d1
##  (computed locally over the vendored ``expat-2.7.0.tar.xz``,
##  493,060 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H
## ``fetch:`` block and the M9.I ``configureFlags:`` block off this
## package's registries and lowers them into:
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
## downstream ``make`` + install glue lands in M9.L; the recipe
## records the library artifact via the ``library`` block so the
## M9.K artifact registry already knows what shared object to expect.
##
## ## Library artifact
##
## expat's autotools build emits a single shared library
## (``libexpat.so``) bundling the SAX/expat parser core, the namespace
## parser, and the XML decoder helpers. We register the artifact under
## the package-level identifier ``libExpat`` (camelCased to follow
## the gdk-pixbuf / json-c precedent of camelCasing the package-level
## artifact identifier).
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static``  — skip the static archive (not used by
##                              the v1 desktop story; cuts build time
##                              + cache size). Matches the
##                              ``BUILD_STATIC_LIBS=OFF`` json-c
##                              precedent.
##   * ``--without-docbook`` — skip the DocBook documentation build
##                              (heavy XSLT dependency surface, not
##                              needed at runtime).
##   * ``--without-examples`` — skip the bundled examples (XML pretty
##                               printer + element counter) that are
##                               not needed at runtime.
##   * ``--without-tests``   — skip the upstream test suite to keep
##                              the build hermetic + fast. Matches the
##                              ``BUILD_TESTING=OFF`` json-c precedent
##                              and the ``-Dtests=disabled`` cairo
##                              precedent.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a developer variant that
## flips ``--with-tests`` for CI bundles).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package expatSource:
  ## From-source expat — fourteenth M9.H/I/K production recipe and
  ## FIRST autotools-driven from-source recipe (every prior recipe used
  ## meson, make, or CMake).
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention
  ## layer reads the ``fetch:`` block (registered via
  ## ``registeredFetchSpec``) and the ``configureFlags:`` block
  ## (registered via ``registeredBuildFlags`` on the ``"configure"``
  ## channel) and lowers them into fetch + configure BuildActions
  ## wired with the right URL + hash + flags. Single library artifact
  ## recipe.

  defaultToolProvisioning "path"

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## github.com release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical GitHub project
    ## that hosts the libexpat source tree.
    "2.7.0":
      sourceRevision = "R_2_7_0"
      sourceUrl = "https://github.com/libexpat/libexpat/releases/download/R_2_7_0/expat-2.7.0.tar.xz"
      sourceRepository = "https://github.com/libexpat/libexpat"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 493,060-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/expat/vendor/expat-2.7.0.tar.xz"
    sha256: "25df13dd2819e85fb27a1ce0431772b7047d72af81ae78dc26b4c6e0805f48d1"
    extractStrip: 1

  uses:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac`` (the upstream
    ## release tarball does ship a pre-generated ``configure`` but we
    ## list autoconf so the convention layer can re-bootstrap if the
    ## tarball gets re-archived without ``configure``).
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
    ## gcc is the host C toolchain — expat is plain C99 with light
    ## use of autoconf macros.
    "gcc >=11"

  configureFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: the ``./configure`` script
    ## evaluates options left-to-right and the ``--without-tests``
    ## sentinel lives at the tail so any override (e.g. a future
    ## CI-bundle variant) can append ``--with-tests`` later without
    ## re-ordering this block.
    ##
    ## ``--disable-static`` skips the static archive (not used by the
    ## v1 desktop story).
    ## ``--without-docbook`` skips the DocBook documentation build.
    ## ``--without-examples`` skips the bundled examples.
    ## ``--without-tests`` skips the upstream test suite.
    "--disable-static"
    "--without-docbook"
    "--without-examples"
    "--without-tests"

  library libExpat:
    ## ``libexpat.so`` — the SAX/expat XML parser consumed by
    ## D-Bus's introspection XML layer, fontconfig's font-cache XML
    ## reader, shared-mime-info's MIME-database parser, and the GNOME
    ## at-spi accessibility XML message decoder. v1 records the
    ## artifact only; the per-artifact build body lands in M9.L when
    ## the convention's make-spawn + install-glue closes.
    discard
