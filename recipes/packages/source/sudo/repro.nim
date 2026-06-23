## Source-from-tarball sudo recipe — closes M9.R.27 Gap 4 (G4).
##
## sudo is the canonical per-command privilege-escalation tool the
## ReproOS live ISO ships in /usr/bin. Replaces Debian's apt ``sudo``
## package. autotools convention.
##
## ## sha256 strategy
##
## Vendored at ``recipes/packages/source/sudo/vendor/sudo-1.9.16p2.tar.gz``.
##
## sha256 = 976aa56d3e3b2a75593307864288addb748c9c136e25d95a9cc699aafa77239c
##  (computed locally over the 5,398,419-byte vendored tarball).
##
## ## Version choice — 1.9.16p2 (current upstream stable)
##
## sudo releases live at sudo.ws. 1.9.16p2 is the current stable as of
## mid-2026.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package sudoSource:
  versions:
    "1.9.16p2":
      sourceRevision = "SUDO_1_9_16p2"
      sourceUrl = "https://www.sudo.ws/dist/sudo-1.9.16p2.tar.gz"
      sourceRepository = "https://github.com/sudo-project/sudo"

  fetch:
    url: "https://www.sudo.ws/dist/sudo-1.9.16p2.tar.gz"
    sha256: "976aa56d3e3b2a75593307864288addb748c9c136e25d95a9cc699aafa77239c"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    "pam"
    "libxcrypt"

  config:
    discard
  executable sudo:
    discard
  executable sudoedit:
    discard

  build:
    setCurrentOwningPackageOverride("sudoSource")
    try:
      let opts = @[
        "--disable-static",
        "--enable-shared",
        "--with-pam",
        "--without-ldap",
        "--without-sssd",
        "--without-aixauth",
        "--without-kerb5",
        "--disable-nls",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("sudo")
      discard pkg.executable("sudoedit")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
