## M68 merge note (hand-edited): the auto-generated ``ghCatalog`` body
## sits below the pre-existing ``package gh:`` Nix block. The Nix
## block remains the source of truth for Nix-capable hosts; the
## ``ghCatalog`` slice below is consumed by the M64 ``cakBuiltin``
## adapter on Windows. Re-harvest emits ONLY the catalog half;
## re-attach the Nix block by hand if you regenerate.

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
      PlatformBinary(cpu: pcAArch64, os: poWindows, url: "https://github.com/cli/cli/releases/download/v2.93.0/gh_2.93.0_windows_arm64.zip", sha256: "1d2ab9d48f01a86c7156dae3008428743d6cd716a51fc50410078d51dec3dea4", sha512: "", extract_path: "")
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]
