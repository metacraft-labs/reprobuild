## ``prek`` — a fast, Rust reimplementation of the pre-commit hook runner.
##
## Agent Harbor's contributor gate is ``prek run`` rather than ``pre-commit
## run``; the two read the same ``.pre-commit-config.yaml`` but prek needs no
## Python environment of its own, which is why the Windows dev environment
## pins it instead of bootstrapping pre-commit.
##
## Upstream publishes per-target zips with the binary flat at the archive
## root, so no strip and no inner path. Version 0.3.2; both Windows digests
## are the ``PREK_SHA256_*`` values Agent Harbor's pin file already carries.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

const
  PrekVersion = "0.3.2"
  PrekBase = "https://github.com/j178/prek/releases/download/v" & PrekVersion & "/prek-"

package prek:
  provisioning:
    nixPackage "nixpkgs#prek", executablePath = "bin/prek",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

    tarball url = PrekBase & "x86_64-pc-windows-msvc.zip",
      sha256 = "4aaf87523d3588090a6f547a5eca379264ddb287e3a424a1fab73aca6cd9c0c0",
      archiveType = "zip",
      executablePath = "prek.exe",
      packageId = "prek@" & PrekVersion,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:prek@" & PrekVersion &
        ":windows-x86_64:sha256:4aaf87523d3588090a6f547a5eca379264ddb287e3a424a1fab73aca6cd9c0c0"

    tarball url = PrekBase & "aarch64-pc-windows-msvc.zip",
      sha256 = "14694b2623fffa38402dbdc1c2208c91400557fd44f7083160853e6027b125d7",
      archiveType = "zip",
      executablePath = "prek.exe",
      packageId = "prek@" & PrekVersion,
      cpu = "aarch64",
      os = "windows",
      lockIdentity = "tarball:prek@" & PrekVersion &
        ":windows-aarch64:sha256:14694b2623fffa38402dbdc1c2208c91400557fd44f7083160853e6027b125d7"
