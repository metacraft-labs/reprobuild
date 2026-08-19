import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package nix:
  provisioning:
    # The default `nix`/`stable` attributes at this pinned nixpkgs revision
    # build locally on aarch64-darwin. 2.28.5 has upstream cache.nixos.org
    # substitutes and is sufficient for Reprobuild's own Nix invocations.
    nixPackage "nixpkgs#nixVersions.nix_2_28", executablePath = "bin/nix",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash,
      packageId = "nix@2.28.5"
