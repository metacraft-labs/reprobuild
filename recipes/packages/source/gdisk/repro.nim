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
      let pkg = autotools_package(srcDir = "./src",
                                  configureOptions = @[],
                                  skipConfigure = true)
      discard pkg.executable("gdisk")
      discard pkg.executable("sgdisk")
      discard pkg.executable("cgdisk")
      discard pkg.executable("fixparts")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
