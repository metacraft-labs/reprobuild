## Archive realizations harvested by tools/catalog-harvester. GM4b: the
## harvester emits ``tarball`` statements, which live in the hand-maintained
## ``package`` block below; merge a re-harvest into it.
## Harvested from bucket: ScoopInstaller/Main
## Versions (newest-first): 3.16.1.0
##
## M9.5 (hand-edited): added the x86_64-linux tarball
## realization manually (cabal ships on ``downloads.haskell.org``,
## not GitHub Releases — the M7 gh-releases harvester doesn't apply).
## URL pattern: ``cabal-install-<ver>-x86_64-linux-deb10.tar.xz``;
## sha256 lifted from upstream's ``SHA256SUMS``. The Debian 10 build
## is the LOWEST glibc floor cabal 3.16.1.0 publishes (glibc 2.28 /
## Debian Buster). M9.5 spec's glibc-2.17 honest-scope target is NOT
## met for cabal — operators on RHEL 7 / Ubuntu 14.04 era distros
## should fall back to the nix realization; documented here for the operator's
## awareness. The archive stays ``tar.xz``; cabal ships a single flat
## ``cabal`` binary inside the tarball (no inner dir).

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# The DSL declaration (hand-written; the catalog harvester emits
# ``tarball`` statements to merge into it — GM4b).
#
# ``cabal-install``, the build driver the ``cabal_package`` constructor runs.
# Upstream's release archives from downloads.haskell.org, each a single
# ``cabal`` executable at the archive root; the SHA-256s match upstream's
# ``SHA256SUMS`` for 3.16.1.0 and were re-computed over the downloaded
# archives (2026-10-01). macOS and Linux arm64 take the pinned nixpkgs'
# ``cabal-install``.
# ---------------------------------------------------------------------------

package cabal:
  provisioning:
    nixPackage "nixpkgs#cabal-install", executablePath = "bin/cabal",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    tarball url = "https://downloads.haskell.org/~cabal/cabal-install-3.16.1.0/cabal-install-3.16.1.0-x86_64-windows.zip",
      sha256 = "7f760fd4afde9bf3f592d71055c1ad6068d297c45244a3f71a5d7cad484d5afd",
      archiveType = "zip",
      executablePath = "cabal.exe",
      packageId = "cabal@3.16.1.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:cabal@3.16.1.0:windows-x86_64:sha256:7f760fd4afde9bf3f592d71055c1ad6068d297c45244a3f71a5d7cad484d5afd",
      version = "3.16.1.0"
    tarball url = "https://downloads.haskell.org/~cabal/cabal-install-3.16.1.0/cabal-install-3.16.1.0-x86_64-linux-deb10.tar.xz",
      sha256 = "f8bbdae03898a072fcdfbf3abc4b067587afa26222ac47821e78611ca0caa40f",
      archiveType = "tar.xz",
      executablePath = "cabal",
      packageId = "cabal@3.16.1.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:cabal@3.16.1.0:linux-x86_64:sha256:f8bbdae03898a072fcdfbf3abc4b067587afa26222ac47821e78611ca0caa40f",
      version = "3.16.1.0"
