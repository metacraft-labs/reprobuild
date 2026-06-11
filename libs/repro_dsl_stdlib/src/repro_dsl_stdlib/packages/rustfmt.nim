## Rustfmt -- the Rust source formatter.
##
## The ``package rustfmt:`` block declares the Nix provisioning
## consumed by the cakNix adapter on Linux/macOS Nix hosts; the
## ``rustfmtCatalog`` slice below is consumed by the M65 cakBuiltin
## adapter on Windows and non-Nix Linux.
##
## Like clippy, the rustfmt component does not publish a standalone
## tarball under ``static.rust-lang.org/dist/``. It ships inside the
## per-channel Rust toolchain archive at
## ``rustfmt-preview/bin/rustfmt(.exe)`` plus the cargo-subcommand
## front ``cargo-fmt(.exe)``.

import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package rustfmt:
  provisioning:
    nixPackage "nixpkgs#rustfmt", executablePath = "bin/rustfmt",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Windows / non-Nix Linux: same shape as cargo / rustc — provisioned
    # through Scoop's `rustup-msvc`, then materialised by rustup-init.exe
    # into `$persist_dir\.cargo\bin\rustfmt.exe`. The declared
    # executablePath references `rustup.exe` at the prefix root because
    # the scoop-app prefix doesn't contain rustfmt.exe directly; cargo's
    # `$persist_dir\.cargo\bin` PATH injection is what makes rustfmt
    # reachable at build time.
    scoopApp(bucket = "main", app = "rustup-msvc",
      preferredVersion = ">=1.20", executablePath = "rustup.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download: same rust standalone-distribution tarball as
    # `cargo.nim`; rustfmt.exe ships under `rustfmt-preview/bin/`.
    tarball url = "https://static.rust-lang.org/dist/rust-1.85.0-x86_64-pc-windows-msvc.tar.xz",
      sha256 = "6f04dd4cc0ce1bb69507fb7b61ce8d502a58d70abc3dfb0b90b8ae12222b8f46",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "rustfmt-preview/bin/rustfmt.exe",
      packageId = "rust@1.85.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:rust@1.85.0:sha256:6f04dd4cc0ce1bb69507fb7b61ce8d502a58d70abc3dfb0b90b8ae12222b8f46"

let rustfmtCatalog* = @[
  VersionedProvisioning(
    version: "1.85.0",
    archive_format: afTarXz,
    install_method: imExtract,
    bin_relpath: @[
      "rustfmt-preview\\bin\\rustfmt.exe",
      "rustfmt-preview\\bin\\cargo-fmt.exe"
    ],
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
        bin_relpath_override: @[
          "rustfmt-preview/bin/rustfmt",
          "rustfmt-preview/bin/cargo-fmt"
        ]),
      PlatformBinary(cpu: pcX86_64, os: poMacos,
        url: "https://static.rust-lang.org/dist/rust-1.85.0-x86_64-apple-darwin.tar.xz",
        sha256: "c8626ba816961e6913f0db29fdf212706d193afff44ab96fe6afb431627a3434",
        sha512: "",
        sha1: "",
        extract_path: "rust-1.85.0-x86_64-apple-darwin",
        bin_relpath_override: @[
          "rustfmt-preview/bin/rustfmt",
          "rustfmt-preview/bin/cargo-fmt"
        ])
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]
