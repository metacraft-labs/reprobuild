## DSL-port M9.R.10a — stdlib provisioning stub for ``rsync``.
##
## ``rsync`` is consumed by recipe install-stage glue (kernel make
## install, system stow) for tree mirroring.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `rsync`:
  provisioning:
    nixPackage "nixpkgs#rsync", executablePath = "bin/rsync",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
