## Source-from-tarball IANA tzdata recipe — closes M9.R.27 Gap 4 (G4),
## end-to-end built in M9.R.28.4.
##
## tzdata is the IANA Time Zone Database. The recipe ships the
## data-only payload that becomes /usr/share/zoneinfo on the live ISO,
## consumed by libc + systemd-timesyncd for local-time conversion.
##
## ## M9.R.28.4 — combined-source vendor
##
## Earlier M9.R.27 vendored only the ``tzdata2024b.tar.gz`` data-only
## tarball; the Makefile inside that archive requires ``tzselect.ksh``
## + ``zic.c`` (from the SEPARATE ``tzcode2024b.tar.gz``) to build
## the ``zic`` compiler. The standalone data tarball therefore fails
## the ``all`` target with "No rule to make target 'tzselect.ksh'".
##
## Fix: re-vendor from the upstream Git tag tarball
## (``tz-2024b.tar.gz`` from github.com/eggert/tz) which combines
## tzcode + tzdata into a single source tree. The combined archive
## extracts to ``tz-2024b/`` (extractStrip: 1 unrolls one level).
##
## Vendored at
## ``recipes/packages/source/iana-tzdata/vendor/tz-2024b.tar.gz``.
## sha256 = 557c41d8eb5c29387a9d496db87c4aeb4f2ac8a2b6d5f60e869a8cade26e679c
## (619,499 bytes).
##
## ## Build shape
##
## Plain ``make`` against the canonical Makefile (no autoconf). The
## Makefile builds ``zic`` from tzcode then compiles tzdata's region
## files (africa, antarctica, asia, etc.) into the TZif binary
## catalog under ``$TOPDIR/usr/share/zoneinfo``.
##
## Uses the autotools convention with ``skipConfigure = true`` (no
## ./configure to run).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package ianaTzdataSource:
  versions:
    "2024b":
      sourceRevision = "2024b"
      sourceUrl = "https://github.com/eggert/tz/archive/refs/tags/2024b.tar.gz"
      sourceRepository = "https://github.com/eggert/tz"

  fetch:
    url: "https://github.com/eggert/tz/archive/refs/tags/2024b.tar.gz"
    sha256: "557c41d8eb5c29387a9d496db87c4aeb4f2ac8a2b6d5f60e869a8cade26e679c"
    extractStrip: 1

  nativeBuildDeps:
    "make"
    "gcc >=11"

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
