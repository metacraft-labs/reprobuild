## ``pnpm`` — fast, disk-efficient alternative npm-compatible package manager.
##
## Recognised by the JS/TS Mode B crude fallback when a project ships a
## ``pnpm-lock.yaml`` (or ``packageManager`` field in ``package.json``
## that pins pnpm). Reprobuild dispatches ``pnpm install`` /
## ``pnpm run build`` in place of the npm equivalents.
##
## Listed in M29 (Provisioning catalog cleanup) alongside ``yarn`` and
## ``bun`` so that every JS/TS package manager the convention CAN see in
## the wild has a catalog entry — even when the convention's current
## emission path defaults to ``npm``. Adding the entry now means a
## future M can promote pnpm/bun to first-class dispatch without
## touching the catalog.

import repro_project_dsl

package pnpm:
  provisioning:
    nixPackage "nixpkgs#pnpm", executablePath = "bin/pnpm",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
