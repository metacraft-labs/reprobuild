## ``cargo-sort`` — keeps ``Cargo.toml`` dependency tables sorted.
##
## A ``cargo-sort`` pre-commit hook runs it in check mode over the workspace,
## so an unsorted manifest fails the gate.
##
## Upstream's Windows zip carries ``cargo-sort.exe`` flat at the archive
## root. Version 2.0.2, the pin its consumers carry — upstream has since
## released 2.1.x, and bumping is a separate decision from packaging what is
## pinned today.
##
## Windows and Linux only: upstream publishes an ``aarch64-apple-darwin``
## asset but no x86_64 macOS one, and the nix channel covers macOS anyway.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

const
  CargoSortVersion = "2.0.2"
  CargoSortBase =
    "https://github.com/DevinR528/cargo-sort/releases/download/v" &
    CargoSortVersion & "/cargo-sort-"

package `cargo-sort`:
  provisioning:
    nixPackage "nixpkgs#cargo-sort", executablePath = "bin/cargo-sort",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

    tarball url = CargoSortBase & "x86_64-pc-windows-msvc.zip",
      sha256 = "83c7e38a9eec715a3e316371e660d210d20c3b197099dcc38577a9d343b027d5",
      archiveType = "zip",
      executablePath = "cargo-sort.exe",
      packageId = "cargo-sort@" & CargoSortVersion,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:cargo-sort@" & CargoSortVersion &
        ":windows-x86_64:sha256:83c7e38a9eec715a3e316371e660d210d20c3b197099dcc38577a9d343b027d5"
