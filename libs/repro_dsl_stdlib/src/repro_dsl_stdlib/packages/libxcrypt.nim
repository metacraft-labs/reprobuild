## DSL-port M9.R.28.4 — stdlib provisioning stub for ``libxcrypt``.
##
## Some recipes (shadow-utils, util-linux) reference the package under
## the SONAME-style identifier ``libxcrypt`` rather than the canonical
## ``libcrypt`` short name. Both names map to nixpkgs#libxcrypt; this
## stub registers the alternate identifier so the resolver doesn't
## hard-fail with ``no sibling recipe at recipes/packages/source/
## libxcrypt/repro.nim and no stdlib provisioning channel`` when a
## recipe uses the alternate spelling.

import repro_project_dsl

package `libxcrypt`:
  provisioning:
    nixPackage "nixpkgs#libxcrypt", executablePath = "lib/libcrypt.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
