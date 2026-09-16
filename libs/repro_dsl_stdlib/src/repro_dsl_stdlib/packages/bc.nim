## DSL-port M9.R.10a — stdlib provisioning stub for ``bc``.
##
## ``bc`` is consumed by glibc / kernel configure scripts during the
## from-source bootstrap; reached transitively via the gcc → glibc arm.
##
## Scoop ``main`` ships an
## ``bc-embedeo`` Windows binary under the ``bc`` manifest, but the
## ``bin`` entry is a per-arch executable list — keep the manifest
## opt-in via the same ``bin/bc.exe`` shape the lessmsi adapter
## consumes elsewhere.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `bc`:
  provisioning:
    nixPackage "nixpkgs#bc", executablePath = "bin/bc",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    scoopApp(bucket = "main", app = "bc",
      preferredVersion = ">=1", executablePath = "bin/bc.exe",
      requiresExecutionProfileChecksum = false)
