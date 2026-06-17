import repro_project_dsl

package rustup:
  provisioning:
    nixPackage "nixpkgs#rustup", executablePath = "bin/rustup",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Windows / non-Nix Linux: rustup-init shipped via ScoopInstaller/Main's
    # ``rustup-msvc`` package. rustup-init.exe runs once on scoop install
    # and lays down a fully wired rustup tree under
    # ``<scoop-persist>/rustup-msvc/.cargo/`` (plus the .rustup
    # toolchain dir). The reachable ``rustup.exe`` is a shim under that
    # persist tree, surfaced through the persist + scoop-app +
    # reprobuild-prefix junction chain at
    # ``<prefix>/bin/.cargo/bin/rustup.exe``.
    scoopApp(bucket = "main", app = "rustup-msvc",
      preferredVersion = ">=1.20",
      executablePath = ".cargo/bin/rustup.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download fallback: use the same rust standalone tarball so
    # the build-time tool resolution is satisfied. rustup itself is a
    # single `rustup-init.exe` upstream; bundling it through the rust
    # archive simplifies the per-package provisioning shape (one URL
    # serves cargo / rustc / rustfmt / rustup). The tarball does NOT
    # ship rustup.exe, so this entry points at cargo.exe — operators
    # who actually need rustup should install it separately via the
    # scoopApp path. The realize loop's rust-installer auto-merge
    # collapses every component into a flat prefix (see
    # ``mergeRustInstallerComponents``), so cargo.exe lands at
    # `<prefix>/bin/cargo.exe`.
    tarball url = "https://static.rust-lang.org/dist/rust-1.92.0-x86_64-pc-windows-msvc.tar.xz",
      sha256 = "7e536d87bb539cdf94a969ecb491e1340f2641a11cf57d6169892f395d68c702",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/cargo.exe",
      packageId = "rust@1.92.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:rust@1.92.0:sha256:7e536d87bb539cdf94a969ecb491e1340f2641a11cf57d6169892f395d68c702"
