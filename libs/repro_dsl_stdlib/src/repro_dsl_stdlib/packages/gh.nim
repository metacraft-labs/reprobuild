## M68 merge note (hand-edited): the auto-generated ``ghCatalog`` body
## sits below the pre-existing ``package gh:`` Nix block. The Nix
## block remains the source of truth for Nix-capable hosts; the
## ``ghCatalog`` slice below is consumed by the M64 ``cakBuiltin``
## adapter on Windows. Re-harvest emits ONLY the catalog half;
## re-attach the Nix block by hand if you regenerate.
##
## **M9.5 merge note (hand-edited):** added a ``(pcX86_64, poLinux)``
## platform slice harvested via ``--source gh-releases:cli/cli
## --asset-pattern 'gh_2\.93\.0_linux_amd64\.tar\.gz' --platform-os
## linux``. The Linux tarball is ``afTarGz`` (vs. the Windows ``afZip``)
## and the inner ``bin/gh`` binary nests under
## ``gh_<ver>_linux_amd64/`` — both encoded via the M9.5 per-platform
## overrides (``archive_format_override`` + ``bin_relpath_override``).
## glibc floor: the gh upstream builds against the GoReleaser default
## (RHEL/CentOS 7 era, glibc 2.17+), satisfying the M9.5 spec's
## "glibc-2.17-compatible Linux tarballs" honest-scope target.

import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# Pre-existing M21 Nix provisioning (preserved across the M68 harvest).
# ---------------------------------------------------------------------------

package gh:
  provisioning:
    nixPackage "nixpkgs#gh", executablePath = "bin/gh",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

# ---------------------------------------------------------------------------
# M68 bulk-harvest catalog (cakBuiltin adapter consumer on Windows).
# Harvested from bucket: ScoopInstaller/Main
# Versions (newest-first): 2.93.0
# ---------------------------------------------------------------------------

let ghCatalog* = @[
  VersionedProvisioning(
    version: "2.93.0",
    archive_format: afZip,
    install_method: imExtract,
    bin_relpath: @["bin\\gh.exe"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows, url: "https://github.com/cli/cli/releases/download/v2.93.0/gh_2.93.0_windows_amd64.zip", sha256: "77aa01ed7317295ad550de0ad04f3f276b1ef0e9272e3d002ac28dd99853d211", sha512: "", extract_path: ""),
      PlatformBinary(cpu: pcAArch64, os: poWindows, url: "https://github.com/cli/cli/releases/download/v2.93.0/gh_2.93.0_windows_arm64.zip", sha256: "1d2ab9d48f01a86c7156dae3008428743d6cd716a51fc50410078d51dec3dea4", sha512: "", extract_path: ""),
      # M9.5: Linux x86_64 slice. archive_format_override = afTarGz
      # (Windows is afZip); bin_relpath_override = the linux tarball's
      # nested ``gh_<ver>_linux_amd64/bin/gh`` path.
      PlatformBinary(cpu: pcX86_64, os: poLinux, url: "https://github.com/cli/cli/releases/download/v2.93.0/gh_2.93.0_linux_amd64.tar.gz", sha256: "02d1290eba130e0b896f3709ffff22e1c75a51475ddb70476a85abc6b5807af0", sha512: "", sha1: "", extract_path: "", archive_format_override: afTarGz, has_archive_format_override: true, bin_relpath_override: @["gh_2.93.0_linux_amd64/bin/gh"])
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]
