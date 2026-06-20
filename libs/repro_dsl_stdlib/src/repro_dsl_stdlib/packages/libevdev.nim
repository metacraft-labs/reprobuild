## DSL-port M9.R.10a — stdlib provisioning stub for ``libevdev``.
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

package `libevdev`:
  provisioning:
    nixPackage "nixpkgs#libevdev", executablePath = "lib/libevdev.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
