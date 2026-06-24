## Source-from-tarball LVM2 recipe — closes M9.R.27 Gap 4 (G4).
##
## LVM2 ships the logical-volume management suite (``lvcreate``,
## ``vgcreate``, ``pvcreate``, ``lvs``, ``vgs``, ``pvs``) plus the
## libdevmapper.so library (consumed by cryptsetup + parted).
## autotools convention.
##
## Vendored at ``recipes/packages/source/lvm2/vendor/LVM2.2.03.30.tgz``.
## sha256 = ad76abecb8dc887733e06c449cb9add04a3506f9f0780c128817a6e1a17cec05
## (2,864,622 bytes).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package lvm2Source:
  versions:
    "2.03.30":
      sourceRevision = "v2_03_30"
      sourceUrl = "https://mirrors.kernel.org/sourceware/lvm2/LVM2.2.03.30.tgz"
      sourceRepository = "https://sourceware.org/git/lvm2.git"

  fetch:
    url: "https://mirrors.kernel.org/sourceware/lvm2/LVM2.2.03.30.tgz"
    sha256: "ad76abecb8dc887733e06c449cb9add04a3506f9f0780c128817a6e1a17cec05"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    ## udev (libudev) for device hotplug integration.
    "libudev"
    ## readline for the lvm shell.
    "readline"
    ## util-linux for libblkid + libuuid.
    "util-linux"
    ## ncurses for the termcap library that readline links against.
    "ncurses"

  config:
    discard
  executable lvm:
    discard
  executable lvcreate:
    discard
  executable vgcreate:
    discard
  executable pvcreate:
    discard
  library libDevmapper:
    discard
  library libLvm2cmd:
    discard

  build:
    setCurrentOwningPackageOverride("lvm2Source")
    try:
      let opts = @[
        "--disable-static",
        "--enable-shared",
        "--enable-readline",
        "--enable-udev_sync",
        "--enable-udev_rules",
        "--enable-pkgconfig",
        "--disable-selinux",
        "--disable-nls",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("lvm")
      discard pkg.executable("lvcreate")
      discard pkg.executable("vgcreate")
      discard pkg.executable("pvcreate")
      discard pkg.library("libDevmapper")
      discard pkg.library("libLvm2cmd")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
