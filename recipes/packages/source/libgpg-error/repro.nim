## From-source recipe for libgpg-error, the common error-code and
## portability library used by libgcrypt and other GnuPG components.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libgpgErrorSource:
  versions:
    "1.51":
      sourceRevision = "libgpg-error-1.51"
      sourceUrl = "https://gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.51.tar.bz2"
      sourceRepository = "https://dev.gnupg.org/source/libgpg-error"

  fetch:
    url: "https://gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.51.tar.bz2"
    sha256: "be0f1b2db6b93eed55369cdf79f19f72750c8c7c39fc20b577e724545427e6b2"
    extractStrip: 1

  nativeBuildDeps:
    "make"
    "gcc >=11"
    "pkg-config"

  config:
    discard

  library libGpgError:
    discard

  build:
    setCurrentOwningPackageOverride("libgpgErrorSource")
    try:
      let pkg = autotools_package(
        srcDir = "./src",
        configureOptions = @["--disable-static", "--disable-nls"],
      )
      discard pkg.library("libGpgError")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
