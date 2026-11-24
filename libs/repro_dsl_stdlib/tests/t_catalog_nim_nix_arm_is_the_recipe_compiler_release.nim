## The catalog's `nim` Nix arm provisions the Nim release recipe compilation
## requires (operator decision of 2026-11-24: Nim 2.2.10).
##
## The canonical nixpkgs snapshot carries Nim 2.2.4, whose generated C file
## names grow with a recipe's depth until the compile dies with
## `cannot open`. The catalog entry therefore pins the snapshot the engine's
## own Linux bootstrap uses for its Nim, and this test holds the two equal so
## the catalog cannot drift back to a snapshot with an older Nim, or away from
## the bootstrap's. It also holds the rule the pin serves: the floor in
## `repro_core/recipe_compiler_requirement` and the bootstrap's declared
## release are the same number.
##
## No mocks: the real registered package definition and the real constants.
## Nothing is evaluated by Nix here; which Nim a snapshot carries was measured
## with `nix eval github:NixOS/nixpkgs/<rev>#nim.version` (2.2.10 for
## eec3e392..., 2.2.4 for addf7cf...) on 2026-11-24.
import std/unittest

import repro_interface_artifacts
import repro_core/recipe_compiler_requirement
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages/nim
import repro_home_apply/package_catalog
import repro_tool_profiles

suite "catalog nim Nix arm":
  test "it is the bootstrap's snapshot, not the canonical one":
    let arms = profileToolUse("nim").useDef.nixProvisioning
    check arms.len == 1
    if arms.len != 1: return
    check arms[0].selector == "nixpkgs#nim"
    check arms[0].executablePath == "bin/nim"
    check arms[0].nixpkgsRev == BootstrapNimNixpkgsRev
    check arms[0].nixpkgsNarHash == BootstrapNimNixpkgsNarHash
    check arms[0].nixpkgsRev != CanonicalNixpkgsRev

  test "the bootstrap's release is the recipe compiler floor":
    check BootstrapNimVersion == RecipeCompilerMinimumVersion
