import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package tmux:
  provisioning:
    nixPackage "nixpkgs#tmux", executablePath = "bin/tmux",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
