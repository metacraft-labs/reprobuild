## Source-from-tarball libXfont2 recipe — M9.R.27.3 Gap 3 prep.
##
## libXfont2 is the historic xorg font helper xwayland's font path
## bootstrap requires when no Wayland-side font config is set.
##
## Vendored at ``recipes/packages/source/libxfont2/vendor/libXfont2-2.0.7.tar.xz``.
## sha256 = 8b7b82fdeba48769b69433e8e3fbb984a5f6bf368b0d5f47abeec49de3e58efb
## (453,012 bytes).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libxfont2Source:
  versions:
    "2.0.7":
      sourceRevision = "libXfont2-2.0.7"
      sourceUrl = "https://www.x.org/releases/individual/lib/libXfont2-2.0.7.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libxfont"

  fetch:
    url: "https://www.x.org/releases/individual/lib/libXfont2-2.0.7.tar.xz"
    sha256: "8b7b82fdeba48769b69433e8e3fbb984a5f6bf368b0d5f47abeec49de3e58efb"
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
    "xtrans"
    "freetype"
    "libfontenc"

  config:
    discard
  library libXfont2:
    discard

  build:
    setCurrentOwningPackageOverride("libxfont2Source")
    try:
      let opts = @["--disable-static", "--enable-shared"]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libXfont2")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
