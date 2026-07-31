import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libxcryptSource:
  versions:
    "4.4.38":
      sourceRevision = "v4.4.38"
      sourceUrl = "https://github.com/besser82/libxcrypt/releases/download/v4.4.38/libxcrypt-4.4.38.tar.xz"
      sourceRepository = "https://github.com/besser82/libxcrypt"
  fetch:
    url: "https://github.com/besser82/libxcrypt/releases/download/v4.4.38/libxcrypt-4.4.38.tar.xz"
    sha256: "80304b9c306ea799327f01d9a7549bdb28317789182631f1b54f4511b4206dd6"
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
        "--disable-static", "--enable-shared", "--enable-hashes=strong,glibc",
      ])
      discard pkg.library("libcrypt")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    discard
