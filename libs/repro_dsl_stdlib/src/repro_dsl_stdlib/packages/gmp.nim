## DSL-port M9.R.10a — stdlib provisioning stub for ``gmp``.
##
## ``gmp`` (GNU Multi-Precision Arithmetic Library) is a build-time
## dep of gcc; wayland → gcc → gmp.
##
## ``executablePath`` here points at the library/header artefact the
## downstream gcc build reads — there is no GMP CLI binary. The
## resolver currently treats ``executablePath`` as the file the realized
## prefix must contain; pointing at ``include/gmp.h`` lets the existence
## check pass on a header-only consumption pattern.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `gmp`:
  provisioning:
    nixPackage "nixpkgs#gmp", executablePath = "include/gmp.h",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
