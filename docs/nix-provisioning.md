# Nix Provisioning Catalog

Reprobuild's Nix adapter is a package-version catalog, not a single
project-wide nixpkgs environment. Each catalog entry describes one tool version
and the exact nixpkgs source that should realize it. Different versions of the
same tool may intentionally point at different nixpkgs commits so that they can
coexist in the Nix store and in Reprobuild's unified tool store.

## Goals

- Prefer upstream nixpkgs derivations over local attribute overrides whenever a
  requested version exists in nixpkgs history. This maximizes hits in
  `cache.nixos.org` and other upstream-compatible binary caches.
- Pin nixpkgs per catalog entry. Nixpkgs moves as a collection, but a
  Reprobuild package catalog entry is a single package version with its own
  realization source.
- Allow multiple versions side-by-side. A project may use `node` from one
  nixpkgs commit and `cargo-nextest` from another when that gives better cache
  coverage or compatibility.
- Treat local overrides as a fallback. Overrides are useful for missing versions
  and patches, but they tend to miss upstream caches because the derivation
  identity changes.

## Metadata

Nix package provisioning supports:

```nim
provisioning:
  nixPackage "nixpkgs#nodejs",
    executablePath = "bin/node",
    nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
    nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
```

`nixpkgsRev` expands to `github:NixOS/nixpkgs/<rev>`. `nixpkgsRef` may be used
instead when the catalog needs a non-default repository or a fully specified
flake reference. `nixpkgsNarHash` is recorded with the reference when supplied.

The resolver expands `nixpkgs#attr` with pinned metadata into:

```sh
nix build --no-link --print-out-paths \
  github:NixOS/nixpkgs/<rev>?narHash=<hash>#attr
```

The resulting tool profile records the effective selector, realized
`/nix/store` outputs, selected executable, and lock identity. The original
catalog metadata remains in the project interface so downstream inspection can
explain why a particular nixpkgs source was chosen.

## Materialization Receipts

Nix provisioning is split into two logical stages:

1. Resolve the catalog entry into an effective package plan: selector, pinned
   nixpkgs source, declared executable, expression-file digest when applicable,
   platform, and configured probe specs.
2. Materialize that package plan and record a reusable receipt.

The materialization receipt is stored below the Reprobuild unified tool store
and contains the realized `/nix/store` outputs, the selected executable, the
unified-store pointer receipt, executable probe results, and the resulting tool
profile fingerprint. The receipt key is package-plan scoped, not project
scoped. If another project requests the same package plan, or if the project
interface changes without changing that package plan, Reprobuild validates that
the recorded paths still exist and reuses the receipt without invoking
`nix build`.

This cache is an early implementation of the bootstrap build-graph split. The
long-term form should expose the plan decision and package materializations as
ordinary bootstrap actions with monitored dependency evidence and
`why`/introspection reporting.

## Catalog Construction Policy

For each package version, choose the newest nixpkgs commit that satisfies all of
these constraints:

1. The requested package version is present at the desired attribute path.
2. The package is not marked broken for the target system.
3. Hydra or an accepted external cache has a substitutable binary for the target
   system and output set.
4. The commit belongs to a channel or tracked branch with good cache coverage
   when multiple equivalent revisions exist.

When multiple package versions can share the same nixpkgs commit without
reducing cache coverage, prefer sharing the commit. This limits duplicated
runtime dependencies while preserving the ability to split entries when a
specific version requires a different historical revision.

## Cache Policy

The default trusted source is `cache.nixos.org` for unmodified upstream nixpkgs
derivations. Additional caches may be associated with a catalog source in a
future metadata extension, but Reprobuild must treat cache trust as explicit
configuration because a substituter is part of the supply-chain boundary.

Before adding an override-based recipe, the catalog builder should first check
whether a historical nixpkgs revision already contains the desired upstream
version and whether the corresponding store path has a narinfo in the accepted
cache set. Override recipes should carry their own provenance and should be
expected to require a Reprobuild-owned binary cache if they are performance
critical.

## Relationship To Project Flakes

A project flake may still provide the developer shell and Reprobuild binary.
That flake does not define the versions of tools requested through `uses:`.
`uses:` entries resolve through the Reprobuild package catalog, and each Nix
catalog entry carries its own pinned nixpkgs source.
