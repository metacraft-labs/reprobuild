## Source-from-tarball cryptsetup recipe — closes M9.R.27 Gap 4 (G4).
##
## cryptsetup ships ``cryptsetup`` (LUKS / dm-crypt manager) +
## ``veritysetup``, ``integritysetup``, libcryptsetup.so. autotools
## convention.
##
## Vendored at ``recipes/packages/source/cryptsetup/vendor/cryptsetup-2.7.5.tar.gz``.
## sha256 = da290c93b17c913540b97ca177f107e22032c56e5371076d2d30e97f1fffa4cf
## (11,847,138 bytes).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package cryptsetupSource:
  versions:
    "2.7.5":
      sourceRevision = "v2.7.5"
      sourceUrl = "https://gitlab.com/cryptsetup/cryptsetup/-/archive/v2.7.5/cryptsetup-v2.7.5.tar.gz"
      sourceRepository = "https://gitlab.com/cryptsetup/cryptsetup"

  fetch:
    url: "https://gitlab.com/cryptsetup/cryptsetup/-/archive/v2.7.5/cryptsetup-v2.7.5.tar.gz"
    sha256: "da290c93b17c913540b97ca177f107e22032c56e5371076d2d30e97f1fffa4cf"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"
    "gettext"

  buildDeps:
    ## libgcrypt is the default crypto backend.
    "libgcrypt"
    ## json-c is required for the LUKS2 metadata JSON parser.
    "json-c"
    ## popt for option parsing.
    "popt"
    ## device-mapper (libdevmapper.so) is the kernel-dm userspace
    ## interface cryptsetup talks to.
    "device-mapper"
    ## util-linux for libuuid + libblkid.
    "util-linux"

  config:
    discard
  executable cryptsetup:
    discard
  executable veritysetup:
    discard
  executable integritysetup:
    discard
  library libCryptsetup:
    discard

  build:
    setCurrentOwningPackageOverride("cryptsetupSource")
    try:
      # M9.R.29.9b — disable the optional plugins that pull in libssh /
      # libfido2 / libpwquality / libpasswdqc / udev. None are needed
      # for the v1 live-ISO LUKS-via-passphrase installer flow; their
      # absence keeps configure from hard-erroring at pkg-config.
      let opts = @[
        "--disable-static",
        "--enable-shared",
        "--enable-cryptsetup-reencrypt",
        "--with-crypto_backend=gcrypt",
        "--disable-nls",
        "--disable-asciidoc",
        "--disable-ssh-token",
        "--disable-fido2-token",
        "--disable-pwquality",
        "--disable-passwdqc",
        "--disable-udev",
        "--enable-internal-argon2",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts,
                                  patchHardcodedFile = true)
      discard pkg.executable("cryptsetup")
      discard pkg.executable("veritysetup")
      discard pkg.executable("integritysetup")
      discard pkg.library("libCryptsetup")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
