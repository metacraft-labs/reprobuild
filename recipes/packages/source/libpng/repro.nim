## Source-from-tarball libpng recipe — closes M9.R.26 Gap 1.
##
## Replaces the prior ``libs/repro_dsl_stdlib/.../packages/libpng.nim``
## nix-store provisioning stub. libpng was previously resolved through
## the nix-store closure mirror in ``stage-de-rootfs.sh`` (the
## ``libpng-apng-1.6.50`` derivation pulled in transitively by Qt6 /
## gdk-pixbuf / freetype). M9.R.26 promotes it to a first-class from-
## source recipe so the ISO bootstrap surface is genuinely "no apt
## fallback, no nix-store reliance" for runtime DE deps.
##
## ## Why libpng matters for the v1 desktop story
##
## libpng is the de-facto PNG image decoder consumed by gdk-pixbuf
## (image-loader plug-in for GNOME / GTK4 + indirectly mutter), cairo
## (PNG surface read/write), Qt6's QtGui (QImage PNG codec — the
## reproos-installer wizard relies on this for its splash assets),
## freetype's WOFF/WOFF2 SFNT decompression chain (transitively via
## ``zlib``), and a long tail of every wallpaper / icon / theme asset
## the live ISO ships.
##
## ## sha256 strategy
##
## We vendor the upstream 1.6.50 .tar.xz at
## ``recipes/packages/source/libpng/vendor/libpng-1.6.50.tar.xz`` and
## reference it via the upstream SourceForge URL. The live ``fetch:``
## block records the canonical URL; the convention layer's argv
## carries it verbatim so the engine's content-addressed cache
## fingerprint stays stable across rebuilds.
##
## sha256 = 4df396518620a7aa3651443e87d1b2862e4e88cad135a8b93423e01706232307
##  (computed locally over the vendored ``libpng-1.6.50.tar.xz``,
##  1,060,992 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Version choice — 1.6.50 (current upstream stable in the 1.6.x line)
##
## libpng releases are cut on SourceForge under tags of the form
## ``v1.6.x``. 1.6.50 is the current stable in the 1.6.x line as of
## mid-2026 and the ABI is stable since the 1.6.0 cut — anything
## ``>=1.6.0`` covers every consumer's pinning.
##
## ## Build shape
##
## libpng's upstream build is autoconf-generated ``./configure`` +
## ``make``. The c_cpp_autotools convention (M9.K) reads the
## ``fetch:`` + ``configureFlags:`` blocks and lowers them into the
## fetch + configure + make + install action chain.
##
## ## Library artifact
##
## libpng's autotools build emits a single shared library
## (``libpng16.so``) bundling the PNG encoder/decoder + the helpers for
## the PNG chunk-table reader. The on-disk SONAME is
## ``libpng16.so.16`` (matching the 1.6.x ABI freeze). We register the
## artifact under the package-level identifier ``libPng`` (PascalCased
## per the libExpat / libZ precedent).
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline:
##
##   * ``--disable-static``   — skip the static archive (not used by
##                               the v1 desktop story; cuts build time
##                               + cache size). Matches the
##                               ``--disable-static`` expat precedent.
##   * ``--enable-shared``    — explicit, defensive; libpng's
##                               ``./configure`` already defaults to
##                               this but the autotools convention
##                               recipes have learned to pin both
##                               sides for clarity.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package libpngSource:
  ## From-source libpng — closes M9.R.26 Gap 1. Tier-2b c_cpp_autotools
  ## convention consumer. Single library artifact recipe.

  versions:
    "1.6.50":
      sourceRevision = "v1.6.50"
      sourceUrl = "https://download.sourceforge.net/libpng/libpng-1.6.50.tar.xz"
      sourceRepository = "https://github.com/pnggroup/libpng"

  fetch:
    url: "https://download.sourceforge.net/libpng/libpng-1.6.50.tar.xz"
    sha256: "4df396518620a7aa3651443e87d1b2862e4e88cad135a8b93423e01706232307"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"

  buildDeps:
    ## libpng links against zlib for the deflate/inflate compression
    ## of PNG IDAT chunks. The sibling ``zlibSource`` recipe vendors
    ## 1.3.1 to match.
    "zlib >=1.2.11"

  config:
    discard
  library libPng:
    discard

  build:
    setCurrentOwningPackageOverride("libpngSource")
    try:
      let opts = @[
        "--disable-static",
        "--enable-shared",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libPng")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## libpng's runtime closure is libz (zlib) — handled via the
    ## buildDep above's rpath/install-mirror linkage.
    discard
