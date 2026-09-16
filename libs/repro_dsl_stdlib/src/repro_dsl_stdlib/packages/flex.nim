## DSL-port M9.R.10a — stdlib provisioning stub for ``flex``.
##
## ``flex`` is reached by the wayland from-source chain via
## ``wayland → gcc → binutils → flex`` (binutils' lexer regenerates
## from flex sources at build time).

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `flex`:
  provisioning:
    nixPackage "nixpkgs#flex", executablePath = "bin/flex",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
