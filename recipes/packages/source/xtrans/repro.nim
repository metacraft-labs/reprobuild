## Source-from-tarball xtrans recipe — M9.R.27.3 Gap 3 preparation.
##
## xtrans is the X11 transport-layer abstraction (Unix-socket / TCP /
## DECnet, ...). Pure-header package consumed at compile-time by libX11
## + the X server.
##
## Vendored at ``recipes/packages/source/xtrans/vendor/xtrans-1.6.0.tar.xz``.
## sha256 = faafea166bf2451a173d9d593352940ec6404145c5d1da5c213423ce4d359e92
## (177,156 bytes).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package xtransSource:
  versions:
    "1.6.0":
      sourceRevision = "xtrans-1.6.0"
      sourceUrl = "https://www.x.org/releases/individual/lib/xtrans-1.6.0.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libxtrans"

  fetch:
    url: "https://www.x.org/releases/individual/lib/xtrans-1.6.0.tar.xz"
    sha256: "faafea166bf2451a173d9d593352940ec6404145c5d1da5c213423ce4d359e92"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    discard

  config:
    discard

  build:
    setCurrentOwningPackageOverride("xtransSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[])
      ## M9.R.29.13 — header-only autotools package; emit the install
      ## mirror explicitly so the consumer's pkgconfig-only fast-path
      ## sees ``xtrans.pc`` under ``.repro/output/install/usr/share/
      ## pkgconfig/``.
      pkg.installTreeMirror()
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
