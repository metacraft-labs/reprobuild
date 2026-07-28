## Source-built rsync for ReproOS root-mirror installation.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package rsyncSource:
  versions:
    "3.4.4":
      sourceRevision = "v3.4.4"
      sourceUrl = "https://download.samba.org/pub/rsync/src/rsync-3.4.4.tar.gz"
      sourceRepository = "https://github.com/RsyncProject/rsync"

  fetch:
    url: "https://download.samba.org/pub/rsync/src/rsync-3.4.4.tar.gz"
    sha256: "bd88cf82fa653da32314fb229136407c5c90f80d1758d8f4b091767877d8fa96"
    extractStrip: 1

  nativeBuildDeps:
    "make"
    "gcc >=11"

  buildDeps:
    discard

  config:
    discard

  executable rsync:
    discard

  build:
    setCurrentOwningPackageOverride("rsyncSource")
    try:
      # Keep the install-time mirror tool independent of optional libraries
      # that are not yet part of the ReproOS source closure.
      let opts = @[
        "--disable-xxhash",
        "--disable-zstd",
        "--disable-lz4",
        "--disable-openssl",
        "--disable-md2man",
        "--disable-acl-support",
        "--disable-xattr-support",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("rsync")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
