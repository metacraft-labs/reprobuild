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
## target. The archive stays ``tar.xz`` (same as Windows), and
## binaries lack the .exe suffix.
##
## ## The Linux arm's layout, measured (2026-10-14)
##
## Both of this arm's layout claims were wrong, and neither could be noticed
## from the recipe: a declared path is a claim about a third party's archive.
## The catalog conformance sweep realizes each arm and probes it, and it
## found them (reprobuild-pm/issues/
## 2026-09-24-no-conformance-check-runs-against-stdlib-tarball-arms.md):
##
## * the inner directory is ``ghc-9.12.1-x86_64-unknown-linux/``, not
##   ``ghc-9.12.1/``. With the wrong ``extractPath`` the realize failed with
##   "extract_path 'ghc-9.12.1' not present", so the arm had never realized;
## * ``bin/ghci-9.12.1`` does not exist in the bindist. ``ghci`` is not a
##   program: it is a generated shell wrapper around ``ghc --interactive``,
##   and the bindist carries it only as an install-time TEMPLATE under the
##   separate top-level ``wrappers/`` directory, which ``make install``
##   substitutes. The seven other declared paths ARE real binaries in
##   ``bin/`` (``ghc-9.12.1`` is a 2 MB ELF), which is why extraction is a
##   realization here at all. The Windows mingw32 bindist does ship a real
##   ``bin/ghci.exe``, so that arm keeps its claim — the asymmetry is
##   upstream's, not ours.

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
# * Linux x86_64: upstream's CentOS 7 bindist, extracted and FLATTENED
#   (``extractPath = "ghc-9.12.1-x86_64-unknown-linux"``), realized by the
#   home archive realizer — an ``extractPath`` flatten is work the ``uses:``
#   provisioning edge does not perform. Its ``bin/`` carries the real
#   binaries, so an extraction does bind them. This entry used to read
#   "Linux and macOS: the pinned nixpkgs' ``ghc``. Upstream's Linux bindists
#   need ``./configure && make install`` before they run", which overstated
#   what the archive contains and read as though there were no Linux tarball
#   arm at all — which is how a wrong ``extractPath`` survived in one.
#
#   **nix remains the sensible default channel on Linux, for a measured
#   reason.** ``bin/ghc-9.12.1`` out of the realized prefix does not start on
#   a current Linux host: ``error while loading shared libraries:
#   libtinfo.so.5``, the CentOS-7-era ncurses5 soname nothing modern ships.
#   That is runnability rather than conformance — the arm's declared paths
#   exist and are executable, which is what Provisioning-Contributions.md
#   §"Conformance And Trust" asks of it — and it is the case recorded as
#   ``issues/2026-09-28-tarball-realized-linux-executables-cannot-start-on-
#   nixos.md``.
# * macOS: the pinned nixpkgs' ``ghc``. There is no macOS tarball arm.
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
      # No ``bin/ghci-9.12.1``: see the layout note in the header. The
      # bindist has it only as an install-time template under ``wrappers/``,
      # so declaring it bound an exported executable the realization cannot
      # produce. ``ghc-9.12.1 --interactive`` is the interpreter.
      extraExecutable = "bin/ghc-pkg-9.12.1",
      extraExecutable = "bin/haddock-ghc-9.12.1",
      extraExecutable = "bin/hp2ps",
      extraExecutable = "bin/hpc",
      extraExecutable = "bin/hsc2hs",
      extraExecutable = "bin/runghc-9.12.1",
      version = "9.12.1",
      packageId = "ghc@9.12.1",
      extractPath = "ghc-9.12.1-x86_64-unknown-linux",
      cpu = "x86_64",
      os = "linux"
