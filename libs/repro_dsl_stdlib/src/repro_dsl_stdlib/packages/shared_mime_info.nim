## DSL-port M9.R.10a — stdlib provisioning stub for ``shared-mime-info``.
##
## Lifted from the M9.R.10a exec-name audit pass: this package surfaces
## as a ``nativeBuildDeps`` / ``buildDeps`` entry on one or more source
## recipes under ``recipes/packages/source/``. The stub registers the
## canonical name + a Nix provisioning channel so the resolver can find
## a usable adapter under ``--tool-provisioning=from-source`` /
## ``--tool-provisioning=nix``.
##
## TODO(M9.R.10b+): widen the channel set (scoop on Windows, tarball
## as a universal fall-through). The stub keeps the audit test green
## by registering the name + a single nix channel; richer provisioning
## arrives when the recipe actually needs to build on the corresponding
## host.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `shared-mime-info`:
  provisioning:
    # The dev output carries the pkg-config metadata Meson consumes and
    # propagates the runtime output containing update-mime-database.
    nixPackage "nixpkgs#shared-mime-info.dev",
      executablePath = "share/pkgconfig/shared-mime-info.pc",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
