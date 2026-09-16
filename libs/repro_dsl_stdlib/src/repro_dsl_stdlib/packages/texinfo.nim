## DSL-port M9.R.10a — stdlib provisioning stub for ``texinfo``.
##
## Lifted from the M9.R.10a exec-name audit pass: this package surfaces
## as a ``nativeBuildDeps`` / ``buildDeps`` entry on one or more source
## recipes under ``recipes/packages/source/``. ``texinfo`` is reached by
## the wayland from-source smoke via the ``wayland → gcc → binutils →
## texinfo`` auto-recurse chain — it is the canary that gates every
## from-source GNU-stack recipe whose Texinfo manuals are regenerated
## from ``.texi`` sources at build time.
##
## The source archive does not provide a ready-to-run makeinfo tool.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `texinfo`:
  provisioning:
    nixPackage "nixpkgs#texinfo", executablePath = "bin/makeinfo",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
