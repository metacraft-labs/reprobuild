## Source-from-tarball libxkbfile recipe — M9.R.27.3 Gap 3 prep.
##
## libxkbfile is the XKB keymap-file reader xkbcomp + the X server
## consume to parse compiled keymap binary files.
##
## Vendored at ``recipes/packages/source/libxkbfile/vendor/libxkbfile-1.1.3.tar.xz``.
## sha256 = a9b63eea997abb9ee6a8b4fbb515831c841f471af845a09de443b28003874bec
## (314,520 bytes).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libxkbfileSource:
  versions:
    "1.1.3":
      sourceRevision = "libxkbfile-1.1.3"
      sourceUrl = "https://www.x.org/releases/individual/lib/libxkbfile-1.1.3.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libxkbfile"

  fetch:
    url: "https://www.x.org/releases/individual/lib/libxkbfile-1.1.3.tar.xz"
    sha256: "a9b63eea997abb9ee6a8b4fbb515831c841f471af845a09de443b28003874bec"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    "xorgproto"

  config:
    discard
  library libxkbfile:
    discard

  build:
    setCurrentOwningPackageOverride("libxkbfileSource")
    try:
      let opts = @["--disable-static", "--enable-shared"]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libxkbfile")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
