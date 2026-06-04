# Nix Support

This directory contains Nix expressions that complement the top-level
`flake.nix`. The flake remains the canonical reprobuild build for
in-repo work (`nix build`, `nix develop`, `nix flake check`); the
files here exist so consumers can drop reprobuild into a `nixpkgs`
fork or `pkgs.callPackage` it directly without depending on the flake
inputs.

## Layout

```
nix/
  README.md
  pkgs/
    by-name/
      re/
        reprobuild/
          package.nix
```

The path under `pkgs/by-name/` matches the upstream nixpkgs
convention. Modern nixpkgs auto-discovers any
`pkgs/by-name/<prefix>/<pname>/package.nix` and exposes it as
`pkgs.<pname>` — no `pkgs/top-level/all-packages.nix` edit is
needed.

## Consuming `package.nix` outside nixpkgs

The package is plain `callPackage` style. Build it directly with:

```sh
nix-build -E '(import <nixpkgs> {}).callPackage ./nix/pkgs/by-name/re/reprobuild/package.nix {}'
```

or, from a flake that consumes reprobuild as an input,

```nix
reprobuildPkg = pkgs.callPackage "${inputs.reprobuild}/nix/pkgs/by-name/re/reprobuild/package.nix" { };
```

## Syncing into the `metacraft-labs/nixpkgs` fork

The downstream fork lives at
[`metacraft-labs/nixpkgs`](https://github.com/metacraft-labs/nixpkgs)
and tracks `nixpkgs-unstable`. Both `reprobuild` and `codetracer`
ship from there. To refresh the published `reprobuild` package
after a `package.nix` change here:

```sh
git clone --single-branch --depth 1 \
  --branch nixpkgs-unstable https://github.com/metacraft-labs/nixpkgs.git
cd nixpkgs
cp /path/to/reprobuild/nix/pkgs/by-name/re/reprobuild/package.nix \
   pkgs/by-name/re/reprobuild/package.nix
git commit -am 'reprobuild: sync from metacraft-labs/reprobuild'
git push origin nixpkgs-unstable
```

Modern nixpkgs (>= 23.11) auto-resolves `by-name/` entries; no edit
to `pkgs/top-level/all-packages.nix` is required. Verify with
`nix-build -A reprobuild` from the nixpkgs root before pushing.

To bring upstream changes into the fork (recommended on a regular
cadence so dependents stay close to current nixpkgs), use a rebase
flow rather than a merge:

```sh
git fetch upstream nixpkgs-unstable
git rebase upstream/nixpkgs-unstable
git push --force-with-lease origin nixpkgs-unstable
```

The fork's two metacraft-labs-specific package files
(`pkgs/by-name/re/reprobuild/` and `pkgs/by-name/co/codetracer/`)
do not collide with upstream paths, so the rebase is conflict-free
in practice.

## Filling in the `src` hash

The `src` argument's `hash` is currently pinned to a known-good value
captured from a `nix-build` on 2026-06-04 (the `main` branch tarball
of `metacraft-labs/reprobuild`). When you bump `src.rev`, replace the
hash with `lib.fakeHash` first, then re-run `nix-build`; the failure
output looks like:

```
error: hash mismatch in fixed-output derivation
  specified: sha256-AAAAAAAA…AAAAAAAA=
       got: sha256-<actual-hash>=
```

Copy the `got:` value into the `hash =` field of the `src`
`fetchFromGitHub` call in `package.nix`.

Same procedure applies to the two fixed source-only inputs in
`package.nix` (`nimcryptoSrc`, `runquotaSrc`) when bumping their
commits. The hashes currently shipped match the upstream `flake.lock`
entries; re-derive them from a `nix flake update` cycle if you bump
the upstream pins.

## Relationship to `flake.nix`

`flake.nix` and `nix/pkgs/by-name/re/reprobuild/package.nix` produce
the same derivation but are consumed differently:

- `flake.nix` is the canonical entry point for `nix build`, `nix
  develop`, and `nix flake check` from inside this repo. It fetches
  the `nimcrypto-src` / `runquota-src` inputs via flake plumbing.
- `package.nix` is the nixpkgs-format slice. It inlines the same
  `fetchFromGitHub` calls so the package is self-contained when used
  via `pkgs.callPackage` (i.e. it works without any flake inputs).

Keep the env vars, `buildInputs`, and build/install phases in sync
across both. Future work folds the per-binary build into the
reprobuild DSL (see `repro.nim` at the repo root); when that lands
the `buildPhase` will shift to invoking the engine directly, but the
nixpkgs-format outer shape stays unchanged.
