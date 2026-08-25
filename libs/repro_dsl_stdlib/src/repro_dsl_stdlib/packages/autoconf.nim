## ``autoconf`` — GNU autoconf, the M4-driven ``./configure`` generator.
##
## Required by the C/C++ Autotools convention (M17, M28). The
## convention's ``autoreconf -fi`` action drives ``autoconf`` +
## ``automake`` + ``libtool`` + ``m4`` to regenerate ``configure`` /
## ``Makefile.in`` from the checked-in ``configure.ac`` /
## ``Makefile.am``. M28 lifted per-source compile + link actions out of
## the lifted ``Makefile.am`` so the build no longer reads the
## generated ``Makefile`` — but the configure action is still emitted
## as a prerequisite, and it needs ``autoconf`` on PATH.
##
## Listed in M29 (Provisioning catalog cleanup) alongside ``automake``
## so the Autotools dispatch path has a closed-set catalog footprint
## matching the existing ``autoreconf`` (autoconf-archive bundle).

import std/tables
import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
# DSL-port M9.R.2c — typed slot var for ``executable autoconfBin:``.
import repro_dsl_stdlib/types/executable
import repro_dsl_stdlib/packages_schema
export packages_schema

package autoconf:
  provisioning:
    nixPackage "nixpkgs#autoconf", executablePath = "bin/autoconf",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Autoconf's release tarball carries a pre-generated configure script,
    # so its source recipe does not execute autoconf while bootstrapping
    # itself. The from-source cycle breaker still requires a non-Nix profile
    # for the declared tool edge; this placeholder provides that profile
    # without introducing a vendor binary into the resulting package.
    tarball url = "https://ftp.gnu.org/gnu/autoconf/autoconf-2.72.tar.xz",
      sha256 = "ba885c1319578d6c94d46e9b0dceb4014caafe2490e437a0dbca3f270a223f5a",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "configure",
      packageId = "autoconf@2.72",
      cpu = "any",
      os = "any",
      lockIdentity = "tarball:autoconf@2.72:sha256:ba885c1319578d6c94d46e9b0dceb4014caafe2490e437a0dbca3f270a223f5a"

  # -------------------------------------------------------------------
  # DSL-port M9.R.2 — typed Layer-3 CLI surface for ``autoconf``.
  #
  # Recipes write ``autoconf.call(configureAc = "./configure.ac",
  # force = true)`` instead of an inline ``sh.call(["autoconf", "-f",
  # "./configure.ac"])``. The positional argument is the path to the
  # ``configure.ac`` (or a directory containing one); a no-argument
  # ``autoconf`` call regenerates ``configure`` in the cwd, hence the
  # positional is not required.
  # -------------------------------------------------------------------
  executable autoconfBin:
    cli:
      dependencyPolicy automaticMonitor

      call:
        boolFlag version is bool, alias = "--version"
        boolFlag force is bool, alias = "--force"
        flag output is string,
          alias = "--output=",
          format = concat,
          role = output
        flag includes is seq[string],
          alias = "--include=",
          format = concat,
          repeated = true
        # ``autoconf`` accepts ``TEMPLATE-FILE`` (default ``configure.ac``)
        # as its single positional. We pass it via ``configureAc`` to
        # avoid the ``required = true`` default the DSL applies to bare
        # ``pos`` declarations; the call site provides ``"./configure.ac"``
        # explicitly or omits the argument by passing an empty string.
        pos configureAc is string,
          position = 0,
          role = input

# ---------------------------------------------------------------------------
# Harvested MSYS2 catalog (cakBuiltin adapter consumer on Windows).
# ---------------------------------------------------------------------------

let autoconfCatalog* = @[
  VersionedProvisioning(
    version: "2.71-3",
    archive_format: afTarZst,
    install_method: imMsys2Pacman,
    bin_relpath: @["bin/autoconf"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows, url: "https://repo.msys2.org/msys/x86_64/autoconf-2.71-3-any.pkg.tar.zst", sha256: "703ea0566c4ec85278d23c626eee976af5bfec2d935d1ef3b5995f1ed4c180e7", sha512: "", sha1: "", extract_path: "usr")
    ],
    installer_args: @[],
    pacman_packages: @["autoconf"],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]
