## macOS sandbox-tool: GNU bash, built from source via reprobuild Mode B.
##
## bash is THE drop-in for ``/bin/sh``: the io-mon SIP redirect points
## ``<DIR>/bin/sh`` → this bash so a monitored ``system("/bin/sh -c …")`` /
## ``posix_spawn(/bin/sh)`` lands on a NON-SIP, injectable shell instead of the
## AMFI-restricted Apple ``/bin/sh``. The from-source build links ONLY
## ``/usr/lib/libSystem.B.dylib`` (``otool -L``), so it is portable + AMFI-safe.
##
## Build shape: the shared ``sandbox_tool`` Mode B template (see
## ``../sandbox_tool.nim``) over the vendored upstream 5.2.37 release tarball
## (committed ``configure``). Offline-reproducible via the ``file:./vendor/...``
## fetch URL.
##
## # Portability-tuned configure flags (vs the Linux ``recipes/packages/source``
## # bash recipe)
##
##   * ``--without-bash-malloc`` — use the system (libSystem) malloc rather than
##     bash's vendored gmalloc, which is not needed on macOS and keeps the
##     allocator surface standard.
##   * ``--disable-readline`` + ``--without-readline`` — do NOT link an EXTERNAL
##     libreadline / libncurses (which would add non-libSystem dylib
##     dependencies and break portability). The sandbox ``sh`` is used non-
##     interactively (script execution under the monitor), so line-editing is
##     irrelevant; dropping readline keeps the binary libSystem-only.
##   * The shared template adds ``CFLAGS=-Wno-implicit-function-declaration`` so
##     bash 5.2's bundled ``lib/termcap/tparam.c`` (which calls ``write``
##     without a prototype) compiles under Apple clang's C23 default, where an
##     implicit function declaration is otherwise a hard error.
##
## sha256 = 9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff
##   (the vendored 11,128,314-byte ``bash-5.2.37.tar.gz``).

import repro_project_dsl

import ../sandbox_tool

package sandboxBash:
  ## From-source GNU bash for the macOS sandbox-tools bundle. One load-bearing
  ## binary (``bash``); the bundle assembler symlinks ``bin/sh`` → ``bash`` so a
  ## ``/bin/sh`` SIP redirect resolves.

  versions:
    "5.2.37":
      sourceRevision = "bash-5.2.37"
      sourceUrl = "https://ftp.gnu.org/gnu/bash/bash-5.2.37.tar.gz"
      sourceRepository = "https://git.savannah.gnu.org/git/bash.git"

  fetch:
    url: "file:./vendor/bash-5.2.37.tar.gz"
    sha256: "9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "make"
    "gcc >=11"
    "bison"

  config:
    discard

  executable bash:
    ## ``/bin/bash`` + the ``/bin/sh`` drop-in target (assembler symlinks sh →
    ## bash). The POSIX shell interpreter every monitored ``system()`` /
    ## ``sh -c`` grandchild is redirected to.
    discard

  build:
    ## Mode B autotools build via the shared sandbox-tool template, with the
    ## portability-tuned flags described in this module's header.
    sandboxAutotoolsPackage(
      owningPackage = "sandboxBash",
      executables = @["bash"],
      extraConfigure = @[
        "--without-bash-malloc",
        "--disable-readline",
        "--without-readline",
        # Portability: do NOT link an external libiconv. The nix dev shell puts
        # ``-L/nix/store/.../libiconv`` on the linker search path and bash's
        # gnulib iconv probe then succeeds, so the link line gets ``-liconv``
        # and the binary records a /nix/store libiconv.2.dylib dependency —
        # breaking the libSystem-only invariant. macOS provides iconv through
        # libSystem, so we force bash's autoconf iconv probe to "no" via the
        # ``am_cv_func_iconv`` / ``am_cv_lib_iconv`` config-cache variables
        # (passed as ``VAR=value`` configure arguments, which seed the cache
        # before the probe runs). bash's ``locale.c`` then uses the libSystem
        # iconv symbols directly with no external ``-liconv``.
        "--without-libiconv-prefix",
        "am_cv_func_iconv=no",
        "am_cv_lib_iconv=no",
      ])

  runtimeDeps:
    discard
