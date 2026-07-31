import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package lcms2Source:
  versions:
    "2.17":
      sourceRevision = "lcms2.17"
      sourceUrl = "https://downloads.sourceforge.net/project/lcms/lcms/2.17/lcms2-2.17.tar.gz"
      sourceRepository = "https://github.com/mm2/Little-CMS"
  fetch:
    url: "https://downloads.sourceforge.net/project/lcms/lcms/2.17/lcms2-2.17.tar.gz"
    sha256: "d11af569e42a1baa1650d20ad61d12e41af4fead4aa7964a01f93b08b53ab074"
    extractStrip: 1
  nativeBuildDeps:
    "make"
    "gcc >=11"
    "pkg-config"
  buildDeps:
    "libjpeg"
    "libtiff"
    "zlib"
  config:
    discard
  library liblcms2:
    discard
  build:
    setCurrentOwningPackageOverride("lcms2Source")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared",
      ])
      discard pkg.library("liblcms2")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "libjpeg"
    "libtiff"
    "zlib"
