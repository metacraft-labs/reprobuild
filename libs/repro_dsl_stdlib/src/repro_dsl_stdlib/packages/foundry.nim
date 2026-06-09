## Foundry -- Ethereum smart contract toolkit (forge + cast + anvil
## + chisel).
##
## The ``package foundry:`` block declares the Nix provisioning
## consumed by the cakNix adapter on Linux/macOS Nix hosts; the
## ``foundryCatalog`` slice below is consumed by the M65
## cakBuiltin adapter on Windows and non-Nix Linux.
##
## Foundry upstream publishes a single archive per platform that
## bundles all four binaries. On Windows the archive is a flat
## zip; on Linux and macOS it is a flat ``tar.gz``. The bin_relpath
## (parent) lists the Windows binaries; ``bin_relpath_override``
## carries the no-``.exe`` Linux/macOS forms.

import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package foundry:
  provisioning:
    nixPackage "nixpkgs#foundry", executablePath = "bin/forge",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

let foundryCatalog* = @[
  VersionedProvisioning(
    version: "stable",
    archive_format: afZip,
    install_method: imExtract,
    bin_relpath: @[
      "forge.exe", "cast.exe", "anvil.exe", "chisel.exe"
    ],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows,
        url: "https://github.com/foundry-rs/foundry/releases/download/stable/foundry_stable_win32_amd64.zip",
        sha256: "78556c2013c91f9143e4e42608d9305a02ea62a29b942b57c6ff3badf7cdfbab",
        sha512: "",
        extract_path: ""),
      PlatformBinary(cpu: pcX86_64, os: poLinux,
        url: "https://github.com/foundry-rs/foundry/releases/download/stable/foundry_stable_linux_amd64.tar.gz",
        sha256: "9cb14a30fa95c1af1cbeb035272baec0e85298dc18e6a45ca7236eca5ce95474",
        sha512: "",
        sha1: "",
        extract_path: "",
        archive_format_override: afTarGz,
        has_archive_format_override: true,
        bin_relpath_override: @["forge", "cast", "anvil", "chisel"]),
      PlatformBinary(cpu: pcX86_64, os: poMacos,
        url: "https://github.com/foundry-rs/foundry/releases/download/stable/foundry_stable_darwin_amd64.tar.gz",
        sha256: "e3f064d1e18f2085530fcfecee4b4068aa53050ada28115e2543d1834924e49d",
        sha512: "",
        sha1: "",
        extract_path: "",
        archive_format_override: afTarGz,
        has_archive_format_override: true,
        bin_relpath_override: @["forge", "cast", "anvil", "chisel"]),
      PlatformBinary(cpu: pcAArch64, os: poMacos,
        url: "https://github.com/foundry-rs/foundry/releases/download/stable/foundry_stable_darwin_arm64.tar.gz",
        sha256: "c4a8190b7c6947b864181cf31c04eb0ef8e3af4ed2299399fcafa35d3efbc9a2",
        sha512: "",
        sha1: "",
        extract_path: "",
        archive_format_override: afTarGz,
        has_archive_format_override: true,
        bin_relpath_override: @["forge", "cast", "anvil", "chisel"])
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]
