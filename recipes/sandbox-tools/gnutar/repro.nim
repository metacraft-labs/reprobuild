## macOS sandbox-tool: GNU tar, built from source via reprobuild Mode B.
##
## tar provides ``tar`` — a SIP binary under ``/usr/bin`` on macOS and a core
## archiving primitive build scripts shell out to (unpacking sources, packaging
## outputs), so the io-mon monitor must be able to redirect a SIP
## ``/usr/bin/tar`` exec to a NON-SIP, injectable drop-in we build. The
## from-source build links ONLY ``/usr/lib/libSystem.B.dylib`` (``otool -L``),
## so the binary is a portable, AMFI-safe drop-in.
##
## Build shape: the shared ``sandbox_tool`` Mode B template (see
## ``../sandbox_tool.nim``) over the vendored upstream 1.35 release tarball
## (committed ``configure``). Offline-reproducible via the ``file:./vendor/...``
## fetch URL. See ``reprobuild-specs/Package-Model.md`` (package shape) and
## ``Language-Conventions/C-Cpp-Autotools.md`` §"Mode B" (build flow).
##
## sha256 = 4d62ff37342ec7aed748535323930c7cf94acf71c3591882b26a7ea50f3edc16
##   (the vendored ``tar-1.35.tar.xz``).

import repro_project_dsl

import ../sandbox_tool

package sandboxGnutar:
  ## From-source GNU tar for the macOS sandbox-tools bundle.

  versions:
    "1.35":
      sourceRevision = "release_1_35"
      sourceUrl = "https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz"
      sourceRepository = "https://git.savannah.gnu.org/git/tar.git"

  fetch:
    url: "file:./vendor/tar-1.35.tar.xz"
    sha256: "4d62ff37342ec7aed748535323930c7cf94acf71c3591882b26a7ea50f3edc16"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "make"
    "gcc >=11"

  config:
    discard

  executable tar:
    discard

  build:
    ## Mode B autotools build via the shared sandbox-tool template. ``tar``
    ## invokes ``gzip`` / ``xz`` (the sibling sandbox drop-ins) as external child
    ## processes for compression, so it needs no in-process ``libz`` /
    ## ``liblzma`` and stays libSystem-only via the shared ``-dead_strip_dylibs``
    ## LDFLAGS.
    ##
    ## NOTE: GNU tar's ``--with-rmt`` expects a PATH argument (the rmt binary),
    ## not a boolean — passing ``--without-rmt`` makes configure abort with
    ## "Invalid argument to --with-rmt". The rmt remote-tape helper is irrelevant
    ## to the sandbox; we simply leave it at its default (tar builds its own
    ## ``rmt`` but the bundle assembler only harvests the ``tar`` drop-in), so no
    ## per-tool configure flag is needed here.
    ## iconv: unlike grep (whose iconv reference is dead and dropped by
    ## ``-dead_strip_dylibs``), GNU tar GENUINELY calls ``iconv`` / ``iconv_open``
    ## (filename charset conversion for ``--to-command`` / non-UTF names). On
    ## this Nix clang toolchain ``_iconv`` is provided ONLY by the Nix
    ## ``libiconv`` (the macOS SDK libSystem stub does not export it), so a tar
    ## that references iconv would either record a /nix/store ``libiconv.2.dylib``
    ## dependency (non-portable) or fail to link once that dylib is dead-stripped.
    ## We therefore compile tar's iconv usage OUT via the gnulib config-cache
    ## ``am_cv_func_iconv=no`` (+ ``--without-libiconv-prefix``), exactly as in the
    ## bash/grep recipes. tar then uses byte-identity for filename charsets — fine
    ## for the sandbox, whose drop-ins archive/extract build trees, not exotic
    ## multibyte filenames — and stays libSystem-only.
    sandboxAutotoolsPackage(
      owningPackage = "sandboxGnutar",
      executables = @["tar"],
      extraConfigure = @[
        "--without-libiconv-prefix",
        "am_cv_func_iconv=no",
        "am_cv_lib_iconv=no",
      ])

  runtimeDeps:
    discard
