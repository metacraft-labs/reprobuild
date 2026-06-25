## macOS sandbox-tool: GNU findutils, built from source via reprobuild Mode B.
##
## findutils provides ``find`` and ``xargs`` (plus ``locate`` / ``updatedb``,
## which we do not register) — both SIP binaries under ``/usr/bin`` on macOS and
## load-bearing for a monitored process tree: ``find … -exec`` and
## ``… | xargs cmd`` are the canonical fan-out primitives a build script uses to
## shell out, so the io-mon monitor must be able to redirect a SIP
## ``/usr/bin/find`` / ``/usr/bin/xargs`` exec to a NON-SIP, injectable drop-in
## we build. The from-source build links ONLY ``/usr/lib/libSystem.B.dylib``
## (``otool -L``), so each binary is a portable, AMFI-safe drop-in.
##
## Build shape: the shared ``sandbox_tool`` Mode B template (see
## ``../sandbox_tool.nim``) over the vendored upstream 4.10.0 release tarball
## (committed ``configure`` — avoids the io-mon ``autom4te`` bug on the
## repo-checkout shape). The fetch URL is a relative ``file:./vendor/...`` so the
## build is offline-reproducible. See ``reprobuild-specs/Package-Model.md`` for
## the package shape and ``Language-Conventions/C-Cpp-Autotools.md`` §"Mode B"
## for the configure/make/install flow.
##
## sha256 = 1387e0b67ff247d2abde998f90dfbf70c1491391a59ddfecb8ae698789f0a4f5
##   (the vendored ``findutils-4.10.0.tar.xz``).

import repro_project_dsl

import ../sandbox_tool

package sandboxFindutils:
  ## From-source GNU findutils for the macOS sandbox-tools bundle. Registers the
  ## load-bearing drop-in binaries (``find`` + ``xargs``) the io-mon SIP redirect
  ## + the bundle assembler need; the Mode B ``make`` builds the full set.

  versions:
    "4.10.0":
      sourceRevision = "v4.10.0"
      sourceUrl = "https://ftp.gnu.org/gnu/findutils/findutils-4.10.0.tar.xz"
      sourceRepository = "https://git.savannah.gnu.org/git/findutils.git"

  fetch:
    ## Vendored tarball, referenced relative to the recipe dir so the recipe
    ## carries no host-absolute path and the build runs offline.
    url: "file:./vendor/findutils-4.10.0.tar.xz"
    sha256: "1387e0b67ff247d2abde998f90dfbf70c1491391a59ddfecb8ae698789f0a4f5"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "make"
    "gcc >=11"

  config:
    discard

  executable find:
    discard
  executable xargs:
    discard

  build:
    ## Mode B autotools build via the shared sandbox-tool template. We disable
    ## the ``locate`` database tooling: it is not a SIP drop-in target and pulls
    ## extra runtime surface (``updatedb`` shells out to ``frcode`` etc.); the
    ## sandbox only needs the ``find`` / ``xargs`` fan-out primitives.
    sandboxAutotoolsPackage(
      owningPackage = "sandboxFindutils",
      executables = @["find", "xargs"])

  runtimeDeps:
    discard
