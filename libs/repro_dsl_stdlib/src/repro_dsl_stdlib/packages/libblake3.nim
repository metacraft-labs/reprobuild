## ``libblake3`` -- the BLAKE3 C library (system-hash mode; the default build compiles the vendored sources instead).
##
## A library, not a tool: reprobuild's images link it. Its realizations
## (Package-Model.md §"Environment-provided library prefixes", approved by
## Zahary Karadjov, 2026-11-02):
##
##   * path mode, natively: the prefix ``BLAKE3_PREFIX`` names -- what the flake's
##     dev shell and the Nix package export -- checked and hashed by the
##     engine at every resolution (``environmentPrefix`` below);
##   * nix mode: ``nixpkgs#libblake3`` from the canonical nixpkgs pin;
##   * ``--target``: the sibling source recipe built for the target, never
##     either arm above (both are the build host's).
##
## The selector is ``libblake3``, not ``blake3``: that is already the name of the Nim binding module (``libs/blake3``), and two modules named ``blake3`` in one compile are ambiguous.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package libblake3:
  provisioning:
    environmentPrefix "BLAKE3_PREFIX", libraries = @["libblake3"], headers = @["blake3.h"]
    nixPackage "nixpkgs#libblake3", executablePath = "lib/libblake3.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
