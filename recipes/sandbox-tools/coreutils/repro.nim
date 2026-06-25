## macOS sandbox-tool: GNU coreutils, built from source via reprobuild Mode B.
##
## coreutils provides the canonical POSIX userland — ``cat`` / ``ls`` / ``cp`` /
## ``mv`` / ``rm`` / ``mkdir`` / ``head`` / ``tail`` / ``wc`` / ``sort`` /
## ``cut`` / ``tr`` / ``basename`` / ``dirname`` / ``touch`` / ``true`` /
## ``false`` / ``printf`` / ``tee`` / ``env`` and ~90 more — every one a SIP
## binary under ``/bin`` + ``/usr/bin`` on macOS. The from-source build links
## ONLY ``/usr/lib/libSystem.B.dylib`` (``otool -L``), so each binary is a
## portable, AMFI-safe drop-in the io-mon monitor can redirect a SIP exec to
## (``rewriteSipPath("/bin/cat", DIR) == "DIR/bin/cat"``).
##
## Build shape: the shared ``sandbox_tool`` Mode B template (see
## ``../sandbox_tool.nim``) over the vendored upstream 9.5 release tarball
## (committed ``configure`` — avoids the io-mon ``autom4te`` bug). The fetch
## URL is a relative ``file:./vendor/...`` so the build is offline-reproducible.
##
## sha256 = cd328edeac92f6a665de9f323c93b712af1858bc2e0d88f3f7100469470a1b8a
##   (the vendored 6,007,136-byte ``coreutils-9.5.tar.xz``).

import repro_project_dsl

import ../sandbox_tool

package sandboxCoreutils:
  ## From-source GNU coreutils for the macOS sandbox-tools bundle. Registers the
  ## load-bearing drop-in binaries the io-mon SIP redirect + the bundle
  ## assembler need; the Mode B ``make`` invocation builds the full ~100-binary
  ## set regardless.

  versions:
    "9.5":
      sourceRevision = "v9.5"
      sourceUrl = "https://ftp.gnu.org/gnu/coreutils/coreutils-9.5.tar.xz"
      sourceRepository = "https://git.savannah.gnu.org/git/coreutils.git"

  fetch:
    ## Vendored tarball, referenced relative to the recipe dir so the recipe
    ## carries no host-absolute path and the build runs offline.
    url: "file:./vendor/coreutils-9.5.tar.xz"
    sha256: "cd328edeac92f6a665de9f323c93b712af1858bc2e0d88f3f7100469470a1b8a"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "make"
    "gcc >=11"
    "perl >=5.32"

  config:
    discard

  # The drop-in binaries the bundle lays out at <DIR>/bin + <DIR>/usr/bin. The
  # full coreutils set is built by the single make invocation; we enumerate the
  # ones the io-mon reproSandboxBinaries list + the SIP e2e test depend on.
  executable cat:
    discard
  executable ls:
    discard
  executable cp:
    discard
  executable mv:
    discard
  executable rm:
    discard
  executable mkdir:
    discard
  executable head:
    discard
  executable tail:
    discard
  executable wc:
    discard
  executable sort:
    discard
  executable cut:
    discard
  executable tr:
    discard
  executable basename:
    discard
  executable dirname:
    discard
  executable touch:
    discard
  executable env:
    discard
  executable printf:
    discard
  executable tee:
    discard

  build:
    ## Mode B autotools build via the shared sandbox-tool template.
    ## ``--enable-no-install-program`` drops the few binaries other macOS
    ## userland packages own (``kill`` from the system, ``uptime``, ``arch``);
    ## they are still BUILT, just not installed into the bundle.
    sandboxAutotoolsPackage(
      owningPackage = "sandboxCoreutils",
      executables = @[
        "cat", "ls", "cp", "mv", "rm", "mkdir", "head", "tail", "wc",
        "sort", "cut", "tr", "basename", "dirname", "touch", "env",
        "printf", "tee",
      ],
      extraConfigure = @[
        "--enable-no-install-program=kill,uptime,arch",
        # PORTABILITY of the digest/locale utilities. coreutils' gnulib
        # ``digest`` module compiles ``md5-stream.o`` / ``sha*-stream.o`` against
        # OpenSSL when the nix dev shell's ``<openssl/md5.h>`` is on the include
        # path, so md5sum / sha*sum / cksum / sort would record a /nix/store
        # ``libcrypto.3.dylib`` dependency. ``--without-openssl`` makes gnulib use
        # its OWN bundled digest implementations, so those binaries link
        # libSystem-only. (An earlier revision feared a stale-``md5-stream.o``
        # race under the parallel Mode B make, but the recipe now always builds
        # from a CLEAN ``build/`` tree, so configure's ``HAVE_OPENSSL`` value is
        # applied uniformly and there is no stale object to mislink.)
        "--without-openssl",
        # ``printf`` (and a few locale utilities) reference ``iconv`` for charset
        # handling; on this Nix clang toolchain ``_iconv`` is provided only by the
        # Nix libiconv (the macOS SDK libSystem stub does not export it), which
        # would record a /nix/store ``libiconv.2.dylib`` dependency. Force the
        # gnulib iconv probe OFF (as in the bash/grep/tar recipes) so coreutils
        # uses libSystem byte handling and stays libSystem-only.
        "--without-libiconv-prefix",
        "am_cv_func_iconv=no",
        "am_cv_lib_iconv=no",
      ])

  runtimeDeps:
    discard
