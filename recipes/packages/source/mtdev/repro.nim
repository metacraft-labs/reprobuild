import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package mtdevSource:
  versions:
    "1.1.7":
      sourceRevision = "v1.1.7"
      sourceUrl = "https://bitmath.org/code/mtdev/mtdev-1.1.7.tar.bz2"
      sourceRepository = "https://bitmath.org/git/mtdev.git"
  fetch:
    url: "https://bitmath.org/code/mtdev/mtdev-1.1.7.tar.bz2"
    sha256: "a107adad2101fecac54ac7f9f0e0a0dd155d954193da55c2340c97f2ff1d814e"
    extractStrip: 1
  nativeBuildDeps:
    "make"
    "gcc >=11"
  config:
    discard
  library libmtdev:
    discard
  build:
    setCurrentOwningPackageOverride("mtdevSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared",
      ])
      discard pkg.library("libmtdev")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    discard
