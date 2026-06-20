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

import repro_project_dsl
# DSL-port M9.R.2c — typed slot var for ``executable autoconfBin:``.
import repro_dsl_stdlib/types/executable

package autoconf:
  provisioning:
    nixPackage "nixpkgs#autoconf", executablePath = "bin/autoconf",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

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
