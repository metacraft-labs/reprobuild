import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libxcryptSource:
  versions:
    "4.5.2":
      sourceRevision = "v4.5.2"
      sourceUrl = "https://github.com/besser82/libxcrypt/releases/download/v4.5.2/libxcrypt-4.5.2.tar.xz"
      sourceRepository = "https://github.com/besser82/libxcrypt"
  fetch:
    url: "https://github.com/besser82/libxcrypt/releases/download/v4.5.2/libxcrypt-4.5.2.tar.xz"
    sha256: "71513a31c01a428bccd5367a32fd95f115d6dac50fb5b60c779d5c7942aec071"
    extractStrip: 1
  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "perl"
  config:
    discard
  library libcrypt:
    discard
  build:
    setCurrentOwningPackageOverride("libxcryptSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static",
        "--enable-shared",
        "--enable-hashes=strong",
        "--enable-obsolete-api=glibc",
        "--disable-failure-tokens",
        "--disable-werror",
      ])
      discard pkg.library("libcrypt")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    discard
