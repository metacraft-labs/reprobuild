## Source-from-tarball zlib recipe — the TWENTY-NINTH real from-source
## production recipe to exercise the M9.H/I/K trio. zlib's unique
## coverage angle vs the prior twenty-eight recipes is the
## ``configureFlags:`` channel feeding a CUSTOM, hand-rolled
## ``./configure`` script — zlib's ``configure`` is NOT autoconf
## generated and accepts a much smaller (~6 flag) flag set with
## different option-shape conventions (e.g. ``--shared`` instead of
## ``--enable-shared``). The convention layer treats the
## ``configureFlags:`` channel as the abstract "argv passed to
## ``./configure``" carrier, so a custom-configure recipe reuses the
## same channel without needing a new flag-channel taxonomy. This pins
## the per-channel partitioning property from a fourth flavour angle:
## autotools (expat), autotools-with-tristate (freetype), autotools-with-
## twin-binaries (gdm), and now custom (zlib).
##
## ## Why zlib matters for the v1 desktop story
##
## zlib is the deflate / inflate compression library underpinning a
## staggering portion of the modern Linux stack: the kernel's compressed
## kernel image, every desktop component that consumes the GIO stream-
## filter API, gzip-content HTTP responses in QtNetwork, font-file
## SFNT compression in freetype, PNG image decoding in libpng (in turn
## consumed by gdk-pixbuf), and ELF section compression in glibc /
## binutils. Sibling consumers pinning ``zlib`` include glib2 (GIO
## gzip streams), qt6-base (QtNetwork HTTP / QFile transparent
## decompression), libxml2 (gzip-compressed XML stream support),
## openssl (TLS record compression — historical, now off-by-default
## but still present in the build), freetype (font WOFF/WOFF2 decode),
## and the linux-kernel recipe (compressed bzImage + initramfs).
##
## ## sha256 strategy
##
## We vendor the upstream 1.3.1 .tar.gz at
## ``recipes/packages/source/zlib/vendor/zlib-1.3.1.tar.gz`` and
## reference it via a ``file://`` URL. The upstream ``zlib.net`` host
## historically serves the canonical tarball but the matching GitHub
## release at
## ``https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz``
## is what's recorded as ``sourceUrl`` (and what we fetched at vendor
## time) because the zlib.net mirror lifecycle is brittle and the
## GitHub release URL is stable across the project's mirror moves. The
## live ``fetch:`` block points at the vendored copy so the convention
## layer's emitted fetch action is offline-reproducible.
##
## ## Version choice — 1.3.1 (current upstream stable)
##
## ``zlib`` releases are cut on GitHub under tags of the form ``v<X>.<Y>.<Z>``.
## 1.3.1 is the current stable in the 1.3.x line as of mid-2026 and the
## ABI has been stable since the 1.2.11 cut — anything ``>=1.2.11``
## covers every consumer's pinning.
##
## sha256 = 9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
##  (computed locally over the vendored ``zlib-1.3.1.tar.gz``,
##  1,512,791 bytes; downloaded once from the GitHub release URL
##  recorded in ``versions:`` above).
##
## ## Build shape
##
## zlib's upstream build uses a hand-rolled ``./configure`` script that
## is NOT autoconf-generated; it shares the autotools-style argv shape
## (positional flags evaluated left-to-right) but accepts a much
## smaller flag set with different naming conventions (``--shared``
## not ``--enable-shared``, ``--static`` not ``--enable-static``,
## ``--prefix=`` not ``--exec-prefix=``). The convention layer treats
## the ``configureFlags:`` channel as the abstract "argv passed to
## ``./configure``" carrier, so a custom-configure recipe reuses the
## same channel without needing a new flag-channel taxonomy. The
## convention layer (M9.K) reads both the M9.H ``fetch:`` block and the
## M9.I ``configureFlags:`` block off this package's registries and
## lowers them into:
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
## zlib's build emits a single shared library (``libz.so``) bundling
## the deflate + inflate compression primitives, the gzip stream
## reader/writer, and the CRC32 helper. We register the artifact under
## the package-level identifier ``libZ`` (PascalCased single-letter
## variant of the upstream SONAME ``z``, matching the libExpat / libGio
## ``lib<Name>`` precedent of preserving the canonical ``lib`` prefix
## while PascalCasing the SONAME body).
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--shared`` — build the shared library (``libz.so``); zlib's
##                    custom ``./configure`` defaults to building both
##                    static and shared, and ``--shared`` keeps only
##                    the shared variant to match the
##                    ``--disable-static`` baseline the sibling
##                    autotools recipes use.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a static-bundling variant
## that flips ``--static`` for the kernel's initramfs build).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package zlibSource:
  ## From-source zlib — twenty-ninth M9.H/I/K production recipe and the
  ## FIRST recipe in the corpus to drive a CUSTOM (non-autotools, non-
  ## meson, non-cmake) ``./configure`` script through the abstract
  ## ``configureFlags:`` channel. The custom-configure flavour reuses
  ## the autotools ``configure`` channel because the convention layer
  ## treats the channel as the abstract "argv passed to ``./configure``"
  ## carrier.
  ##
  ## Tier-2b c_cpp_autotools convention consumer (custom-configure
  ## flavour): the convention layer reads the ``fetch:`` block
  ## (registered via ``registeredFetchSpec``) and the
  ## ``configureFlags:`` block (registered via ``registeredBuildFlags``
  ## on the ``"configure"`` channel) and lowers them into fetch +
  ## configure BuildActions wired with the right URL + hash + flags.
  ## Single library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## github.com release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical GitHub project
    ## that hosts the zlib source tree (the historical zlib.net
    ## mirror lifecycle is brittle — GitHub is the stable mirror).
    "1.3.1":
      sourceRevision = "v1.3.1"
      sourceUrl = "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz"
      sourceRepository = "https://github.com/madler/zlib"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 1,512,791-byte tarball
    ## downloaded once from the GitHub release URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/zlib/vendor/zlib-1.3.1.tar.gz"
    sha256: "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"
    extractStrip: 1

  nativeBuildDeps:
    ## make is the build-system driver — zlib's custom ``./configure``
    ## emits a ``Makefile`` that ``make`` then drives.
    "make"
    ## gcc is the host C toolchain — zlib is plain C89 / C99 with no
    ## external runtime dependencies.
    "gcc >=11"

  configureFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. zlib's custom ``./configure`` accepts a much smaller flag
    ## set than autotools-generated ``./configure`` scripts (~6 flags
    ## total: ``--prefix=``, ``--shared``, ``--static``, ``--const``,
    ## ``--zprefix``, ``--solo``) with different naming conventions
    ## (``--shared`` not ``--enable-shared``).
    ##
    ## Order is load-bearing: zlib's ``./configure`` evaluates options
    ## left-to-right and a regression that reorders this seq would
    ## silently change build behaviour (shared-only vs both).
    ##
    ## ``--shared`` builds only the shared library variant; matches
    ## the ``--disable-static`` baseline the sibling autotools recipes
    ## use.
    "--shared"

  library libZ:
    ## ``libz.so`` — the deflate / inflate compression library
    ## consumed by glib2 (GIO gzip streams), qt6-base (QtNetwork HTTP
    ## decompression), libxml2 (gzip-compressed XML streams), openssl
    ## (historical TLS record compression), freetype (WOFF/WOFF2 font
    ## decode), and the linux-kernel recipe (compressed bzImage +
    ## initramfs). The upstream SONAME ``z`` is PascalCased to
    ## ``libZ`` per the libExpat / libGio precedent of preserving the
    ## canonical ``lib`` prefix while PascalCasing the SONAME body.
    ## v1 records the artifact only; the per-artifact build body lands
    ## in M9.L when the convention's make-spawn + install-glue closes.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
