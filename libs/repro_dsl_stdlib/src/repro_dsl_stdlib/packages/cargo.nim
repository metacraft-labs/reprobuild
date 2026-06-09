import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package cargo:
  provisioning:
    nixPackage "nixpkgs#cargo", executablePath = "bin/cargo",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

  executable cargo:
    cli:
      dependencyPolicy automaticMonitor,
        ignoredInputPrefixes = @[
          "$CARGO_HOME/.global-cache",
          "$CARGO_HOME/.package-cache",
          "$HOME/.cargo/.global-cache",
          "$HOME/.cargo/.package-cache"
        ]

      subcmd "build":
        boolFlag locked is bool, alias = "--locked"
        boolFlag release is bool, alias = "--release"
        flag manifestPath is string,
          alias = "--manifest-path",
          role = input
        flag targetDir is string,
          alias = "--target-dir"

# M65 cakBuiltin catalog -- consumed on Windows and non-Nix Linux.
# Same per-channel Rust toolchain archive as `rustc.nim` and
# `rustfmt.nim` / `clippy.nim`; bin_relpath points at the `cargo/`
# subdirectory inside the extracted archive.

let cargoCatalog* = @[
  VersionedProvisioning(
    version: "1.85.0",
    archive_format: afTarXz,
    install_method: imExtract,
    bin_relpath: @["cargo\\bin\\cargo.exe"],
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
        bin_relpath_override: @["cargo/bin/cargo"]),
      PlatformBinary(cpu: pcX86_64, os: poMacos,
        url: "https://static.rust-lang.org/dist/rust-1.85.0-x86_64-apple-darwin.tar.xz",
        sha256: "c8626ba816961e6913f0db29fdf212706d193afff44ab96fe6afb431627a3434",
        sha512: "",
        sha1: "",
        extract_path: "rust-1.85.0-x86_64-apple-darwin",
        bin_relpath_override: @["cargo/bin/cargo"])
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]
