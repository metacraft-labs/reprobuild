## DSL-port M9.R.10a — stdlib provisioning stub for ``mpfr``.
##
## ``mpfr`` is a build-time dep of gcc; wayland → gcc → mpfr.
##
## ``executablePath`` points at the header artefact (same pattern as
## ``gmp.nim``) because mpfr is library-only — no CLI surface.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `mpfr`:
  provisioning:
    nixPackage "nixpkgs#mpfr", executablePath = "include/mpfr.h",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
