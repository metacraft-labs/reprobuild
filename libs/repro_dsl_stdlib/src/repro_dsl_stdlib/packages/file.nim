## DSL-port M9.R.10a — stdlib provisioning stub for ``file``.
##
## ``file`` is the libmagic CLI; consumed by autoconf-generated configure
## scripts to probe binary layouts at configure time.
##
## Scoop ``main`` ships a ``file``
## manifest with a flat ``file.exe`` extract.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `file`:
  provisioning:
    nixPackage "nixpkgs#file", executablePath = "bin/file",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    scoopApp(bucket = "main", app = "file",
      preferredVersion = ">=5", executablePath = "file.exe",
      requiresExecutionProfileChecksum = false)
