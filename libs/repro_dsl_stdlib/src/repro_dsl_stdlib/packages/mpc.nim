## DSL-port M9.R.10a — stdlib provisioning stub for ``mpc``.
##
## ``mpc`` (multiprecision complex) is a build-time dep of gcc;
## wayland → gcc → mpc.
##
## ``executablePath`` points at the header artefact (same pattern as
## ``gmp.nim`` / ``mpfr.nim``) because mpc is library-only.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `mpc`:
  provisioning:
    nixPackage "nixpkgs#libmpc", executablePath = "include/mpc.h",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
