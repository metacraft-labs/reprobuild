## ``taplo`` — the TOML formatter and linter.
##
## The ``taplo-fmt`` pre-commit hook runs it over every TOML file in the
## tree, so it is part of the contributor gate rather than an optional
## convenience.
##
## Upstream's Windows zips carry ``taplo.exe`` flat at the archive root, so
## no strip and no inner path. Version 0.10.0, matching the
## ``DIY_TAPLO_CLI_VERSION`` pin its consumers carry; digests were computed
## from the upstream release assets on 2026-09-16.
##
## Note the crate is published as ``taplo-cli`` while the program and the
## package interface are ``taplo`` — the package name is the program's name,
## not the crate's.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

const
  TaploVersion = "0.10.0"
  TaploBase = "https://github.com/tamasfe/taplo/releases/download/" &
    TaploVersion & "/taplo-"

package taplo:
  provisioning:
    nixPackage "nixpkgs#taplo", executablePath = "bin/taplo",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

    tarball url = TaploBase & "windows-x86_64.zip",
      sha256 = "1615eed140039bd58e7089109883b1c434de5d6de8f64a993e6e8c80ca57bdf9",
      archiveType = "zip",
      executablePath = "taplo.exe",
      packageId = "taplo@" & TaploVersion,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:taplo@" & TaploVersion &
        ":windows-x86_64:sha256:1615eed140039bd58e7089109883b1c434de5d6de8f64a993e6e8c80ca57bdf9"

    tarball url = TaploBase & "windows-aarch64.zip",
      sha256 = "65a50c5d3b78f6014e6bc6d64eb6dc1d4992bc236589c9bb29e5609fc3454674",
      archiveType = "zip",
      executablePath = "taplo.exe",
      packageId = "taplo@" & TaploVersion,
      cpu = "aarch64",
      os = "windows",
      lockIdentity = "tarball:taplo@" & TaploVersion &
        ":windows-aarch64:sha256:65a50c5d3b78f6014e6bc6d64eb6dc1d4992bc236589c9bb29e5609fc3454674"
