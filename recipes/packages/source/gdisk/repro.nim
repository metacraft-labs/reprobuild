## Source-from-tarball gptfdisk recipe — closes M9.R.27 Gap 4 (G4).
##
## gptfdisk provides ``gdisk``, ``cgdisk``, ``sgdisk``, ``fixparts`` —
## GPT partition table editors paired with the BIOS-era ``fdisk``. Make
## driven (no autoconf).
##
## Vendored at ``recipes/packages/source/gdisk/vendor/gptfdisk-1.0.10.tar.gz``.
## sha256 = 2abed61bc6d2b9ec498973c0440b8b804b7a72d7144069b5a9209b2ad693a282
## (220,787 bytes).
##
## gptfdisk is a raw Makefile project (no ``./configure``), so we use
## the autotools convention with ``skipConfigure = true`` (same shape
## as the duktape recipe in M9.R.26.3).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package gdiskSource:
  versions:
    "1.0.10":
      sourceRevision = "v1.0.10"
      sourceUrl = "https://downloads.sourceforge.net/gptfdisk/gptfdisk-1.0.10.tar.gz"
      sourceRepository = "https://www.rodsbooks.com/gdisk/"

  fetch:
    url: "https://downloads.sourceforge.net/gptfdisk/gptfdisk-1.0.10.tar.gz"
    sha256: "2abed61bc6d2b9ec498973c0440b8b804b7a72d7144069b5a9209b2ad693a282"
    extractStrip: 1

  nativeBuildDeps:
    "make"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    ## ncurses for cgdisk's curses UI.
    "ncurses"
    ## popt for option parsing.
    "popt"
    ## util-linux for libuuid.
    "util-linux"

  config:
    discard
  executable gdisk:
    discard
  executable sgdisk:
    discard
  executable cgdisk:
    discard
  executable fixparts:
    discard

  build:
    setCurrentOwningPackageOverride("gdiskSource")
    try:
      let sourceRoot = "/opt/repro/reprobuild/recipes/packages/source"
      let utilLinux = sourceRoot & "/util-linux/.repro/output/install/usr"
      let popt = sourceRoot & "/popt/.repro/output/install/usr"
      let ncurses = sourceRoot & "/ncurses/.repro/output/install/usr"
      let sourceRpath =
        utilLinux & "/lib:" & popt & "/lib:" & ncurses & "/lib"
      let opts = @[
        "CXXFLAGS=-O2 -Wall -D_FILE_OFFSET_BITS=64" &
          " -I" & utilLinux & "/include" &
          " -I" & popt & "/include" &
          " -I" & ncurses & "/include",
        "LDFLAGS=-L" & utilLinux & "/lib" &
          " -L" & popt & "/lib" &
          " -L" & ncurses & "/lib" &
          " -Wl,-rpath," & utilLinux & "/lib" &
          " -Wl,-rpath," & popt & "/lib" &
          " -Wl,-rpath," & ncurses & "/lib",
        "LDLIBS=-luuid",
        "SGDISK_LDLIBS=-lpopt",
        "CGDISK_LDLIBS=-lncursesw -ltinfow",
      ]
      let pkg = autotools_package(srcDir = "./src",
                                  configureOptions = opts,
                                  skipConfigure = true,
                                  srcPatches = @[
        # Our wide-character ncurses build installs the portable header as
        # /usr/include/ncurses.h while retaining the ncursesw library ABI.
        "sed -i 's|<ncursesw/ncurses.h>|<ncurses.h>|' ./src/gptcurses.cc",
        "printf '\ninstall: all\n\tmkdir -p $(DESTDIR)/usr/sbin\n" &
          "\tfor binary in gdisk sgdisk cgdisk fixparts; do " &
          "old=$$(patchelf --print-rpath $$binary); " &
          "patchelf --set-rpath " & sourceRpath & ":$$old $$binary; done\n" &
          "\tcp -f gdisk sgdisk cgdisk fixparts $(DESTDIR)/usr/sbin/\n' " &
          ">> ./src/Makefile",
      ])
      discard pkg.executable("gdisk")
      discard pkg.executable("sgdisk")
      discard pkg.executable("cgdisk")
      discard pkg.executable("fixparts")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
