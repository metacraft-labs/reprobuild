## macOS sandbox-tool: GNU sed, built from source via reprobuild Mode B.
##
## sed provides ``sed`` — a SIP binary under ``/usr/bin`` on macOS and a core
## stream-editing primitive build scripts shell out to, so the io-mon monitor
## must be able to redirect a SIP ``/usr/bin/sed`` exec to a NON-SIP,
## injectable drop-in we build. The from-source build links ONLY
## ``/usr/lib/libSystem.B.dylib`` (``otool -L``), so the binary is a portable,
## AMFI-safe drop-in.
##
## Build shape: the shared ``sandbox_tool`` Mode B template (see
## ``../sandbox_tool.nim``) over the vendored upstream 4.9 release tarball
## (committed ``configure``). Offline-reproducible via the ``file:./vendor/...``
## fetch URL. See ``reprobuild-specs/Package-Model.md`` (package shape) and
## ``Language-Conventions/C-Cpp-Autotools.md`` §"Mode B" (build flow).
##
## sha256 = 6e226b732e1cd739464ad6862bd1a1aba42d7982922da7a53519631d24975181
##   (the vendored ``sed-4.9.tar.xz``).

import repro_project_dsl

import ../sandbox_tool

package sandboxGnused:
  ## From-source GNU sed for the macOS sandbox-tools bundle.

  versions:
    "4.9":
      sourceRevision = "v4.9"
      sourceUrl = "https://ftp.gnu.org/gnu/sed/sed-4.9.tar.xz"
      sourceRepository = "https://git.savannah.gnu.org/git/sed.git"

  fetch:
    url: "file:./vendor/sed-4.9.tar.xz"
    sha256: "6e226b732e1cd739464ad6862bd1a1aba42d7982922da7a53519631d24975181"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "make"
    "gcc >=11"

  config:
    discard

  executable sed:
    discard

  build:
    ## Mode B autotools build via the shared sandbox-tool template. The shared
    ## defaults (``--disable-nls`` etc.) already keep sed libSystem-only; no
    ## per-tool configure flag is required.
    sandboxAutotoolsPackage(
      owningPackage = "sandboxGnused",
      executables = @["sed"])

  runtimeDeps:
    discard
