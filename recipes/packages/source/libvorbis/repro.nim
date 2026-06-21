## Source-from-tarball libvorbis recipe — M9.R.15p.2.3 libcanberra
## blocker.
##
## libvorbis is the Xiph.Org foundation's Vorbis audio codec library —
## supplies ``libvorbis.so.0`` + ``libvorbisfile.so.3`` + ``libvorbisenc.so.2``.
## libcanberra's configure.ac:586 invokes
## ``PKG_CHECK_MODULES(VORBIS, [ vorbisfile ])`` as a MANDATORY probe
## (commented "### Vorbis (mandatory) ###") and aborts when vorbisfile.pc
## is missing.
##
## ## Why libvorbis matters for the v1 desktop story
##
## libcanberra's null back-end (the only back-end we build in for v1)
## still links against vorbisfile for the on-disk .ogg/.vorbis sound-
## sample loader path. Without libvorbisfile, knotifications' libcanberra
## consumption fails to link.
##
## ## sha256 strategy
##
## We vendor the upstream 1.3.7 .tar.xz at
## ``recipes/packages/source/libvorbis/vendor/libvorbis-1.3.7.tar.xz``
## and reference it via the canonical downloads.xiph.org URL.
##
## sha256 = b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b
##  (computed locally over the vendored 1,203,792-byte tarball;
##  downloaded once from the upstream URL recorded in ``versions:``).
##
## ## Version choice — 1.3.7 (last upstream release; matches nixpkgs)
##
## libvorbis 1.3.7 is the current upstream stable in the 1.3.x line and
## the version every modern distribution ships. ABI-stable since 1.3.0.
##
## ## Build shape
##
## c_cpp_autotools convention (M9.K). Build depends on libogg
## (vorbisfile.pc names ogg as a Requires:).
##
## ## Library artifacts
##
## libvorbis emits three shared libraries:
##   * ``libvorbis.so.0``     — the core Vorbis codec.
##   * ``libvorbisfile.so.3`` — the high-level .ogg/.vorbis demuxer +
##                              decoder (the API libcanberra consumes).
##   * ``libvorbisenc.so.2``  — the Vorbis encoder (not used by
##                              libcanberra but emitted by the build).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package libvorbisSource:
  ## From-source libvorbis — M9.R.15p.2.3 libcanberra blocker.
  ## Tier-2b c_cpp_autotools convention consumer. Three library
  ## artifacts recipe.

  versions:
    "1.3.7":
      sourceRevision = "v1.3.7"
      sourceUrl = "https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz"
      sourceRepository = "https://gitlab.xiph.org/xiph/vorbis.git"

  fetch:
    url: "https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz"
    sha256: "b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    ## libogg is the .ogg container library libvorbisfile demuxes
    ## audio streams from. vorbisfile.pc lists it as a Requires:.
    "libogg >=1.3"

  config:
    discard

  library libVorbis:
    ## ``libvorbis.so.0`` — the core Vorbis codec.
    discard

  library libVorbisfile:
    ## ``libvorbisfile.so.3`` — high-level .ogg/.vorbis demuxer +
    ## decoder. The API libcanberra consumes via vorbisfile.pc.
    discard

  library libVorbisenc:
    ## ``libvorbisenc.so.2`` — the Vorbis encoder.
    discard

  build:
    setCurrentOwningPackageOverride("libvorbisSource")
    try:
      let opts = @[
        "--disable-static",
        "--disable-docs",
        "--disable-examples",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libVorbis")
      discard pkg.library("libVorbisfile")
      discard pkg.library("libVorbisenc")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
