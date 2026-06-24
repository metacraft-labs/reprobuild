## Source-from-tarball GNU parted recipe — closes M9.R.27 Gap 4 (G4).
##
## GNU parted is the canonical disk-partitioning CLI the reproos
## installer Phase 2 shells out to. autotools convention.
##
## Vendored at ``recipes/packages/source/parted/vendor/parted-3.6.tar.xz``.
## sha256 = 3b43dbe33cca0f9a18601ebab56b7852b128ec1a3df3a9b30ccde5e73359e612
## (1,896,164 bytes).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package partedSource:
  versions:
    "3.6":
      sourceRevision = "v3.6"
      sourceUrl = "https://ftp.gnu.org/gnu/parted/parted-3.6.tar.xz"
      sourceRepository = "https://git.savannah.gnu.org/cgit/parted.git"

  fetch:
    url: "https://ftp.gnu.org/gnu/parted/parted-3.6.tar.xz"
    sha256: "3b43dbe33cca0f9a18601ebab56b7852b128ec1a3df3a9b30ccde5e73359e612"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"
    "gettext"

  buildDeps:
    ## device-mapper provides the libdevmapper.so parted uses for
    ## LVM / dmcrypt partition introspection.
    "device-mapper"
    ## readline is the line-editing library parted uses for its
    ## interactive shell.
    "readline"
    ## libuuid (from util-linux) for partition UUIDs.
    "util-linux"
    ## ncurses provides the terminfo/termcap library parted's
    ## readline integration links against (parted's configure
    ## hard-errors with "termcap could not be found which is required
    ## for the --with-readline option" without it).
    "ncurses"

  config:
    discard
  executable parted:
    discard
  executable partprobe:
    discard
  library libParted:
    discard

  build:
    setCurrentOwningPackageOverride("partedSource")
    try:
      let opts = @[
        "--disable-static",
        "--enable-shared",
        "--with-readline",
        "--disable-nls",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("parted")
      discard pkg.executable("partprobe")
      discard pkg.library("libParted")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
