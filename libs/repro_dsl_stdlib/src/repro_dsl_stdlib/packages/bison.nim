## Provisioning for the host bison parser generator.
##
## The GNU source archive contains configure, not a ready-to-run bison.
## Keep executable provisioning on the Nix and Scoop channels.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `bison`:
  provisioning:
    nixPackage "nixpkgs#bison", executablePath = "bin/bison",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    scoopApp(bucket = "main", app = "bison",
      preferredVersion = ">=2.4", executablePath = "bin/bison.exe",
      requiresExecutionProfileChecksum = false)
