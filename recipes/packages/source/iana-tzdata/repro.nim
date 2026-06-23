## Source-from-tarball IANA tzdata recipe — closes M9.R.27 Gap 4 (G4).
##
## tzdata is the IANA Time Zone Database. The recipe ships the
## data-only payload that becomes /usr/share/zoneinfo on the live ISO,
## consumed by libc + systemd-timesyncd for local-time conversion.
##
## Vendored at ``recipes/packages/source/iana-tzdata/vendor/tzdata2024b.tar.gz``.
## sha256 = 70e754db126a8d0db3d16d6b4cb5f7ec1e04d5f261255e4558a67fe92d39e550
## (459,393 bytes).
##
## ## Build shape
##
## tzdata's upstream is plain ``make`` against the canonical Makefile
## (no autoconf). The Makefile reads ``TOPDIR`` + ``ZIC=zic`` and
## populates ``$TOPDIR/usr/share/zoneinfo`` with the compiled binary
## TZif catalog when invoked as ``make install TOPDIR=$DESTDIR``.
##
## Uses the autotools convention with ``skipConfigure = true`` (same
## shape as gptfdisk + duktape).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package ianaTzdataSource:
  versions:
    "2024b":
      sourceRevision = "2024b"
      sourceUrl = "https://data.iana.org/time-zones/releases/tzdata2024b.tar.gz"
      sourceRepository = "https://github.com/eggert/tz"

  fetch:
    url: "https://data.iana.org/time-zones/releases/tzdata2024b.tar.gz"
    sha256: "70e754db126a8d0db3d16d6b4cb5f7ec1e04d5f261255e4558a67fe92d39e550"
    extractStrip: 0

  nativeBuildDeps:
    "make"
    "gcc >=11"
    ## tzcode (sibling tarball) ships the ``zic`` compiler. For now we
    ## use the host's zic via gcc-compiled fallback at first build time.

  buildDeps:
    discard

  config:
    discard

  build:
    setCurrentOwningPackageOverride("ianaTzdataSource")
    try:
      let pkg = autotools_package(srcDir = "./src",
                                  configureOptions = @[],
                                  skipConfigure = true)
      discard pkg
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
