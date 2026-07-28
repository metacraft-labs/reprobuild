## Source-built PCI access library used by the Xorg server.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libpciaccessSource:
  versions:
    "0.19":
      sourceRevision = "libpciaccess-0.19"
      sourceUrl = "https://gitlab.freedesktop.org/xorg/lib/libpciaccess/-/archive/libpciaccess-0.19/libpciaccess-libpciaccess-0.19.tar.gz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libpciaccess"

  fetch:
    url: "https://gitlab.freedesktop.org/xorg/lib/libpciaccess/-/archive/libpciaccess-0.19/libpciaccess-libpciaccess-0.19.tar.gz"
    sha256: "ae2d080c8394d2b36a54aed270bc826f1438e41e7daf783ca5cff60285529ae2"
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
    setCurrentOwningPackageOverride("libpciaccessSource")
    try:
      let pkg = meson_package(srcDir = "./src")
      pkg.installTreeMirror()
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
