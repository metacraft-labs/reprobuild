## ``zsh`` — the Z shell.
##
## A package of its own so a recipe can declare ``uses: "zsh"`` for an edge
## that runs zsh as a child process, the way it declares ``bash``. Without
## it a path-mode ``uses:`` probed PATH for ``zsh`` and nothing provisioned
## one, so the tool came from the caller's environment, outside the edge's
## tool identity
## (reprobuild-pm/issues/2026-11-08-the-stdlib-has-no-zsh-package-so-a-recipe-cannot-provision-zsh.md).
##
## PROVISIONING ONLY, like ``bash.nim``: there is no ``executable zsh:`` /
## ``cli:`` block, so ``zsh`` names no build edge and carries no dependency
## or non-determinism policy.
##
## No Windows arm. zsh has no native Windows build; the only Windows zsh is
## an MSYS2 package, and the recipe that asked for this one (the shell
## recorders) does not declare zsh on Windows. A Windows ``uses: "zsh"``
## therefore resolves from PATH, as it did before.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package zsh:
  provisioning:
    # Nix-capable hosts: nixpkgs' zsh at the canonical pin (5.9 there).
    nixPackage "nixpkgs#zsh", executablePath = "bin/zsh",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
