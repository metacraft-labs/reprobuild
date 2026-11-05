## ``xxhash`` -- the xxHash C library (system-hash mode; the default build compiles the vendored sources instead).
##
## A library, not a tool: reprobuild's images link it. Its realizations
## (Package-Model.md §"Environment-provided library prefixes", approved by
## Zahary Karadjov, 2026-11-02):
##
##   * path mode, natively: the prefix ``XXHASH_PREFIX`` names -- what the flake's
##     dev shell and the Nix package export -- checked and hashed by the
##     engine at every resolution (``environmentPrefix`` below);
##   * nix mode: ``nixpkgs#xxHash`` from the canonical nixpkgs pin;
##   * ``--target``: the sibling source recipe built for the target, never
##     either arm above (both are the build host's).
##
## The selector is ``xxhash``.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package xxhash:
  provisioning:
    environmentPrefix "XXHASH_PREFIX", libraries = @["libxxhash"], headers = @["xxhash.h"]
    nixPackage "nixpkgs#xxHash", executablePath = "lib/libxxhash.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
