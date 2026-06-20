## ``libtool`` — GNU libtool, the portable shared-library wrapper used
## by every autotools-driven C/C++ project to build / link shared
## libraries cross-platform.
##
## M9.R.14c.8 — added as part of the bootstrap-floor widening. The
## from-source autoconf / automake / libtool tools are perl scripts
## whose execution requires sibling ``share/<tool>/`` + ``lib/<tool>/``
## trees with macro databases + perl modules. The autotools_package
## stage-copy convention (M9.R.14c.5) stages only the executable
## binary, dropping the sibling tree context. Until M9.L's per-artifact
## install-glue lands, these tools come from stdlib (nix on Linux/macOS,
## scoop on Windows) which ships the full install tree intact.

import repro_project_dsl

package libtool:
  provisioning:
    nixPackage "nixpkgs#libtool", executablePath = "bin/libtool",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

package libtoolize:
  provisioning:
    nixPackage "nixpkgs#libtool", executablePath = "bin/libtoolize",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
