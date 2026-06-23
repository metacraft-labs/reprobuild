## Source-from-tarball libxshmfence recipe — M9.R.27.3 Gap 3 prep.
##
## libxshmfence is the shared-memory fence-based synchronisation
## primitive xwayland's DRI3 codepath uses for GL synchronisation.
##
## Vendored at ``recipes/packages/source/libxshmfence/vendor/libxshmfence-1.3.3.tar.xz``.
## sha256 = d4a4df096aba96fea02c029ee3a44e11a47eb7f7213c1a729be83e85ec3fde10
## (264,860 bytes).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libxshmfenceSource:
  versions:
    "1.3.3":
      sourceRevision = "libxshmfence-1.3.3"
      sourceUrl = "https://www.x.org/releases/individual/lib/libxshmfence-1.3.3.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libxshmfence"

  fetch:
    url: "https://www.x.org/releases/individual/lib/libxshmfence-1.3.3.tar.xz"
    sha256: "d4a4df096aba96fea02c029ee3a44e11a47eb7f7213c1a729be83e85ec3fde10"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    "xorgproto"

  config:
    discard
  library libXshmfence:
    discard

  build:
    setCurrentOwningPackageOverride("libxshmfenceSource")
    try:
      let opts = @["--disable-static", "--enable-shared"]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libXshmfence")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
