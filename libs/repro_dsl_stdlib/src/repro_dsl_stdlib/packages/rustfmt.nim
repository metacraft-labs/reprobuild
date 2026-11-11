## Rustfmt -- the Rust source formatter.
##
## The ``package rustfmt:`` block declares the Nix provisioning and the
## direct-download ``tarball`` realizations; a recipe's ``uses:`` and a
## home profile select among them the same way (GM4b merged the former
## ``rustfmtCatalog`` copy into the ``tarball`` statements).
##
## Like clippy, the rustfmt component does not publish a standalone
## tarball under ``static.rust-lang.org/dist/``. It ships inside the
## per-channel Rust toolchain archive at
## ``rustfmt-preview/bin/rustfmt(.exe)`` plus the cargo-subcommand
## front ``cargo-fmt(.exe)``.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
export packages_schema

package rustfmt:
  provisioning:
    nixPackage "nixpkgs#rustfmt", executablePath = "bin/rustfmt",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
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
    tarball url = "https://static.rust-lang.org/dist/rust-1.94.0-x86_64-pc-windows-msvc.tar.xz",
      sha256 = "2e65904a4340df11a1ed8a86a7cc5c08e09f65453ce822ef36159c605a97f6a5",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/rustfmt.exe",
      packageId = "rust@1.94.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:rust@1.94.0:sha256:2e65904a4340df11a1ed8a86a7cc5c08e09f65453ce822ef36159c605a97f6a5",
      version = "1.94.0",
      extraExecutable = "bin/cargo-fmt.exe"
    # Linux x86_64: same rust standalone-distribution tarball as the
    # Windows entry — different triple. The realize loop's rust-installer
    # auto-merge flattens rustfmt-preview / cargo / rustc into a single
    # prefix, so `rustfmt` lands at `<prefix>/bin/rustfmt` alongside
    # `cargo-fmt`.
    tarball url = "https://static.rust-lang.org/dist/rust-1.94.0-x86_64-unknown-linux-gnu.tar.xz",
      sha256 = "e8fa4185f3ef6ae32725ff638b1ecdbff28f5d651dc0b3111e2539350d03b15a",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/rustfmt",
      packageId = "rust@1.94.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:rust@1.94.0:linux:sha256:e8fa4185f3ef6ae32725ff638b1ecdbff28f5d651dc0b3111e2539350d03b15a",
      version = "1.94.0",
      extraExecutable = "bin/cargo-fmt"
    # macOS aarch64: same rust standalone-distribution tarball — different
    # triple (Apple Silicon). All current GitHub-hosted macOS runners are
    # M1/M2/M3, so aarch64 is the only macOS entry we ship. The
    # rust-installer auto-merge places `rustfmt` at `<prefix>/bin/rustfmt`
    # alongside `cargo-fmt`.
    tarball url = "https://static.rust-lang.org/dist/rust-1.94.0-aarch64-apple-darwin.tar.xz",
      sha256 = "9e55893e014e6aa76924b4cc244a289ad56de4d89d3721fbd5c7f497b31ea33c",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/rustfmt",
      packageId = "rust@1.94.0",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:rust@1.94.0:macos-aarch64:sha256:9e55893e014e6aa76924b4cc244a289ad56de4d89d3721fbd5c7f497b31ea33c",
      version = "1.94.0"
    # GM4b: archive realizations formerly held by the retired
    # `VersionedProvisioning` catalog record (see the conflict notes
    # in the Gradual-Nix-To-Reprobuild-Migration GM4b milestone).
    tarball url = "https://static.rust-lang.org/dist/rust-1.94.0-x86_64-apple-darwin.tar.xz",
      sha256 = "63fe27931d4b8da0b0069f13d4d2c04792203a5cabb4df17ff15495aaaab0ef7",
      archiveType = "tar.xz",
      executablePath = "rustfmt-preview/bin/rustfmt",
      extraExecutable = "rustfmt-preview/bin/cargo-fmt",
      version = "1.94.0",
      packageId = "rustfmt@1.94.0",
      extractPath = "rust-1.94.0-x86_64-apple-darwin",
      preInstall = preInstallAction("move-item", "$dir/rust-std-x86_64-pc-windows-msvc/lib/rustlib/x86_64-pc-windows-msvc/lib", "$dir/rustc/lib/rustlib/x86_64-pc-windows-msvc/lib", false, ""),
      preInstall = preInstallAction("move-item", "$dir/rust-std-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu/lib", "$dir/rustc/lib/rustlib/x86_64-unknown-linux-gnu/lib", false, ""),
      preInstall = preInstallAction("move-item", "$dir/rust-std-x86_64-apple-darwin/lib/rustlib/x86_64-apple-darwin/lib", "$dir/rustc/lib/rustlib/x86_64-apple-darwin/lib", false, ""),
      cpu = "x86_64",
      os = "macos"
    # Rust 1.97.1: the same four archives of a newer release, for a recipe
    # whose ``uses:`` range excludes 1.94 (a crate that needs a newer stable
    # compiler). Declared after the 1.94.0 arms, so an unranged or wide
    # ``uses:`` keeps taking 1.94.0 (selection takes the first eligible arm
    # in declaration order). Digests: upstream's ``<archive>.sha256``, read
    # 2026-11-11, equal to channel-rust-1.97.toml's ``xz_hash`` rows.
    tarball url = "https://static.rust-lang.org/dist/rust-1.97.1-x86_64-pc-windows-msvc.tar.xz",
      sha256 = "a1cdfcfd1e351ba21823d6bd454a297fa95190abca2f432a372e3c47bef8b863",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/rustfmt.exe",
      packageId = "rust@1.97.1",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:rust@1.97.1:sha256:a1cdfcfd1e351ba21823d6bd454a297fa95190abca2f432a372e3c47bef8b863",
      version = "1.97.1",
      extraExecutable = "bin/cargo-fmt.exe"
    tarball url = "https://static.rust-lang.org/dist/rust-1.97.1-x86_64-unknown-linux-gnu.tar.xz",
      sha256 = "88f28fa9af20594179f85d6df67078dfd6fa93e2f6da5e1e9b0ac4997988ca4f",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/rustfmt",
      packageId = "rust@1.97.1",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:rust@1.97.1:linux:sha256:88f28fa9af20594179f85d6df67078dfd6fa93e2f6da5e1e9b0ac4997988ca4f",
      version = "1.97.1",
      extraExecutable = "bin/cargo-fmt"
    tarball url = "https://static.rust-lang.org/dist/rust-1.97.1-aarch64-apple-darwin.tar.xz",
      sha256 = "c9748cc86107734a2a024069908a895de7caa2d37062fb641eef9f756938ace2",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/rustfmt",
      packageId = "rust@1.97.1",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:rust@1.97.1:macos-aarch64:sha256:c9748cc86107734a2a024069908a895de7caa2d37062fb641eef9f756938ace2",
      version = "1.97.1"
    tarball url = "https://static.rust-lang.org/dist/rust-1.97.1-x86_64-apple-darwin.tar.xz",
      sha256 = "891c32ea77b750dccc7fb0ea98e3feb9db3d29fe0cfea5907d002f270c59cf58",
      archiveType = "tar.xz",
      executablePath = "rustfmt-preview/bin/rustfmt",
      extraExecutable = "rustfmt-preview/bin/cargo-fmt",
      version = "1.97.1",
      packageId = "rustfmt@1.97.1",
      extractPath = "rust-1.97.1-x86_64-apple-darwin",
      preInstall = preInstallAction("move-item", "$dir/rust-std-x86_64-pc-windows-msvc/lib/rustlib/x86_64-pc-windows-msvc/lib", "$dir/rustc/lib/rustlib/x86_64-pc-windows-msvc/lib", false, ""),
      preInstall = preInstallAction("move-item", "$dir/rust-std-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu/lib", "$dir/rustc/lib/rustlib/x86_64-unknown-linux-gnu/lib", false, ""),
      preInstall = preInstallAction("move-item", "$dir/rust-std-x86_64-apple-darwin/lib/rustlib/x86_64-apple-darwin/lib", "$dir/rustc/lib/rustlib/x86_64-apple-darwin/lib", false, ""),
      cpu = "x86_64",
      os = "macos"
