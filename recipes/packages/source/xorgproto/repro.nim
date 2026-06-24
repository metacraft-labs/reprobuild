## Source-from-tarball xorgproto recipe — closes one of xwayland's 9
## leaf x.org library deps (M9.R.27.3 Gap 3 preparation).
##
## xorgproto is the catalog of X11 protocol headers (XProto, XKB,
## DRI3, DRI2, Composite, Damage, Fixes, Render, Randr, Resource,
## Present, Scrnsaver, Sync, Xinerama, Xv). Pure-header package
## consumed at compile-time by every X11 client + the X server.
##
## Vendored at ``recipes/packages/source/xorgproto/vendor/xorgproto-2024.1.tar.xz``.
## sha256 = 372225fd40815b8423547f5d890c5debc72e88b91088fbfb13158c20495ccb59
## (760,500 bytes).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package xorgprotoSource:
  versions:
    "2024.1":
      sourceRevision = "xorgproto-2024.1"
      sourceUrl = "https://www.x.org/releases/individual/proto/xorgproto-2024.1.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/proto/xorgproto"

  fetch:
    url: "https://www.x.org/releases/individual/proto/xorgproto-2024.1.tar.xz"
    sha256: "372225fd40815b8423547f5d890c5debc72e88b91088fbfb13158c20495ccb59"
    extractStrip: 1

  nativeBuildDeps:
    "meson >=1.0"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    discard

  config:
    discard

  build:
    setCurrentOwningPackageOverride("xorgprotoSource")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[])
      ## M9.R.29.13 — pure-header X11 protocol package; emit the
      ## install mirror explicitly so consumers' pkgconfig-only
      ## fast-path sees the .pc files under
      ## ``.repro/output/install/usr/share/pkgconfig/``.
      pkg.installTreeMirror()
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
