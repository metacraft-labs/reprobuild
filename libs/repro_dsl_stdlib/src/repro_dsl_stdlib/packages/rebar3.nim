## ``rebar3`` — the Erlang build tool.
##
## A package of its own so a recipe can declare ``uses: "rebar3"``: a
## path-mode ``uses:`` probes PATH for the selector's name, and nothing else
## provides one
## (reprobuild-pm/issues/2026-11-07-the-stdlib-beam-packages-cannot-provision-erl-mix-or-rebar3.md).
## nixpkgs wraps its ``bin/rebar3`` with its own erlang, so the realisation
## needs nothing from the ambient PATH.
##
## No Windows arm. Upstream publishes rebar3 only as a bare escript, with no
## Windows archive to pin, and the recipe that asked for the package (the BEAM
## recorder) builds on Linux CI only. A Windows ``uses: "rebar3"`` therefore
## resolves from PATH, as it did before.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package rebar3:
  provisioning:
    # Nix-capable hosts: nixpkgs' rebar3 at the canonical pin (3.25.1 there).
    nixPackage "nixpkgs#rebar3", executablePath = "bin/rebar3",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
