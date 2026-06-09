## Circom -- zk-SNARK circuit compiler from iden3.
##
## No ``nixpkgs#circom`` is available at the catalog-wide pinned
## nixpkgs rev; the metacraft-labs ``nix-blockchain-development``
## flake carries an out-of-tree ``self'.packages.circom`` instead.
## The catalog here pulls upstream's signed GitHub-release binaries
## directly, so the recorder dev env stays self-contained on
## Windows and non-Nix Linux. On Nix-based Linux/macOS the
## ``mcl-blockchain`` overlay remains authoritative; the cakNix
## adapter consults that flake before falling through to cakBuiltin.
##
## The version matches the ``nix-blockchain-development`` pin
## (``packages/circom/default.nix`` -> ``version = "2.1.5"``), so
## the three dev-shell paths (nix, repro builtin, env.ps1) agree on
## which compiler the recorder sees.
##
## ``codetracer-circom-recorder``'s ``bus_type`` fixtures additionally
## pull in circom 2.2.3 via ``CIRCOM_2_2_BIN``; that secondary binary
## is a per-test runtime input, not a dev-env tool, so it stays out
## of this catalog entry and is the recorder's responsibility to
## provision at test time.

import std/tables
import repro_dsl_stdlib/packages_schema
export packages_schema

# iden3/circom releases publish raw, platform-keyed binaries (no
# archive wrapper). ``afRaw`` tells the realize loop to copy the
# downloaded bytes into the prefix at the ``bin_relpath`` leaf
# rather than running an extractor.

let circomCatalog* = @[
  VersionedProvisioning(
    version: "2.1.5",
    archive_format: afRaw,
    install_method: imExtract,
    bin_relpath: @["bin\\circom.exe"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows,
        url: "https://github.com/iden3/circom/releases/download/v2.1.5/circom-windows-amd64.exe",
        sha256: "bea0d676ab6b3ac015cfd53260a35b4e447e7aa4c3385f741481309796c71106",
        sha512: "",
        extract_path: ""),
      PlatformBinary(cpu: pcX86_64, os: poLinux,
        url: "https://github.com/iden3/circom/releases/download/v2.1.5/circom-linux-amd64",
        sha256: "8bbceaa993e757998808cfe9966daa80da04f41505f22c989c62f66e8ce2dcb2",
        sha512: "",
        sha1: "",
        extract_path: "",
        bin_relpath_override: @["bin/circom"]),
      PlatformBinary(cpu: pcX86_64, os: poMacos,
        url: "https://github.com/iden3/circom/releases/download/v2.1.5/circom-macos-amd64",
        sha256: "9e5ab9e950c553d4ac3a6e1f84a310d04273cf55405663e9765a8daf4460714e",
        sha512: "",
        sha1: "",
        extract_path: "",
        bin_relpath_override: @["bin/circom"])
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]
