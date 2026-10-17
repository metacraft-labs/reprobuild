## Foundry -- Ethereum smart contract toolkit (forge + cast + anvil
## + chisel).
##
## The ``package foundry:`` block declares the Nix provisioning and the
## direct-download ``tarball`` realizations; a recipe's ``uses:`` and a
## home profile select among them the same way (GM4b merged the former
## ``foundryCatalog`` copy into the ``tarball`` statements).
##
## Foundry upstream publishes a single archive per platform that
## bundles all four binaries. On Windows the archive is a flat
## zip; on Linux and macOS it is a flat ``tar.gz``. Each ``tarball``
## statement declares ``forge`` as its ``executablePath`` and the other
## three as ``extraExecutable`` (``.exe`` forms on Windows).

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
export packages_schema

package foundry:
  provisioning:
    nixPackage "nixpkgs#foundry", executablePath = "bin/forge",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Foundry upstream ships one flat archive per platform that bundles
    # forge / cast / anvil / chisel at the archive root (no top-level
    # directory). The reprobuild tarball resolver extracts the verified
    # download into the realized prefix; ``executablePath`` is the path
    # to the canonical binary INSIDE the archive (the ``executable
    # foundry: name: "forge"`` clause below maps the logical use name
    # ``foundry`` to ``forge[.exe]``). A home profile's
    # ``package "foundry"`` selects from these same statements.
    tarball url = "https://github.com/foundry-rs/foundry/releases/download/stable/foundry_stable_win32_amd64.zip",
      sha256 = "78556c2013c91f9143e4e42608d9305a02ea62a29b942b57c6ff3badf7cdfbab",
      archiveType = "zip",
      stripComponents = 0,
      executablePath = "forge.exe",
      packageId = "foundry@stable",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:foundry@stable:sha256:78556c2013c91f9143e4e42608d9305a02ea62a29b942b57c6ff3badf7cdfbab",
      version = "stable",
      extraExecutable = "cast.exe",
      extraExecutable = "anvil.exe",
      extraExecutable = "chisel.exe"
    tarball url = "https://github.com/foundry-rs/foundry/releases/download/stable/foundry_stable_linux_amd64.tar.gz",
      sha256 = "9cb14a30fa95c1af1cbeb035272baec0e85298dc18e6a45ca7236eca5ce95474",
      archiveType = "tar.gz",
      stripComponents = 0,
      executablePath = "forge",
      packageId = "foundry@stable",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:foundry@stable:sha256:9cb14a30fa95c1af1cbeb035272baec0e85298dc18e6a45ca7236eca5ce95474",
      version = "stable",
      extraExecutable = "cast",
      extraExecutable = "anvil",
      extraExecutable = "chisel"
    tarball url = "https://github.com/foundry-rs/foundry/releases/download/stable/foundry_stable_darwin_amd64.tar.gz",
      sha256 = "e3f064d1e18f2085530fcfecee4b4068aa53050ada28115e2543d1834924e49d",
      archiveType = "tar.gz",
      stripComponents = 0,
      executablePath = "forge",
      packageId = "foundry@stable",
      cpu = "x86_64",
      os = "macos",
      lockIdentity = "tarball:foundry@stable:sha256:e3f064d1e18f2085530fcfecee4b4068aa53050ada28115e2543d1834924e49d",
      version = "stable",
      extraExecutable = "cast",
      extraExecutable = "anvil",
      extraExecutable = "chisel"
    tarball url = "https://github.com/foundry-rs/foundry/releases/download/stable/foundry_stable_darwin_arm64.tar.gz",
      sha256 = "c4a8190b7c6947b864181cf31c04eb0ef8e3af4ed2299399fcafa35d3efbc9a2",
      archiveType = "tar.gz",
      stripComponents = 0,
      executablePath = "forge",
      packageId = "foundry@stable",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:foundry@stable:sha256:c4a8190b7c6947b864181cf31c04eb0ef8e3af4ed2299399fcafa35d3efbc9a2",
      version = "stable",
      extraExecutable = "cast",
      extraExecutable = "anvil",
      extraExecutable = "chisel"

  # The Foundry archive bundles four binaries (forge / cast / anvil /
  # chisel) but ships no ``foundry`` wrapper. Recipes still declare
  # ``uses: "foundry"`` as the logical selector for the toolchain; this
  # ``executable`` block tells the resolver that the package's canonical
  # binary basename is ``forge`` so a path-mode lookup of the use
  # ``foundry`` probes ``forge[.exe]`` rather than the non-existent
  # ``foundry[.exe]``. (Tarball-mode resolution already picks up
  # ``forge[.exe]`` from the ``tarball`` statements' ``executablePath``;
  # this block keeps the two modes in agreement without forcing a
  # ``forge.exe`` -> ``foundry.exe`` copy hack at provisioning time.)
  executable foundry:
    name: "forge"
