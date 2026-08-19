## ``bun`` — all-in-one JavaScript runtime + package manager + bundler
## from oven.sh.
##
## Recognised by the JS/TS Mode B crude fallback when a project ships a
## ``bun.lockb`` (or ``packageManager`` field in ``package.json`` that
## pins bun). Reprobuild dispatches ``bun install`` / ``bun run build``
## in place of the npm equivalents.
##
## Listed in M29 (Provisioning catalog cleanup) alongside ``yarn`` and
## ``pnpm`` so that every JS/TS package manager the convention CAN see
## in the wild has a catalog entry — even when the convention's current
## emission path defaults to ``npm``. Adding the entry now means a
## future M can promote pnpm/bun to first-class dispatch without
## touching the catalog.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package bun:
  provisioning:
    nixPackage "nixpkgs#bun", executablePath = "bin/bun",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
