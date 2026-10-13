## Solc -- Solidity compiler from the Ethereum Foundation.
##
## The ``package solc:`` block declares the Nix provisioning and the
## direct-download ``tarball`` realizations; a recipe's ``uses:`` and a
## home profile select among them the same way (GM4b merged the former
## ``solcCatalog`` copy into the ``tarball`` statements).
##
## solc upstream publishes a raw single-file binary per platform
## (the Solidity build is statically linked on Linux and uses a
## monolithic ``solc-windows.exe`` on Windows); ``raw`` tells the
## realize loop to copy the downloaded bytes into the prefix at
## the ``executablePath`` leaf rather than running an extractor.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
export packages_schema

package solc:
  provisioning:
    nixPackage "nixpkgs#solc", executablePath = "bin/solc",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Direct-download: argotorg/solidity publishes raw per-platform
    # solc binaries (no archive wrapper). The reprobuild tarball
    # resolver copies the verified download to ``executablePath``
    # inside the realized prefix when ``archiveType = "raw"``. A home
    # profile's ``package "solc"`` selects from these same statements.
    tarball url = "https://github.com/argotorg/solidity/releases/download/v0.8.28/solc-windows.exe",
      sha256 = "76a71001309810aafd0462d9b2f2612bf19b89550c866140edca26e533de06bc",
      archiveType = "raw",
      stripComponents = 0,
      executablePath = "bin/solc.exe",
      packageId = "solc@0.8.28",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:solc@0.8.28:sha256:76a71001309810aafd0462d9b2f2612bf19b89550c866140edca26e533de06bc",
      version = "0.8.28"
    tarball url = "https://github.com/argotorg/solidity/releases/download/v0.8.28/solc-static-linux",
      sha256 = "9a0fb7e0db2c0641dbae1c5cc645dc686820c83af516226abb1c0a2f76636f25",
      archiveType = "raw",
      stripComponents = 0,
      executablePath = "bin/solc",
      packageId = "solc@0.8.28",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:solc@0.8.28:sha256:9a0fb7e0db2c0641dbae1c5cc645dc686820c83af516226abb1c0a2f76636f25",
      version = "0.8.28"
    tarball url = "https://github.com/argotorg/solidity/releases/download/v0.8.28/solc-macos",
      sha256 = "81515b0e53deaa266d549545ccaac0a5a96e6d4e8201c77f673b2c710976d9ea",
      archiveType = "raw",
      stripComponents = 0,
      executablePath = "bin/solc",
      packageId = "solc@0.8.28",
      cpu = "x86_64",
      os = "macos",
      lockIdentity = "tarball:solc@0.8.28:sha256:81515b0e53deaa266d549545ccaac0a5a96e6d4e8201c77f673b2c710976d9ea",
      version = "0.8.28"
