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

package autoconf:
  provisioning:
    nixPackage "nixpkgs#autoconf", executablePath = "bin/autoconf",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
