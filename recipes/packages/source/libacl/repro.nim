import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libaclSource:
  versions:
    "2.3.2":
      sourceRevision = "v2.3.2"
      sourceUrl = "https://download.savannah.gnu.org/releases/acl/acl-2.3.2.tar.gz"
      sourceRepository = "https://git.savannah.nongnu.org/git/acl.git"
  fetch:
    url: "https://download.savannah.gnu.org/releases/acl/acl-2.3.2.tar.gz"
    sha256: "5f2bdbad629707aa7d85c623f994aa8a1d2dec55a73de5205bac0bf6058a2f7c"
    extractStrip: 1
  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"
  buildDeps:
    "libattr"
  config:
    discard
  library libacl:
    discard
  build:
    setCurrentOwningPackageOverride("libaclSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared",
      ])
      discard pkg.library("libacl")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "libattr"
