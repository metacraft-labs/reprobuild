## Source-from-tarball xkbcomp recipe — M9.R.27.3 Gap 3 prep.
##
## xkbcomp is the XKB keymap compiler invoked at runtime by xwayland
## to translate Wayland session keymaps into X11 keymaps.
##
## Vendored at ``recipes/packages/source/xkbcomp/vendor/xkbcomp-1.4.7.tar.xz``.
## sha256 = 0a288114e5f44e31987042c79aecff1ffad53a8154b8ec971c24a69a80f81f77
## (239,324 bytes).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package xkbcompSource:
  versions:
    "1.4.7":
      sourceRevision = "xkbcomp-1.4.7"
      sourceUrl = "https://www.x.org/releases/individual/app/xkbcomp-1.4.7.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/app/xkbcomp"

  fetch:
    url: "https://www.x.org/releases/individual/app/xkbcomp-1.4.7.tar.xz"
    sha256: "0a288114e5f44e31987042c79aecff1ffad53a8154b8ec971c24a69a80f81f77"
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
    "libxkbfile"

  config:
    discard
  executable xkbcomp:
    discard

  build:
    setCurrentOwningPackageOverride("xkbcompSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[])
      discard pkg.executable("xkbcomp")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
