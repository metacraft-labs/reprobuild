import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libmdSource:
  versions:
    "1.1.0":
      sourceRevision = "1.1.0"
      sourceUrl = "https://archive.hadrons.org/software/libmd/libmd-1.1.0.tar.xz"
      sourceRepository = "https://git.hadrons.org/cgit/libmd.git"
  fetch:
    url: "https://archive.hadrons.org/software/libmd/libmd-1.1.0.tar.xz"
    sha256: "1bd6aa42275313af3141c7cf2e5b964e8b1fd488025caf2f971f43b00776b332"
    extractStrip: 1
  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
  config:
    discard
  library libmd:
    discard
  build:
    setCurrentOwningPackageOverride("libmdSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared",
      ])
      discard pkg.library("libmd")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    discard
