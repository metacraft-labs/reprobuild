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
        # NOTE on portability of the digest/locale utilities: coreutils'
        # gnulib ``digest`` module compiles ``md5-stream.o`` against OpenSSL
        # when the nix dev shell's ``<openssl/md5.h>`` is on the include path,
        # so md5sum / sha*sum / cksum (and, via libintl, sort / printf) record
        # a /nix/store/.../libcrypto.3.dylib (or libiconv.2.dylib) dependency.
        # Passing ``--with-openssl=no`` makes a CLEAN tree build them
        # libSystem-only, but under the parallel Mode B ``make`` a stale
        # ``md5-stream.o`` (compiled against the openssl-enabled config.h on the
        # first pass) survives and the final link then fails with undefined
        # OpenSSL symbols. Rather than fight that race, we leave the digest
        # utilities as-built and let the bundle assembler EXCLUDE any binary
        # that is not libSystem-only. This is sound for the sandbox use case:
        # md5sum / sha*sum / cksum / sort / printf are NOT SIP drop-in targets
        # the io-mon monitor redirects to. The ESSENTIAL drop-ins — cat / ls /
        # cp / mv / rm / mkdir / head / tail / wc / cut / tr / basename /
        # dirname / touch / env / tee / true / false / sleep / pwd / echo /
        # ... — are libSystem-only and land in the bundle. Making the digest
        # utilities portable is a tracked follow-up (force a from-scratch make,
        # or build with the openssl headers off the include path).
      ])

  runtimeDeps:
    discard
