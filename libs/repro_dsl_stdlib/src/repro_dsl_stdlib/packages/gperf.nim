## DSL-port M9.R.10a — stdlib provisioning stub for ``gperf``.
##
## ``gperf`` (perfect hash generator) is consumed transitively by the
## wayland from-source chain through glib2 / wayland-protocols and by
## gcc's bootstrap suite.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `gperf`:
  provisioning:
    nixPackage "nixpkgs#gperf", executablePath = "bin/gperf",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
