## Foundry — Ethereum smart contract toolkit. The Nix package
## ``nixpkgs#foundry`` bundles forge, cast, anvil, and chisel under a
## single derivation; the executablePath below points at ``forge`` as
## the canonical front-door binary. ``cast``/``anvil``/``chisel`` ship
## alongside it under the same ``bin/`` prefix and resolve via PATH
## once the package is on the dev shell.

import repro_project_dsl

package foundry:
  provisioning:
    nixPackage "nixpkgs#foundry", executablePath = "bin/forge",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
