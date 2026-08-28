## ``wrangler`` — Cloudflare's Workers / Pages CLI (developer.cloudflare.com).
##
## The deploy step of an isonim static site publishes the rendered ``dist/``
## tree to Cloudflare Pages with ``wrangler pages deploy dist/``. Naming
## ``wrangler`` in a recipe's ``uses:`` makes reprobuild provision the CLI the
## same way the site's ``flake.nix`` ``.#ci`` dev shell does today — from the
## pinned nixpkgs — so the deploy runs inside the reprobuild-defined
## environment rather than assuming a globally-installed ``wrangler``.
##
## Provisioning channel — ``nixpkgs#wrangler``. nixpkgs packages the CLI (a
## bundled Node executable) and exposes it at ``bin/wrangler``; that is exactly
## the binary ``wrangler pages deploy`` needs. A recipe declares it as a tool
## floor (``uses: "wrangler"``); the SSG/render edges never invoke it — deploy
## stays a CI/`repro run` step outside the hermetic build graph, but declaring
## the tool here lets the engine resolve and pin it.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package wrangler:
  provisioning:
    nixPackage "nixpkgs#wrangler", executablePath = "bin/wrangler",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
