## ``automake`` — GNU automake, generates ``Makefile.in`` templates
## from ``Makefile.am`` sources.
##
## Required by the C/C++ Autotools convention (M17, M28). The
## convention's ``autoreconf -fi`` action invokes
## ``aclocal`` + ``autoconf`` + ``automake --add-missing`` + ``libtool``
## to regenerate the build's configure / Makefile templates.
##
## Listed in M29 (Provisioning catalog cleanup) alongside ``autoconf``
## so the Autotools dispatch path has a closed-set catalog footprint.

import repro_project_dsl

package automake:
  provisioning:
    nixPackage "nixpkgs#automake", executablePath = "bin/automake",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
