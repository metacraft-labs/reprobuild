## Source-from-tarball e2fsprogs recipe — closes M9.R.27 Gap 4 (G4).
##
## e2fsprogs ships the canonical ext2/3/4 filesystem utilities
## (``mke2fs``, ``mkfs.ext4``, ``e2fsck``, ``tune2fs``, ``resize2fs``,
## ``debugfs``). autotools convention.
##
## Vendored at ``recipes/packages/source/e2fsprogs/vendor/e2fsprogs-1.47.2.tar.xz``.
## sha256 = 08242e64ca0e8194d9c1caad49762b19209a06318199b63ce74ae4ef2d74e63c
## (7,299,932 bytes).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package e2fsprogsSource:
  versions:
    "1.47.2":
      sourceRevision = "v1.47.2"
      sourceUrl = "https://www.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v1.47.2/e2fsprogs-1.47.2.tar.xz"
      sourceRepository = "https://git.kernel.org/pub/scm/fs/ext2/e2fsprogs.git"

  fetch:
    url: "https://www.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v1.47.2/e2fsprogs-1.47.2.tar.xz"
    sha256: "08242e64ca0e8194d9c1caad49762b19209a06318199b63ce74ae4ef2d74e63c"
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
    ## util-linux supplies libuuid (-> /dev/disk/by-uuid), libblkid (FS
    ## detection), and the parent kernel-include surface e2fsprogs shares.
    "util-linux"

  config:
    discard
  ## M9.R.29.7 — ``mkfs.ext4`` (period between verb and FS name) is a
  ## compat symlink to ``mke2fs`` that the PascalToKebab transformer
  ## can't represent. Use ``executableAlias`` per the dosfstools
  ## precedent (M9.R.28.4).
  executable mke2fs:
    discard
  executable e2fsck:
    discard
  executable tune2fs:
    discard
  executable resize2fs:
    discard
  executable debugfs:
    discard

  build:
    setCurrentOwningPackageOverride("e2fsprogsSource")
    try:
      let opts = @[
        "--disable-static",
        "--enable-shared",
        "--enable-elf-shlibs",
        "--disable-defrag",
        "--disable-fsck",
        "--disable-uuidd",
        "--disable-nls",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("mke2fs")
      discard pkg.executableAlias("mkfsExt4", "mkfs.ext4")
      discard pkg.executable("e2fsck")
      discard pkg.executable("tune2fs")
      discard pkg.executable("resize2fs")
      discard pkg.executable("debugfs")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
