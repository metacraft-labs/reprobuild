## Source-built X.Org font metadata and conversion utilities.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package fontUtilSource:
  versions:
    "1.4.2":
      sourceRevision = "font-util-1.4.2"
      sourceUrl = "https://gitlab.freedesktop.org/xorg/font/util/-/archive/font-util-1.4.2/util-font-util-1.4.2.tar.gz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/font/util"

  fetch:
    url: "https://gitlab.freedesktop.org/xorg/font/util/-/archive/font-util-1.4.2/util-font-util-1.4.2.tar.gz"
    sha256: "bf8505b74d0159cd11aeaad929d0e262ebb97eacc09eee7665300cf68f8705e5"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "m4"
    "make"
    "gcc >=11"
    "pkg-config"
    "sed"

  buildDeps:
    "util-macros"

  config:
    discard

  build:
    setCurrentOwningPackageOverride("fontUtilSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[],
        patchHardcodedFile = true,
        srcPatches = @[
          "cp ../util-macros/.repro/output/install/usr/share/aclocal/xorg-macros.m4 ./src/xorg-macros.m4",
          "sed -i '1i m4_include([xorg-macros.m4])' ./src/configure.ac",
        ])
      pkg.installTreeMirror()
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
