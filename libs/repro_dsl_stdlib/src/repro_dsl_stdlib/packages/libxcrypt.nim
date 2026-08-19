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
import repro_dsl_stdlib/nixpkgs_pin

package `libxcrypt`:
  provisioning:
    nixPackage "nixpkgs#libxcrypt", executablePath = "lib/libcrypt.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
