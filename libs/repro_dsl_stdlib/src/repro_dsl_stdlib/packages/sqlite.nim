## ``sqlite`` -- SQLite, the engine's on-disk index store.
##
## A library, not a tool: reprobuild's images link it. Its realizations
## (Package-Model.md §"Environment-provided library prefixes", approved by
## Zahary Karadjov, 2026-11-02):
##
##   * path mode, natively: the prefix ``SQLITE_PREFIX`` names -- what the flake's
##     dev shell and the Nix package export -- checked and hashed by the
##     engine at every resolution (``environmentPrefix`` below);
##   * nix mode: ``nixpkgs#sqlite`` from the canonical nixpkgs pin;
##   * ``--target``: the sibling source recipe built for the target, never
##     either arm above (both are the build host's).
##
## The selector is ``sqlite``, the name of the catalog's source recipe (``packages/source/sqlite``), which a ``--target`` build resolves to.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package sqlite:
  provisioning:
    # No `headers`: reprobuild links libsqlite3 and compiles against none of
    # its headers, and the dev shell's `SQLITE_PREFIX` is nixpkgs'
    # `sqlite.out`, which ships none (they are in `.dev`). The arm checks
    # exactly what the consumer needs.
    environmentPrefix "SQLITE_PREFIX", libraries = @["libsqlite3"]
    nixPackage "nixpkgs#sqlite", executablePath = "lib/libsqlite3.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
