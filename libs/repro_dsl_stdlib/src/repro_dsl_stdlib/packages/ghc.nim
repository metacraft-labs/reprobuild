## Archive realizations harvested by tools/catalog-harvester. GM4b: the
## harvester emits ``tarball`` statements, which live in the hand-maintained
## ``package`` block below; merge a re-harvest into it.
## Harvested from bucket: ScoopInstaller/Main
## Versions (newest-first): 9.12.1
##
## M9.5 (hand-edited): added the x86_64-linux tarball
## realization manually (GHC ships on ``downloads.haskell.org``,
## not GitHub — so the M7 gh-releases harvester doesn't apply). URL
## pattern: ``ghc-<ver>-x86_64-centos7-linux.tar.xz``; sha256 lifted
## from upstream's ``SHA256SUMS``. The CentOS 7 build is selected
## because it floors at glibc 2.17 (RHEL 7) — directly matches the
## M9.5 spec's "glibc-2.17-compatible Linux tarballs" honest-scope
## target. The archive stays ``tar.xz`` (same as Windows), but the
## inner dir is ``ghc-<ver>/`` (vs. the Windows mingw32 variant) and
## binaries lack the .exe suffix.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# The DSL declaration (hand-written; the catalog harvester emits
# ``tarball`` statements to merge into it — GM4b).
#
# What a recipe's ``nativeBuildDeps: "ghc"`` resolves to -- the compiler
# the ``cabal_package`` constructor drives.
#
# * Windows x86_64: upstream's bindist, ``ghc-9.12.1-x86_64-unknown-
#   mingw32.tar.xz`` from downloads.haskell.org, whose SHA-256 below matches
#   upstream's ``SHA256SUMS`` for the release and was re-computed over the
#   downloaded archive (2026-10-01). The bindist is relocatable (it finds
#   its ``lib`` and its bundled MinGW toolchain beside ``bin``), so
#   extracting it IS installing it. ``doc`` (832 MB of the 3.5 GB tree) is
#   pruned: nothing a build runs reads it.
# * Linux and macOS: the pinned nixpkgs' ``ghc``. Upstream's Linux bindists
#   need ``./configure && make install`` before they run, which is not an
#   extraction.
# ---------------------------------------------------------------------------

package ghc:
  provisioning:
    nixPackage "nixpkgs#ghc", executablePath = "bin/ghc",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    tarball url = "https://downloads.haskell.org/~ghc/9.12.1/ghc-9.12.1-x86_64-unknown-mingw32.tar.xz",
      sha256 = "22dc942be1b968d5e28e75c06aba52829d0c52d9234bc9941df9ab2a0e2a610d",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/ghc.exe",
      prunePaths = @["doc"],
      packageId = "ghc@9.12.1",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:ghc@9.12.1:windows-x86_64:sha256:22dc942be1b968d5e28e75c06aba52829d0c52d9234bc9941df9ab2a0e2a610d",
      version = "9.12.1",
      extraExecutable = "bin\\ghci.exe",
      extraExecutable = "bin\\ghc-pkg.exe",
      extraExecutable = "bin\\haddock.exe",
      extraExecutable = "bin\\hp2ps.exe",
      extraExecutable = "bin\\hpc.exe",
      extraExecutable = "bin\\hsc2hs.exe",
      extraExecutable = "bin\\runghc.exe"
    # GM4b: archive realizations formerly held by the retired
    # `VersionedProvisioning` catalog record (see the conflict notes
    # in the Gradual-Nix-To-Reprobuild-Migration GM4b milestone).
    tarball url = "https://downloads.haskell.org/~ghc/9.12.1/ghc-9.12.1-x86_64-centos7-linux.tar.xz",
      sha256 = "13b211eaacb85a3579e3523b0178ecc41a95486edd2fb7c82edcbb71981ffdc9",
      archiveType = "tar.xz",
      executablePath = "bin/ghc-9.12.1",
      extraExecutable = "bin/ghci-9.12.1",
      extraExecutable = "bin/ghc-pkg-9.12.1",
      extraExecutable = "bin/haddock-ghc-9.12.1",
      extraExecutable = "bin/hp2ps",
      extraExecutable = "bin/hpc",
      extraExecutable = "bin/hsc2hs",
      extraExecutable = "bin/runghc-9.12.1",
      version = "9.12.1",
      packageId = "ghc@9.12.1",
      extractPath = "ghc-9.12.1",
      cpu = "x86_64",
      os = "linux"
