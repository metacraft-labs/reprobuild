import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package cargo:
  provisioning:
    nixPackage "nixpkgs#cargo", executablePath = "bin/cargo",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Windows / non-Nix Linux: cargo ships as part of the Rust toolchain
    # that Scoop's ``rustup-msvc`` installs via ``rustup-init.exe``.
    # The bytes live at ``<scoop-persist>/rustup-msvc/.cargo/bin/cargo.exe``;
    # scoop's persist mechanism junctions ``.cargo`` into the app dir
    # (``<scoop-app>/<ver>/.cargo`` -> ``<scoop-persist>/.cargo``), and the
    # reprobuild scoop adapter junctions ``<prefix>/bin`` ->
    # ``<scoop-app>/<ver>``, so the binary is reachable at
    # ``<prefix>/bin/.cargo/bin/cargo.exe``. Operators who haven't yet
    # had rustup bootstrap a default toolchain should run
    # ``rustup default stable-msvc`` once after the scoop install so
    # the persist tree actually contains ``cargo.exe``.
    scoopApp(bucket = "main", app = "rustup-msvc",
      preferredVersion = ">=1.20",
      executablePath = ".cargo/bin/cargo.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download: the upstream Rust standalone-distribution tarball
    # ships cargo / rustc / rustfmt / rust-std under a single
    # `rust-X.Y.Z-x86_64-pc-windows-msvc/` top-level dir. cargo.exe
    # lives at `cargo/bin/cargo.exe` inside that tree. With
    # stripComponents=1 the prefix root holds `cargo/bin/cargo.exe`.
    tarball url = "https://static.rust-lang.org/dist/rust-1.92.0-x86_64-pc-windows-msvc.tar.xz",
      sha256 = "7e536d87bb539cdf94a969ecb491e1340f2641a11cf57d6169892f395d68c702",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "cargo/bin/cargo.exe",
      packageId = "rust@1.92.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:rust@1.92.0:sha256:7e536d87bb539cdf94a969ecb491e1340f2641a11cf57d6169892f395d68c702"

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
    version: "1.92.0",
    archive_format: afTarXz,
    install_method: imExtract,
    bin_relpath: @["cargo\\bin\\cargo.exe"],
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
        bin_relpath_override: @["cargo/bin/cargo"]),
      PlatformBinary(cpu: pcX86_64, os: poMacos,
        url: "https://static.rust-lang.org/dist/rust-1.92.0-x86_64-apple-darwin.tar.xz",
        sha256: "ef71fcdcd50efd3301144e701faf15124113a1b2efe9a111175d7d1e4f2d31d2",
        sha512: "",
        sha1: "",
        extract_path: "rust-1.92.0-x86_64-apple-darwin",
        bin_relpath_override: @["cargo/bin/cargo"])
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string](),
    # See ``rustc.nim`` for the rationale: merge ``rust-std-<triple>``
    # into the rustc sysroot so any rustc.exe invoked from this prefix
    # (e.g. via the cargo-prefix bin dir hit by PATH on
    # this realized closure) can find libstd. The action is a no-op
    # when the source does not exist, so we can list all three
    # platform triples; only the matching one fires on each host.
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
