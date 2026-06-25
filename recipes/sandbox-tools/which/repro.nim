## macOS sandbox-tool: GNU which, built from source via reprobuild Mode B.
##
## which provides ``which`` — the PATH-resolution helper build scripts shell out
## to when locating a command. macOS ships a (different) ``/usr/bin/which``; the
## sandbox bundle provides a portable, NON-SIP drop-in so a redirected
## ``/usr/bin/which`` exec lands on a binary WE build. The from-source build
## links ONLY ``/usr/lib/libSystem.B.dylib`` (``otool -L``), so the binary is a
## portable, AMFI-safe drop-in.
##
## Build shape: the shared ``sandbox_tool`` Mode B template (see
## ``../sandbox_tool.nim``) over the vendored upstream 2.21 release tarball
## (committed ``configure``) from the canonical GNU release host. Offline-
## reproducible via the ``file:./vendor/...`` fetch URL. See
## ``reprobuild-specs/Package-Model.md`` (package shape) and
## ``Language-Conventions/C-Cpp-Autotools.md`` §"Mode B" (build flow).
##
## sha256 = f4a245b94124b377d8b49646bf421f9155d36aa7614b6ebf83705d3ffc76eaad
##   (the vendored ``which-2.21.tar.gz``).

import repro_project_dsl

import ../sandbox_tool

package sandboxWhich:
  ## From-source GNU which for the macOS sandbox-tools bundle.

  versions:
    "2.21":
      sourceRevision = "v2.21"
      sourceUrl = "https://ftp.gnu.org/gnu/which/which-2.21.tar.gz"
      sourceRepository = "https://git.savannah.gnu.org/git/which.git"

  fetch:
    url: "file:./vendor/which-2.21.tar.gz"
    sha256: "f4a245b94124b377d8b49646bf421f9155d36aa7614b6ebf83705d3ffc76eaad"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "make"
    "gcc >=11"

  config:
    discard

  executable which:
    discard

  build:
    ## Mode B autotools build via the shared sandbox-tool template. ``which`` is
    ## a single small C program with no external library deps, so the shared
    ## defaults already produce a libSystem-only binary; no per-tool configure
    ## flag is required.
    sandboxAutotoolsPackage(
      owningPackage = "sandboxWhich",
      executables = @["which"])

  runtimeDeps:
    discard
