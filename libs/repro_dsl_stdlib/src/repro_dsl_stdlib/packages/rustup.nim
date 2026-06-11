import repro_project_dsl

package rustup:
  provisioning:
    nixPackage "nixpkgs#rustup", executablePath = "bin/rustup",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Windows / non-Nix Linux: rustup-init shipped via ScoopInstaller/Main's
    # `rustup-msvc` package. After install, rustup.exe lives at the prefix
    # root; the cargo/rustc/rustfmt binaries it manages are persisted to
    # `$persist_dir\.cargo\bin\` and exposed via the manifest's
    # `env_add_path: ".cargo\bin"`.
    scoopApp(bucket = "main", app = "rustup-msvc",
      preferredVersion = ">=1.20", executablePath = "rustup.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download fallback: use the same rust standalone tarball so
    # the build-time tool resolution is satisfied. rustup itself is a
    # single `rustup-init.exe` upstream; bundling it through the rust
    # archive simplifies the per-package provisioning shape (one URL
    # serves cargo / rustc / rustfmt / rustup). The tarball does NOT
    # ship rustup.exe, so this entry points at cargo.exe — operators
    # who actually need rustup should install it separately via the
    # scoopApp path.
    tarball url = "https://static.rust-lang.org/dist/rust-1.85.0-x86_64-pc-windows-msvc.tar.xz",
      sha256 = "6f04dd4cc0ce1bb69507fb7b61ce8d502a58d70abc3dfb0b90b8ae12222b8f46",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "cargo/bin/cargo.exe",
      packageId = "rust@1.85.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:rust@1.85.0:sha256:6f04dd4cc0ce1bb69507fb7b61ce8d502a58d70abc3dfb0b90b8ae12222b8f46"
