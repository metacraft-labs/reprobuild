## Clippy -- the Rust linter.
##
## The ``package clippy:`` block declares the Nix provisioning
## consumed by the cakNix adapter on Linux/macOS Nix hosts; the
## ``clippyCatalog`` slice below is consumed by the M65 cakBuiltin
## adapter on Windows and non-Nix Linux.
##
## On Windows clippy does NOT publish a standalone tarball under
## ``static.rust-lang.org/dist/``. The component lives inside the
## per-channel rust-toolchain archive (``rust-<ver>-<triple>.tar.xz``)
## under ``<extract_path>/clippy-preview/bin/``. This catalog entry
## downloads that full archive and points ``bin_relpath`` at the two
## clippy binaries inside it: ``cargo-clippy.exe`` (the cargo
## subcommand front-end) and ``clippy-driver.exe`` (the rustc-shim
## that performs the actual lint pass; cargo-clippy spawns it via
## the prefix's bin/ entry).
##
## The catalog intentionally pins Rust 1.92.0 to match the
## recorder dev shells' constraint (``rustc >=1.85``). Bumping the
## pin requires harvesting fresh ``static.rust-lang.org/dist/`` SHAs.
##
## Note that ``cargo clippy`` at runtime also requires ``rustc`` and
## ``cargo`` on PATH; the recorder dev shells declare them via
## separate ``uses:`` entries and each has its own catalog block.
## Installing clippy alone does not give a working linter.

import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package clippy:
  provisioning:
    nixPackage "nixpkgs#clippy", executablePath = "bin/cargo-clippy",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

let clippyCatalog* = @[
  VersionedProvisioning(
    version: "1.92.0",
    archive_format: afTarXz,
    install_method: imExtract,
    bin_relpath: @[
      "clippy-preview\\bin\\cargo-clippy.exe",
      "clippy-preview\\bin\\clippy-driver.exe"
    ],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows,
        url: "https://static.rust-lang.org/dist/rust-1.92.0-x86_64-pc-windows-msvc.tar.xz",
        sha256: "7e536d87bb539cdf94a969ecb491e1340f2641a11cf57d6169892f395d68c702",
        sha512: "",
        extract_path: "rust-1.92.0-x86_64-pc-windows-msvc"),
      PlatformBinary(cpu: pcX86_64, os: poLinux,
        url: "https://static.rust-lang.org/dist/rust-1.92.0-x86_64-unknown-linux-gnu.tar.xz",
        sha256: "d2ccef59dd9f7439f2c694948069f789a044dc1addcc0803613232af8f88ee0c",
        sha512: "",
        sha1: "",
        extract_path: "rust-1.92.0-x86_64-unknown-linux-gnu",
        bin_relpath_override: @[
          "clippy-preview/bin/cargo-clippy",
          "clippy-preview/bin/clippy-driver"
        ]),
      PlatformBinary(cpu: pcX86_64, os: poMacos,
        url: "https://static.rust-lang.org/dist/rust-1.92.0-x86_64-apple-darwin.tar.xz",
        sha256: "ef71fcdcd50efd3301144e701faf15124113a1b2efe9a111175d7d1e4f2d31d2",
        sha512: "",
        sha1: "",
        extract_path: "rust-1.92.0-x86_64-apple-darwin",
        bin_relpath_override: @[
          "clippy-preview/bin/cargo-clippy",
          "clippy-preview/bin/clippy-driver"
        ])
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string](),
    # See ``rustc.nim`` for the rationale: clippy-driver.exe is itself
    # a rustc-shim that needs the standard library in the canonical
    # sysroot layout. piaMoveItem is a silent no-op when the source
    # does not exist, so all three triples can be listed.
    pre_install_actions: @[
      PreInstallAction(kind: piaMoveItem,
        source: "$dir/rust-std-x86_64-pc-windows-msvc/lib/rustlib/x86_64-pc-windows-msvc/lib",
        target: "$dir/rustc/lib/rustlib/x86_64-pc-windows-msvc/lib",
        recurse: false, literal: ""),
      PreInstallAction(kind: piaMoveItem,
        source: "$dir/rust-std-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu/lib",
        target: "$dir/rustc/lib/rustlib/x86_64-unknown-linux-gnu/lib",
        recurse: false, literal: ""),
      PreInstallAction(kind: piaMoveItem,
        source: "$dir/rust-std-x86_64-apple-darwin/lib/rustlib/x86_64-apple-darwin/lib",
        target: "$dir/rustc/lib/rustlib/x86_64-apple-darwin/lib",
        recurse: false, literal: "")
    ])
]
