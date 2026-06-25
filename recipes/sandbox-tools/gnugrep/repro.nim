## macOS sandbox-tool: GNU grep, built from source via reprobuild Mode B.
##
## grep provides ``grep`` plus the ``egrep`` / ``fgrep`` wrappers — SIP binaries
## under ``/usr/bin`` on macOS and ubiquitous in build scripts (pattern matching
## over command output), so the io-mon monitor must be able to redirect a SIP
## ``/usr/bin/grep`` exec to a NON-SIP, injectable drop-in we build. The
## from-source build links ONLY ``/usr/lib/libSystem.B.dylib`` (``otool -L``),
## so each binary is a portable, AMFI-safe drop-in.
##
## Build shape: the shared ``sandbox_tool`` Mode B template (see
## ``../sandbox_tool.nim``) over the vendored upstream 3.11 release tarball
## (committed ``configure``). Offline-reproducible via the ``file:./vendor/...``
## fetch URL. See ``reprobuild-specs/Package-Model.md`` (package shape) and
## ``Language-Conventions/C-Cpp-Autotools.md`` §"Mode B" (build flow).
##
## # Portability note (egrep / fgrep)
##
## Modern GNU grep ships ``egrep`` / ``fgrep`` as tiny shell-script wrappers
## (``exec grep -E``/``-F``) rather than separate binaries; they are installed
## into ``<stage>/usr/bin`` by ``make install`` and are libSystem-agnostic
## scripts, so the bundle assembler copies them verbatim alongside the ``grep``
## Mach-O. We register all three names so the artifact registry enumerates them.
##
## sha256 = 1db2aedde89d0dea42b16d9528f894c8d15dae4e190b59aecc78f5a951276eab
##   (the vendored ``grep-3.11.tar.xz``).

import repro_project_dsl

import ../sandbox_tool

package sandboxGnugrep:
  ## From-source GNU grep for the macOS sandbox-tools bundle.

  versions:
    "3.11":
      sourceRevision = "v3.11"
      sourceUrl = "https://ftp.gnu.org/gnu/grep/grep-3.11.tar.xz"
      sourceRepository = "https://git.savannah.gnu.org/git/grep.git"

  fetch:
    url: "file:./vendor/grep-3.11.tar.xz"
    sha256: "1db2aedde89d0dea42b16d9528f894c8d15dae4e190b59aecc78f5a951276eab"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "make"
    "gcc >=11"

  config:
    discard

  executable grep:
    discard
  executable egrep:
    discard
  executable fgrep:
    discard

  build:
    ## Mode B autotools build via the shared sandbox-tool template.
    ##
    ##   * ``--disable-perl-regexp`` — force the gnulib PCRE probe OFF. The nix
    ##     dev shell puts ``libpcre2`` on the search path, and a ``grep -P``-
    ##     enabled build would record a /nix/store ``libpcre2`` dependency,
    ##     breaking the libSystem-only invariant. The sandbox ``grep`` only needs
    ##     POSIX BRE/ERE/FRE.
    ##   * ``am_cv_func_iconv=no`` / ``am_cv_lib_iconv=no`` /
    ##     ``--without-libiconv-prefix`` — force gnulib's iconv probe to "no".
    ##     Exactly as in the bash recipe: the nix dev shell exposes
    ##     ``/nix/store/.../libiconv``, so an unforced build links ``-liconv`` and
    ##     records a /nix/store ``libiconv.2.dylib`` dependency. macOS provides
    ##     iconv through libSystem, so seeding these autoconf config-cache
    ##     variables (``VAR=value`` configure args, applied before the probe runs)
    ##     makes grep use the libSystem iconv symbols directly and stay
    ##     libSystem-only.
    sandboxAutotoolsPackage(
      owningPackage = "sandboxGnugrep",
      executables = @["grep", "egrep", "fgrep"],
      extraConfigure = @[
        "--disable-perl-regexp",
        "--without-libiconv-prefix",
        "am_cv_func_iconv=no",
        "am_cv_lib_iconv=no",
      ])

  runtimeDeps:
    discard
