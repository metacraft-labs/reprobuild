## Source-built X.Org autoconf macro collection.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package utilMacrosSource:
  versions:
    "1.20.2":
      sourceRevision = "util-macros-1.20.2"
      sourceUrl = "https://gitlab.freedesktop.org/xorg/util/macros/-/archive/util-macros-1.20.2/macros-util-macros-1.20.2.tar.gz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/util/macros"

  fetch:
    url: "https://gitlab.freedesktop.org/xorg/util/macros/-/archive/util-macros-1.20.2/macros-util-macros-1.20.2.tar.gz"
    sha256: "beac7e00e5996bd0c9d9bd8cf62704583b22dbe8613bd768626b95fcac955744"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "m4"
    "make"

  buildDeps:
    discard

  config:
    discard

  build:
    setCurrentOwningPackageOverride("utilMacrosSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[],
                                  patchHardcodedFile = true)
      pkg.installTreeMirror()
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
