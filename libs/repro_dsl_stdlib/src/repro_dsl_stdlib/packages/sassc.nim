## DSL-port M9.R.15b — stdlib provisioning stub for ``sassc``.
##
## Lifted from the M9.R.15b GNOME-stack foundation pass: gtk4 declares
## ``sassc`` as a ``nativeBuildDeps`` entry (it consumes the Sass
## stylesheets bundled with the default Adwaita theme and compiles them
## to CSS at build time). The stub registers the canonical name + a
## Nix provisioning channel so the resolver can find a usable adapter
## under ``--tool-provisioning=from-source`` / ``--tool-provisioning=nix``.
##
## TODO(M9.R.15c+): widen the channel set when sassc surfaces on Windows
## or macOS, and add a from-source recipe under
## ``recipes/packages/source/sassc/`` if the nix-only channel ever
## proves insufficient.

import repro_project_dsl

package `sassc`:
  provisioning:
    nixPackage "nixpkgs#sassc", executablePath = "bin/sassc",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
