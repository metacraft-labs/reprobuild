## macOS sandbox-tool: GNU awk (gawk), built from source via reprobuild Mode B.
##
## gawk provides ``gawk`` and the ``awk`` symlink/wrapper — SIP binaries under
## ``/usr/bin`` on macOS and a staple text-processing primitive build scripts
## shell out to, so the io-mon monitor must be able to redirect a SIP
## ``/usr/bin/awk`` exec to a NON-SIP, injectable drop-in we build. The
## from-source build links ONLY ``/usr/lib/libSystem.B.dylib`` (``otool -L``),
## so each binary is a portable, AMFI-safe drop-in.
##
## Build shape: the shared ``sandbox_tool`` Mode B template (see
## ``../sandbox_tool.nim``) over the vendored upstream 5.3.1 release tarball
## (committed ``configure``). Offline-reproducible via the ``file:./vendor/...``
## fetch URL. See ``reprobuild-specs/Package-Model.md`` (package shape) and
## ``Language-Conventions/C-Cpp-Autotools.md`` §"Mode B" (build flow).
##
## sha256 = 694db764812a6236423d4ff40ceb7b6c4c441301b72ad502bb5c27e00cd56f78
##   (the vendored ``gawk-5.3.1.tar.xz``).

import repro_project_dsl

import ../sandbox_tool

package sandboxGawk:
  ## From-source GNU awk for the macOS sandbox-tools bundle. ``make install``
  ## lays down both ``gawk`` (the real Mach-O) and an ``awk`` link to it; we
  ## register both names so the SIP redirect resolves ``/usr/bin/awk`` too.

  versions:
    "5.3.1":
      sourceRevision = "gawk-5.3.1"
      sourceUrl = "https://ftp.gnu.org/gnu/gawk/gawk-5.3.1.tar.xz"
      sourceRepository = "https://git.savannah.gnu.org/git/gawk.git"

  fetch:
    url: "file:./vendor/gawk-5.3.1.tar.xz"
    sha256: "694db764812a6236423d4ff40ceb7b6c4c441301b72ad502bb5c27e00cd56f78"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "make"
    "gcc >=11"

  config:
    discard

  executable gawk:
    discard
  executable awk:
    discard

  build:
    ## Mode B autotools build via the shared sandbox-tool template. We disable
    ## the optional MPFR/GMP arbitrary-precision support and dynamic-extension
    ## loading: both would pull non-libSystem dylibs (``libmpfr`` / ``libgmp``
    ## from the nix dev shell) and break the libSystem-only invariant. The
    ## sandbox ``awk`` only needs the standard POSIX text-processing language.
    sandboxAutotoolsPackage(
      owningPackage = "sandboxGawk",
      executables = @["gawk", "awk"],
      extraConfigure = @[
        "--disable-mpfr",
        "--disable-extensions",
      ])

  runtimeDeps:
    discard
