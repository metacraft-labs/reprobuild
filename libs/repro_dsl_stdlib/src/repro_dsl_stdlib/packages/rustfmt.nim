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
    # Windows / non-Nix Linux: same shape as cargo / rustc. rustfmt.exe
    # is a rustup shim reachable through the persist + scoop-app +
    # reprobuild-prefix junction chain at
    # ``<prefix>/bin/.cargo/bin/rustfmt.exe``.
    scoopApp(bucket = "main", app = "rustup-msvc",
      preferredVersion = ">=1.20",
      executablePath = ".cargo/bin/rustfmt.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download: same rust standalone-distribution tarball as
    # `cargo.nim`. The realize loop merges every rust-installer
    # component (cargo, rustc, rust-std, rustfmt-preview, ...) into a
    # flat prefix matching what upstream's `install.sh` produces, so
    # `rustfmt.exe` lands at `<prefix>/bin/rustfmt.exe` and the
    # cargo-fmt subcommand front at `<prefix>/bin/cargo-fmt.exe`. See
    # ``mergeRustInstallerComponents`` in
    # ``repro_tool_profiles.nim``.
    tarball url = "https://static.rust-lang.org/dist/rust-1.92.0-x86_64-pc-windows-msvc.tar.xz",
      sha256 = "7e536d87bb539cdf94a969ecb491e1340f2641a11cf57d6169892f395d68c702",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/rustfmt.exe",
      packageId = "rust@1.92.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:rust@1.92.0:sha256:7e536d87bb539cdf94a969ecb491e1340f2641a11cf57d6169892f395d68c702"
    # Linux x86_64: same rust standalone-distribution tarball as the
    # Windows entry — different triple. The realize loop's rust-installer
    # auto-merge flattens rustfmt-preview / cargo / rustc into a single
    # prefix, so `rustfmt` lands at `<prefix>/bin/rustfmt` alongside
    # `cargo-fmt`.
    tarball url = "https://static.rust-lang.org/dist/rust-1.92.0-x86_64-unknown-linux-gnu.tar.xz",
      sha256 = "d2ccef59dd9f7439f2c694948069f789a044dc1addcc0803613232af8f88ee0c",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/rustfmt",
      packageId = "rust@1.92.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:rust@1.92.0:linux:sha256:d2ccef59dd9f7439f2c694948069f789a044dc1addcc0803613232af8f88ee0c"

let rustfmtCatalog* = @[
  VersionedProvisioning(
    version: "1.92.0",
    archive_format: afTarXz,
    install_method: imExtract,
    bin_relpath: @[
      "rustfmt-preview\\bin\\rustfmt.exe",
      "rustfmt-preview\\bin\\cargo-fmt.exe"
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
          "rustfmt-preview/bin/rustfmt",
          "rustfmt-preview/bin/cargo-fmt"
        ]),
      PlatformBinary(cpu: pcX86_64, os: poMacos,
        url: "https://static.rust-lang.org/dist/rust-1.92.0-x86_64-apple-darwin.tar.xz",
        sha256: "ef71fcdcd50efd3301144e701faf15124113a1b2efe9a111175d7d1e4f2d31d2",
        sha512: "",
        sha1: "",
        extract_path: "rust-1.92.0-x86_64-apple-darwin",
        bin_relpath_override: @[
          "rustfmt-preview/bin/rustfmt",
          "rustfmt-preview/bin/cargo-fmt"
        ])
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string](),
    # See ``rustc.nim`` for the rationale: merge the rust-std component
    # into rustc's sysroot so any rustc.exe co-resident in this prefix
    # can find libstd. piaMoveItem is a silent no-op when the source
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
