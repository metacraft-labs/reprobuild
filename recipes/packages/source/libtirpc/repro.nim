## Source-from-tarball libtirpc recipe — M9.R.27.3 Gap 3 prep.
##
## libtirpc is the Sun RPC userspace library xwayland's secure-RPC
## xauth helpers consume (post-glibc-RPC-removal).
##
## Vendored at ``recipes/packages/source/libtirpc/vendor/libtirpc-1.3.6.tar.bz2``.
## sha256 = bbd26a8f0df5690a62a47f6aa30f797f3ef8d02560d1bc449a83066b5a1d3508
## (566,384 bytes).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libtirpcSource:
  versions:
    "1.3.6":
      sourceRevision = "libtirpc-1-3-6"
      sourceUrl = "https://downloads.sourceforge.net/libtirpc/libtirpc-1.3.6.tar.bz2"
      sourceRepository = "https://git.linux-nfs.org/?p=steved/libtirpc.git"

  fetch:
    url: "https://downloads.sourceforge.net/libtirpc/libtirpc-1.3.6.tar.bz2"
    sha256: "bbd26a8f0df5690a62a47f6aa30f797f3ef8d02560d1bc449a83066b5a1d3508"
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
  library libTirpc:
    discard

  build:
    setCurrentOwningPackageOverride("libtirpcSource")
    try:
      let opts = @[
        "--disable-static",
        "--enable-shared",
        "--disable-gssapi",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libTirpc")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
