## Forc -- the Fuel/Sway compiler driver.
##
## No ``nixpkgs#forc`` is available at the catalog-wide pinned
## nixpkgs rev; the metacraft-labs ``nix-blockchain-development``
## flake builds forc from source (FuelLabs/sway, pinned to
## ``v0.70.3``). The catalog here pulls the matching upstream
## ``forc-binaries`` release tarballs so the recorder dev env stays
## self-contained on non-Nix hosts.
##
## FuelLabs publishes Linux and macOS tarballs only -- there is no
## Windows artefact upstream as of v0.70.3. Windows users currently
## rely on WSL or the env.ps1 fallback; the recorder's Windows DIY
## path documents this gap.
##
## The release tarball bundles ``forc``, ``forc-fmt``, ``forc-lsp``,
## ``forc-deploy``, and ``forc-run`` together under a single
## ``forc-binaries/`` directory. ``bin_relpath`` walks each binary
## via per-platform overrides because the tarball is flat (the
## inner ``forc-binaries/`` dir is the only nesting).

import std/tables
import repro_dsl_stdlib/packages_schema
export packages_schema

let forcCatalog* = @[
  VersionedProvisioning(
    version: "0.70.3",
    archive_format: afTarGz,
    install_method: imExtract,
    bin_relpath: @[
      "forc-binaries/forc",
      "forc-binaries/forc-fmt",
      "forc-binaries/forc-lsp",
      "forc-binaries/forc-deploy",
      "forc-binaries/forc-run"
    ],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poLinux,
        url: "https://github.com/FuelLabs/sway/releases/download/v0.70.3/forc-binaries-linux_amd64.tar.gz",
        sha256: "572a61acae22887e28b1f3222b98951ae4cf253cab1d6c5668f71aee239f07cc",
        sha512: "",
        sha1: "",
        extract_path: ""),
      PlatformBinary(cpu: pcX86_64, os: poMacos,
        url: "https://github.com/FuelLabs/sway/releases/download/v0.70.3/forc-binaries-darwin_amd64.tar.gz",
        sha256: "801ff4749eb8681229c8d4ce74142a8f206b9b0e79c626a3936beaec19f1646e",
        sha512: "",
        sha1: "",
        extract_path: ""),
      PlatformBinary(cpu: pcAArch64, os: poMacos,
        url: "https://github.com/FuelLabs/sway/releases/download/v0.70.3/forc-binaries-darwin_arm64.tar.gz",
        sha256: "14d24cd9a42ff2499464592e13e4806aec3e3669768013e24cc98e2be0b573c2",
        sha512: "",
        sha1: "",
        extract_path: "")
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]
