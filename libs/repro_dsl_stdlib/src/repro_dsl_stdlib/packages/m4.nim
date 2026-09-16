## DSL-port M9.R.10a — stdlib provisioning stub for ``m4``.
##
## ``m4`` is reached by every autotools driver: ``wayland → expat →
## autoconf → m4`` AND ``wayland → gcc → binutils → m4``.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `m4`:
  provisioning:
    nixPackage "nixpkgs#gnum4", executablePath = "bin/m4",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    scoopApp(bucket = "main", app = "m4",
      preferredVersion = ">=1", executablePath = "bin/m4.exe",
      requiresExecutionProfileChecksum = false)
