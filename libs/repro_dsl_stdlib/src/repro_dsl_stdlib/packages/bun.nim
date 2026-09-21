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
    # Direct-download: official bun release archives from oven-sh/bun's
    # GitHub Releases. Before this, bun had ONLY the Nix selector above, so a
    # Windows / non-Nix Linux host — where every other JS runtime (node, npm,
    # npx) already resolves through a direct-download tarball — could not
    # provision bun at all. That is the gap that blocked opencode's Bun build
    # off Nix. Each asset is a `.zip` whose single top-level `bun-<triple>/`
    # dir holds the `bun` binary, so `stripComponents = 1` flattens it and the
    # binary lands at `<prefix>/bun` (`bun.exe` on Windows). Digests are the
    # sha256 of each release asset (verified by download); the engine
    # deduplicates by content hash. URL + version: bun-v1.4.2.
    tarball url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.2/bun-windows-x64.zip",
      sha256 = "ce4c17497b2f29712a99d3d53f028de28cd42e3bacb8589599e7f000e49b6405",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "bun.exe",
      packageId = "bun@1.4.2",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:bun@1.4.2:sha256:ce4c17497b2f29712a99d3d53f028de28cd42e3bacb8589599e7f000e49b6405"
    tarball url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.2/bun-linux-x64.zip",
      sha256 = "36368faef7527875d5ffa52e53cd48021741f2a83eb6208a8dd64068d422a913",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "bun",
      packageId = "bun@1.4.2",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:bun@1.4.2:linux:sha256:36368faef7527875d5ffa52e53cd48021741f2a83eb6208a8dd64068d422a913"
    tarball url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.2/bun-darwin-aarch64.zip",
      sha256 = "90987a3a16d7db556d886ac3d551e7b6d3edf0a1cf43acaed622e8676be1d12f",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "bun",
      packageId = "bun@1.4.2",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:bun@1.4.2:macos-aarch64:sha256:90987a3a16d7db556d886ac3d551e7b6d3edf0a1cf43acaed622e8676be1d12f"
    tarball url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.2/bun-darwin-x64.zip",
      sha256 = "80520d7e17526308c9185d261679ac6d27798d3803a0e9f7ff9121ab8affb012",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "bun",
      packageId = "bun@1.4.2",
      cpu = "x86_64",
      os = "macos",
      lockIdentity = "tarball:bun@1.4.2:macos-x64:sha256:80520d7e17526308c9185d261679ac6d27798d3803a0e9f7ff9121ab8affb012"
