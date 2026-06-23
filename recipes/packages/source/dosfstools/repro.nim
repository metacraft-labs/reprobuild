## Source-from-tarball dosfstools recipe — closes M9.R.27 Gap 4 (G4).
##
## dosfstools ships ``mkfs.fat`` (UEFI ESP creation), ``fatlabel``,
## ``fsck.fat``. autotools convention.
##
## Vendored at ``recipes/packages/source/dosfstools/vendor/dosfstools-4.2.tar.gz``.
## sha256 = 64926eebf90092dca21b14259a5301b7b98e7b1943e8a201c7d726084809b527
## (320,917 bytes).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package dosfstoolsSource:
  versions:
    "4.2":
      sourceRevision = "v4.2"
      sourceUrl = "https://github.com/dosfstools/dosfstools/releases/download/v4.2/dosfstools-4.2.tar.gz"
      sourceRepository = "https://github.com/dosfstools/dosfstools"

  fetch:
    url: "https://github.com/dosfstools/dosfstools/releases/download/v4.2/dosfstools-4.2.tar.gz"
    sha256: "64926eebf90092dca21b14259a5301b7b98e7b1943e8a201c7d726084809b527"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    discard

  config:
    discard
  executable mkfsFat:
    discard
  executable fsckFat:
    discard
  executable fatlabel:
    discard

  build:
    setCurrentOwningPackageOverride("dosfstoolsSource")
    try:
      let opts = @[
        "--enable-compat-symlinks",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("mkfsFat")
      discard pkg.executable("fsckFat")
      discard pkg.executable("fatlabel")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
