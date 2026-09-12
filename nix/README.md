# Nix Support

This directory holds the Nix expressions that the top-level `flake.nix`
is built out of, plus the NixOS / nix-darwin / home-manager modules the
flake exports.

## Layout

```
nix/
  README.md
  modules/
    reprobuild.nix            # services.reprobuild — nixos + darwin + homeManager
    repro-binary-cache.nix    # services.mcl-repro-binary-cache — the cache host
  pkgs/
    by-name/
      re/
        reprobuild/
          package.nix         # the reprobuild derivation (nixpkgs by-name form)
          nim-fork.nix        # its private Nim-toolchain helper
```

## Modules — one definition, re-exported

`modules/` is the **single source of truth** for the reprobuild option
schema, the `caches.conf` renderer, and the systemd/launchd unit wiring.
The flake exports them as

| output | module |
| --- | --- |
| `nixosModules.reprobuild` | system-wide `repro` + `/etc/repro/caches.conf` + both lease daemons |
| `darwinModules.reprobuild` | the same for nix-darwin, with launchd jobs |
| `homeManagerModules.reprobuild` | per-user `repro` + `~/.config/repro/caches.conf` + the user daemon |
| `nixosModules.repro-binary-cache` | the binary-cache HTTP host |
| `nixosModules.reprobuild-legacy-option-names` | opt-in aliases for the historical `programs.reprobuild.*` path |

They used to live only in `metacraft-labs/nixos-modules`
(`modules/mcl-reprobuild`, `modules/mcl-repro-binary-cache`), so an
external Nix user could get the package from this flake but had to
depend on our org's module repo to get the services. nixos-modules now
**re-exports** these and holds no copy of them. The direction is forced
by the input graph: nixos-modules pins `reprobuild`, so reprobuild must
not need nixos-modules for its modules.

A minimal external consumer:

```nix
{
  inputs.reprobuild.url = "github:metacraft-labs/reprobuild";
  outputs = { nixpkgs, reprobuild, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        reprobuild.nixosModules.reprobuild
        {
          services.reprobuild = {
            enable = true;
            enableUserDaemon = true;
            caches.repro-cache = {
              url = "https://repro-cache.example.com";
              trustedPublicKeys = [ "04…" ];   # 130 hex chars; R1 is default-untrusted
              priority = 20;
            };
          };
        }
      ];
    };
  };
}
```

## The package — one derivation, two source strategies

`pkgs/by-name/re/reprobuild/package.nix` is the **only** definition of
the reprobuild derivation. `flake.nix` `callPackage`s it, overriding
every `*Src` argument with the corresponding flake input, so
`--override-input io-mon-src path:../io-mon` and the `.envrc` sibling
auto-overrides keep working. A nixpkgs consumer takes the same file with
its `fetchFromGitHub` defaults and needs no flake plumbing at all.

This replaced a hand-maintained second copy of the derivation. The
copies had drifted badly — the nixpkgs one was still on version 0.1.0,
used `nim2` instead of the Nim fork, pinned `rev = "main"` (a retired
branch, and a moving ref inside a fixed-output fetch), and named three
of the thirteen source inputs the build actually needs. Two derivations
for one package do not stay in step.

Build it outside a flake with:

```sh
nix-build -E '(import <nixpkgs> {}).callPackage ./nix/pkgs/by-name/re/reprobuild/package.nix {}'
```

`version` is the one value `package.nix` cannot derive for itself:
reading `${src}/reprobuild.nimble` at eval time is
import-from-derivation, which nixpkgs forbids. It therefore carries a
literal default, and `nix build .#checks.<system>.nixpkgs-package-version-sync`
fails the build if that literal and the nimble manifest disagree.

## Syncing into the `metacraft-labs/nixpkgs` fork

The downstream fork is [`metacraft-labs/nixpkgs`](https://github.com/metacraft-labs/nixpkgs);
its `nixpkgs-unstable` branch is what dependents consume. Refresh the
published package after a change here:

```sh
git clone --single-branch --branch nixpkgs-unstable \
  https://github.com/metacraft-labs/nixpkgs.git
cd nixpkgs
mkdir -p pkgs/by-name/re/reprobuild
cp /path/to/reprobuild/nix/pkgs/by-name/re/reprobuild/*.nix \
   pkgs/by-name/re/reprobuild/
git commit -am 'reprobuild: sync from metacraft-labs/reprobuild'
```

Modern nixpkgs auto-resolves `by-name/` entries, and it auto-calls only
`package.nix` — `nim-fork.nix` stays a private helper reached through
`callPackage ./nim-fork.nix { }`. Verify with `nix build .#reprobuild`
from the nixpkgs root before pushing.

Bumping `src.rev` (or any `*Src` rev): set the corresponding `hash` to
`lib.fakeHash`, build, and copy the `got:` line from the failure. Each
default mirrors a `flake.lock` entry, so bump the two together.

## Upstream-submission status

Everything in `package.nix` and `nim-fork.nix` is nixpkgs-legal — fixed
output fetches with pinned revs, no network at build time, no flake
inputs, no vendored binaries, `strictDeps`, `meta` with a license and
`mainProgram`. Two things would still draw a reviewer's objection, and
packaging cannot paper over either:

1. **The Nim compiler fork.** `nim-fork.nix` bootstraps
   `metacraft-labs/nim` (Nim 2.3.1 devel, an unreleased fork) from
   `csources_v3` rather than using nixpkgs' `nim`. nixpkgs does not
   accept a package that ships its own compiler toolchain build when a
   packaged compiler exists; the honest routes are to land the fork's
   compiler-side changes upstream in Nim, or to add the fork as a
   first-class `nim-unwrapped-*` variant in its own right. Until one of
   those happens this package is fork-only.
2. **Seventeen pinned source fetches.** Legal, but well outside what a
   reviewer expects; nixpkgs would rather see the Nim libraries packaged
   individually (or a `buildNimPackage` lockfile). Three of them
   (`nim-shm-gset`, `reprobuild-test-adapters`,
   `codetracer-trace-format-nim`) also carry no LICENSE file, which
   blocks `meta.license` being honest about the whole closure.
