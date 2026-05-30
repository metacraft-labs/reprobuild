## M68 merge note (hand-edited): the auto-generated ``justCatalog`` body
## sits below the pre-existing ``package just:`` Nix block. The Nix
## block remains the source of truth for Nix-capable hosts; the
## ``justCatalog`` slice below is consumed by the M64 ``cakBuiltin``
## adapter on Windows. Re-harvest emits ONLY the catalog half;
## re-attach the Nix block by hand if you regenerate.

import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# Pre-existing M21 Nix provisioning (preserved across the M68 harvest).
# ---------------------------------------------------------------------------

package just:
  provisioning:
    nixPackage "nixpkgs#just", executablePath = "bin/just",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

# ---------------------------------------------------------------------------
# M68 bulk-harvest catalog (cakBuiltin adapter consumer on Windows).
# Harvested from bucket: ScoopInstaller/Main
# Versions (newest-first): 1.51.0
# ---------------------------------------------------------------------------

let justCatalog* = @[
  VersionedProvisioning(
    version: "1.51.0",
    archive_format: afZip,
    install_method: imExtract,
    bin_relpath: @["just.exe"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows, url: "https://github.com/casey/just/releases/download/1.51.0/just-1.51.0-x86_64-pc-windows-msvc.zip", sha256: "09d1138b6845e73f04bff5e26be3f57663bddca25e36fe6241d28a5aa310b64e", sha512: "", extract_path: "")
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]
