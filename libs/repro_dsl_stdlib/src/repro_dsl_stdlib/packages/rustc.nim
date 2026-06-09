## Rustc -- the Rust compiler driver.
##
## The ``package rustc:`` block declares the Nix provisioning
## consumed by the cakNix adapter on Linux/macOS Nix hosts; the
## ``rustcCatalog`` slice below is consumed by the M65 cakBuiltin
## adapter on Windows and non-Nix Linux. The catalog downloads the
## per-channel Rust toolchain archive
## (``rust-<ver>-<triple>.tar.xz``) and surfaces ``rustc`` plus its
## supporting binaries on the realized prefix's PATH.
##
## A correctly working rustc install needs the matching
## ``rust-std-<triple>`` component the archive bundles alongside
## ``rustc/`` (the standard library), so the realize loop extracts
## the archive whole and the bin_relpath just exposes the front
## binaries; the std-lib lives at
## ``rust-std-<triple>/lib/rustlib/<triple>/lib`` inside the same
## prefix and is found via the rustc binary's known-relative search
## path.
##
## The catalog pins Rust 1.85.0 to match the recorder dev shells'
## ``rustc >=1.85`` constraint. ``cargo`` / ``rustfmt`` / ``clippy``
## have their own catalog entries that download the same archive and
## point at their respective ``<component>/bin/`` paths.

import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package rustc:
  provisioning:
    nixPackage "nixpkgs#rustc", executablePath = "bin/rustc",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

let rustcCatalog* = @[
  VersionedProvisioning(
    version: "1.85.0",
    archive_format: afTarXz,
    install_method: imExtract,
    bin_relpath: @["rustc\\bin\\rustc.exe"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows,
        url: "https://static.rust-lang.org/dist/rust-1.85.0-x86_64-pc-windows-msvc.tar.xz",
        sha256: "6f04dd4cc0ce1bb69507fb7b61ce8d502a58d70abc3dfb0b90b8ae12222b8f46",
        sha512: "",
        extract_path: "rust-1.85.0-x86_64-pc-windows-msvc"),
      PlatformBinary(cpu: pcX86_64, os: poLinux,
        url: "https://static.rust-lang.org/dist/rust-1.85.0-x86_64-unknown-linux-gnu.tar.xz",
        sha256: "6f8b323ed2a34ccf0031631b85d79e1133da662094566bc910432da9bd3a5b42",
        sha512: "",
        sha1: "",
        extract_path: "rust-1.85.0-x86_64-unknown-linux-gnu",
        bin_relpath_override: @["rustc/bin/rustc"]),
      PlatformBinary(cpu: pcX86_64, os: poMacos,
        url: "https://static.rust-lang.org/dist/rust-1.85.0-x86_64-apple-darwin.tar.xz",
        sha256: "c8626ba816961e6913f0db29fdf212706d193afff44ab96fe6afb431627a3434",
        sha512: "",
        sha1: "",
        extract_path: "rust-1.85.0-x86_64-apple-darwin",
        bin_relpath_override: @["rustc/bin/rustc"])
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]
