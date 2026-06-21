## Source-from-tarball libogg recipe — M9.R.15p.2.2 libcanberra blocker.
##
## libogg is the Xiph.Org foundation's container-format library — the
## ``.ogg`` framing format used by libvorbis (vorbisfile API) to carry
## Vorbis audio streams. libcanberra's ``Vorbis (mandatory)`` configure
## probe (configure.ac:586) pulls in libvorbisfile, which in turn pulls
## in libogg as a hard dependency through ``PKG_CHECK_MODULES(VORBIS,
## [ vorbisfile ])`` — vorbisfile.pc names ogg as a Requires:.
##
## ## Why libogg matters for the v1 desktop story
##
## libogg's ``libogg.so.0`` is the foundation library every Xiph audio
## codec (Vorbis / Speex / Theora / Opus-in-ogg) links against for
## stream framing. libcanberra needs it transitively to satisfy its
## hardcoded vorbisfile dependency.
##
## ## sha256 strategy
##
## We vendor the upstream 1.3.5 .tar.xz at
## ``recipes/packages/source/libogg/vendor/libogg-1.3.5.tar.xz``
## and reference it via the canonical downloads.xiph.org URL.
##
## sha256 = c4d91be36fc8e54deae7575241e03f4211eb102afb3fc0775fbbc1b740016705
##  (computed locally over the vendored 429,076-byte tarball;
##  downloaded once from the upstream URL recorded in ``versions:``).
##
## ## Version choice — 1.3.5 (last upstream release; matches nixpkgs)
##
## libogg 1.3.5 is the current upstream stable in the 1.3.x line and
## the version every modern distribution (Debian / Fedora / Arch /
## NixOS) ships. The ABI has been stable since 1.3.0.
##
## ## Build shape
##
## c_cpp_autotools convention (M9.K) — sibling to the expat / freetype /
## fontconfig / libcanberra autotools recipes.
##
## ## Library artifact
##
## libogg's autotools build emits a single shared library
## (``libogg.so.0``).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package liboggSource:
  ## From-source libogg — M9.R.15p.2.2 libcanberra blocker.
  ## Tier-2b c_cpp_autotools convention consumer. Single library
  ## artifact recipe.

  versions:
    "1.3.5":
      sourceRevision = "v1.3.5"
      sourceUrl = "https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.xz"
      sourceRepository = "https://gitlab.xiph.org/xiph/ogg.git"

  fetch:
    url: "https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.xz"
    sha256: "c4d91be36fc8e54deae7575241e03f4211eb102afb3fc0775fbbc1b740016705"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"

  config:
    discard

  library libOgg:
    ## ``libogg.so.0`` — the Xiph.Org ogg container library. v1 records
    ## the artifact only.
    discard

  build:
    setCurrentOwningPackageOverride("liboggSource")
    try:
      let opts = @[
        "--disable-static",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libOgg")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
