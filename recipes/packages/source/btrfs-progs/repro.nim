## Source-from-tarball btrfs-progs recipe — closes M9.R.27 Gap 4 (G4).
##
## btrfs-progs ships the canonical Btrfs userspace utilities
## (``mkfs.btrfs``, ``btrfs``, ``btrfsck``, ``btrfs-image``,
## ``btrfs-tune``). autotools convention.
##
## Vendored at ``recipes/packages/source/btrfs-progs/vendor/btrfs-progs-v7.0.tar.xz``.
## sha256 = c286d6876cbcd72327a0b417e4cfd280353ec23e37b549fdbcd7800a832d9a99
## (4,989,268 bytes).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package btrfsProgsSource:
  versions:
    "7.0":
      sourceRevision = "v7.0"
      sourceUrl = "https://www.kernel.org/pub/linux/kernel/people/kdave/btrfs-progs/btrfs-progs-v7.0.tar.xz"
      sourceRepository = "https://github.com/kdave/btrfs-progs"

  fetch:
    url: "https://www.kernel.org/pub/linux/kernel/people/kdave/btrfs-progs/btrfs-progs-v7.0.tar.xz"
    sha256: "c286d6876cbcd72327a0b417e4cfd280353ec23e37b549fdbcd7800a832d9a99"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    "util-linux"   # libblkid + libuuid
    "lzo"          # transparent compression dep
    "zstd"         # transparent compression dep
    "libgcrypt"    # checksumming (sha256, blake2)
    "zlib"         # zlib compression dep
    "e2fsprogs"    # libext2fs (mkfs.btrfs --rootdir support)

  config:
    discard
  executable btrfs:
    discard
  executable mkfsBtrfs:
    discard
  executable btrfsck:
    discard
  executable btrfsImage:
    discard
  executable btrfsTune:
    discard
  library libBtrfs:
    discard

  build:
    setCurrentOwningPackageOverride("btrfsProgsSource")
    try:
      let opts = @[
        "--disable-static",
        "--enable-shared",
        "--disable-documentation",
        "--disable-python",
        "--disable-zoned",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("btrfs")
      discard pkg.executable("mkfsBtrfs")
      discard pkg.executable("btrfsck")
      discard pkg.executable("btrfsImage")
      discard pkg.executable("btrfsTune")
      discard pkg.library("libBtrfs")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
