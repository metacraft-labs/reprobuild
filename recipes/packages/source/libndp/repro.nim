## Source build for libndp, the IPv6 Neighbor Discovery library used
## by NetworkManager. Version and source hash match nixpkgs' libndp
## 1.9 package.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libndpSource:
  versions:
    "1.9":
      sourceRevision = "v1.9"
      sourceUrl = "http://libndp.org/files/libndp-1.9.tar.gz"
      sourceRepository = "https://github.com/jpirko/libndp"

  fetch:
    url: "http://libndp.org/files/libndp-1.9.tar.gz"
    sha256: "a8ab214e01dc3a9b615276905395637f391298c84d77651f0cbf0b1082dd2dd4"
    extractStrip: 1

  nativeBuildDeps:
    ## The release archive includes generated autotools files, while
    ## these tools keep the recipe robust to regenerated inputs.
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"

  config:
    discard

  library libNdp:
    ## libndp.so implements Router and Neighbor Discovery messages.
    discard

  build:
    setCurrentOwningPackageOverride("libndpSource")
    try:
      let opts = @[
        "--disable-static",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libNdp")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## libndp has no external runtime library beyond libc.
    discard
