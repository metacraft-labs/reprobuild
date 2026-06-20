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

package `shared-mime-info`:
  provisioning:
    # M9.R.14h.6 — shared-mime-info 2.4 (nixpkgs addf7cf5) does NOT
    # ship a ``share/mime/version`` file at the realized prefix; the
    # canonical artifact every consumer actually needs is
    # ``bin/update-mime-database``, the helper gdk-pixbuf et al. invoke
    # at install-time to populate the runtime MIME cache.
    nixPackage "nixpkgs#shared-mime-info",
      executablePath = "bin/update-mime-database",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
