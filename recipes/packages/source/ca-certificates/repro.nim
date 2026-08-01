## Pinned Mozilla trust bundle packaged from curl's immutable dated PEM.
## The payload is source data rather than an archive or compiled program,
## so the fetch registry uses ``dataFile: true`` and the build only installs
## the verified bytes into the standard Linux trust-store locations.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package caCertificatesSource:
  versions:
    "2026-07-16":
      sourceRevision = "2026-07-16"
      sourceUrl = "https://curl.se/ca/cacert-2026-07-16.pem"
      sourceRepository = "https://hg.mozilla.org/projects/nss"

  fetch:
    url: "https://curl.se/ca/cacert-2026-07-16.pem"
    sha256: "3ff344e30b9b1ed2971044eabb438a08f2e2245ddb5f8ab1a3ad8b63ab4eaf91"
    dataFile: true
    extractStrip: 0

  nativeBuildDeps:
    "make"

  buildDeps:
    discard

  config:
    discard

  files caBundle:
    ## Installs the canonical bundle and a Fedora-compatible alias.
    discard

  build:
    setCurrentOwningPackageOverride("caCertificatesSource")
    try:
      let patches = @[
        "printf '%b\\n' 'all:' '\\t@:' 'install:' " &
          "'\\tmkdir -p $(DESTDIR)/etc/ssl/certs $(DESTDIR)/etc/pki/tls' " &
          "'\\tcp source $(DESTDIR)/etc/ssl/certs/ca-certificates.crt' " &
          "'\\tchmod 0644 $(DESTDIR)/etc/ssl/certs/ca-certificates.crt' " &
          "'\\tln -sf ../../ssl/certs/ca-certificates.crt $(DESTDIR)/etc/pki/tls/cert.pem' " &
          "> src/Makefile",
      ]
      let pkg = autotools_package(
        srcDir = "./src",
        configureOptions = @[],
        skipConfigure = true,
        srcPatches = patches)
      pkg.installTreeMirror()
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
