import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libattrSource:
  versions:
    "2.5.2":
      sourceRevision = "v2.5.2"
      sourceUrl = "https://download.savannah.gnu.org/releases/attr/attr-2.5.2.tar.gz"
      sourceRepository = "https://git.savannah.nongnu.org/git/attr.git"
  fetch:
    url: "https://download.savannah.gnu.org/releases/attr/attr-2.5.2.tar.gz"
    sha256: "39bf67452fa41d0948c2197601053f48b3d78a029389734332a6309a680c6c87"
    extractStrip: 1
  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
  config:
    discard
  library libattr:
    discard
  build:
    setCurrentOwningPackageOverride("libattrSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared",
      ])
      discard pkg.library("libattr")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    discard
