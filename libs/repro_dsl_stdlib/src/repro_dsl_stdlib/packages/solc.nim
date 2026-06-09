## Solc -- Solidity compiler from the Ethereum Foundation.
##
## The ``package solc:`` block declares the Nix provisioning
## consumed by the cakNix adapter on Linux/macOS Nix hosts; the
## ``solcCatalog`` slice below is consumed by the M65 cakBuiltin
## adapter on Windows and non-Nix Linux.
##
## solc upstream publishes a raw single-file binary per platform
## (the Solidity build is statically linked on Linux and uses a
## monolithic ``solc-windows.exe`` on Windows); ``afRaw`` tells the
## realize loop to copy the downloaded bytes into the prefix at
## the ``bin_relpath`` leaf rather than running an extractor.

import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package solc:
  provisioning:
    nixPackage "nixpkgs#solc", executablePath = "bin/solc",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

let solcCatalog* = @[
  VersionedProvisioning(
    version: "0.8.28",
    archive_format: afRaw,
    install_method: imExtract,
    bin_relpath: @["bin\\solc.exe"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows,
        url: "https://github.com/argotorg/solidity/releases/download/v0.8.28/solc-windows.exe",
        sha256: "76a71001309810aafd0462d9b2f2612bf19b89550c866140edca26e533de06bc",
        sha512: "",
        extract_path: ""),
      PlatformBinary(cpu: pcX86_64, os: poLinux,
        url: "https://github.com/argotorg/solidity/releases/download/v0.8.28/solc-static-linux",
        sha256: "9a0fb7e0db2c0641dbae1c5cc645dc686820c83af516226abb1c0a2f76636f25",
        sha512: "",
        sha1: "",
        extract_path: "",
        bin_relpath_override: @["bin/solc"]),
      PlatformBinary(cpu: pcX86_64, os: poMacos,
        url: "https://github.com/argotorg/solidity/releases/download/v0.8.28/solc-macos",
        sha256: "81515b0e53deaa266d549545ccaac0a5a96e6d4e8201c77f673b2c710976d9ea",
        sha512: "",
        sha1: "",
        extract_path: "",
        bin_relpath_override: @["bin/solc"])
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]
