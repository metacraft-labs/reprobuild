import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package xdotool:
  provisioning:
    nixPackage "nixpkgs#xdotool", executablePath = "bin/xdotool",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
