import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package lzoSource:
  versions:
    "2.10":
      sourceRevision = "v2.10"
      sourceUrl = "https://www.oberhumer.com/opensource/lzo/download/lzo-2.10.tar.gz"
      sourceRepository = "https://github.com/nemequ/lzo"
  fetch:
    url: "https://www.oberhumer.com/opensource/lzo/download/lzo-2.10.tar.gz"
    sha256: "c0f892943208266f9b6543b3ae308fab6284c5c90e627931446fb49b4221a072"
    extractStrip: 1
  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
  config:
    discard
  library liblzo2:
    discard
  build:
    setCurrentOwningPackageOverride("lzoSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared",
      ])
      discard pkg.library("liblzo2")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    discard
