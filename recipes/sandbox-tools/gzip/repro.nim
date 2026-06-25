## macOS sandbox-tool: GNU gzip, built from source via reprobuild Mode B.
##
## gzip provides ``gzip`` plus the ``gunzip`` / ``zcat`` wrappers — SIP binaries
## under ``/usr/bin`` on macOS and core (de)compression primitives build scripts
## shell out to, so the io-mon monitor must be able to redirect a SIP
## ``/usr/bin/gzip`` exec to a NON-SIP, injectable drop-in we build. The
## from-source build links ONLY ``/usr/lib/libSystem.B.dylib`` (``otool -L``),
## so each binary is a portable, AMFI-safe drop-in.
##
## Build shape: the shared ``sandbox_tool`` Mode B template (see
## ``../sandbox_tool.nim``) over the vendored upstream 1.13 release tarball
## (committed ``configure``). Offline-reproducible via the ``file:./vendor/...``
## fetch URL. See ``reprobuild-specs/Package-Model.md`` (package shape) and
## ``Language-Conventions/C-Cpp-Autotools.md`` §"Mode B" (build flow). gzip is
## the very package the Phase-2 milestone used to PROVE the gnulib Mode B route,
## so it is the simplest confirmation that the full set builds.
##
## # Portability note (gunzip / zcat)
##
## ``gunzip`` / ``zcat`` are installed by ``make install`` as small shell-script
## wrappers (``exec gzip -d`` / ``exec gzip -cd``), not separate Mach-O
## binaries, so the bundle assembler copies them verbatim. We register all three
## names so the artifact registry enumerates them.
##
## sha256 = 7454eb6935db17c6655576c2e1b0fabefd38b4d0936e0f87f48cd062ce91a057
##   (the vendored ``gzip-1.13.tar.xz``).

import repro_project_dsl

import ../sandbox_tool

package sandboxGzip:
  ## From-source GNU gzip for the macOS sandbox-tools bundle.

  versions:
    "1.13":
      sourceRevision = "v1.13"
      sourceUrl = "https://ftp.gnu.org/gnu/gzip/gzip-1.13.tar.xz"
      sourceRepository = "https://git.savannah.gnu.org/git/gzip.git"

  fetch:
    url: "file:./vendor/gzip-1.13.tar.xz"
    sha256: "7454eb6935db17c6655576c2e1b0fabefd38b4d0936e0f87f48cd062ce91a057"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "make"
    "gcc >=11"

  config:
    discard

  executable gzip:
    discard
  executable gunzip:
    discard
  executable zcat:
    discard

  build:
    ## Mode B autotools build via the shared sandbox-tool template. gzip has its
    ## own DEFLATE implementation (no external ``libz``), so the shared defaults
    ## already produce a libSystem-only binary; no per-tool configure flag is
    ## required.
    sandboxAutotoolsPackage(
      owningPackage = "sandboxGzip",
      executables = @["gzip", "gunzip", "zcat"])

  runtimeDeps:
    discard
