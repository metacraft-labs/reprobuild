## macOS sandbox-tool: XZ Utils (xz), built from source via reprobuild Mode B.
##
## xz provides ``xz`` plus the ``unxz`` / ``xzcat`` wrappers — the LZMA/xz
## (de)compression userland build scripts shell out to (unpacking ``.tar.xz``
## sources, etc.). macOS does not ship ``xz`` at a fixed SIP path on every
## release, but the sandbox bundle still needs a portable ``xz`` so a redirected
## ``/usr/bin/xz`` (or a tool that execs ``xz``) lands on a NON-SIP drop-in we
## build. The from-source build links ONLY ``/usr/lib/libSystem.B.dylib``
## (``otool -L``), so each binary is a portable, AMFI-safe drop-in.
##
## Build shape: the shared ``sandbox_tool`` Mode B template (see
## ``../sandbox_tool.nim``) over the vendored upstream 5.6.3 release tarball
## (committed ``configure``) from the canonical tukaani-project release host.
## Offline-reproducible via the ``file:./vendor/...`` fetch URL. See
## ``reprobuild-specs/Package-Model.md`` (package shape) and
## ``Language-Conventions/C-Cpp-Autotools.md`` §"Mode B" (build flow).
##
## # Portability note (unxz / xzcat)
##
## ``unxz`` / ``xzcat`` are installed by ``make install`` as symlinks to the
## ``xz`` Mach-O (mode-switch by argv[0]), so the bundle assembler resolves them
## to the same binary. We register all three names.
##
## sha256 = db0590629b6f0fa36e74aea5f9731dc6f8df068ce7b7bafa45301832a5eebc3a
##   (the vendored ``xz-5.6.3.tar.xz``).

import repro_project_dsl

import ../sandbox_tool

package sandboxXz:
  ## From-source XZ Utils for the macOS sandbox-tools bundle.

  versions:
    "5.6.3":
      sourceRevision = "v5.6.3"
      sourceUrl = "https://github.com/tukaani-project/xz/releases/download/v5.6.3/xz-5.6.3.tar.xz"
      sourceRepository = "https://github.com/tukaani-project/xz.git"

  fetch:
    url: "file:./vendor/xz-5.6.3.tar.xz"
    sha256: "db0590629b6f0fa36e74aea5f9731dc6f8df068ce7b7bafa45301832a5eebc3a"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "make"
    "gcc >=11"

  config:
    discard

  executable xz:
    discard
  executable unxz:
    discard
  executable xzcat:
    discard

  build:
    ## Mode B autotools build via the shared sandbox-tool template. We force a
    ## STATIC liblzma and disable the shared library
    ## (``--enable-static --disable-shared``): the ``xz`` CLI then links its own
    ## ``liblzma`` statically and records NO external ``liblzma.5.dylib``
    ## dependency, keeping the binary libSystem-only and relocatable. We also
    ## drop the ``scripts`` (``xzgrep``/``xzdiff`` perl/sh helpers) and
    ## ``lzmainfo``/``xzdec`` extras the sandbox does not need.
    sandboxAutotoolsPackage(
      owningPackage = "sandboxXz",
      executables = @["xz", "unxz", "xzcat"],
      extraConfigure = @[
        "--enable-static",
        "--disable-shared",
        "--disable-scripts",
        "--disable-lzmainfo",
        "--disable-xzdec",
      ])

  runtimeDeps:
    discard
