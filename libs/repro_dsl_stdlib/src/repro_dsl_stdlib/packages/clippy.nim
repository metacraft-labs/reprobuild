## Clippy -- the Rust linter.
##
## The ``package clippy:`` block declares the Nix provisioning and the
## direct-download ``tarball`` realizations; a recipe's ``uses:`` and a
## home profile select among them the same way (GM4b merged the former
## ``clippyCatalog`` copy into the ``tarball`` statements).
##
## On Windows clippy does NOT publish a standalone tarball under
## ``static.rust-lang.org/dist/``. The component lives inside the
## per-channel rust-toolchain archive (``rust-<ver>-<triple>.tar.xz``)
## under ``<extractPath>/clippy-preview/bin/``. The tarball realization
## downloads that full archive and declares the two
## clippy binaries inside it: ``cargo-clippy.exe`` (the cargo
## subcommand front-end) and ``clippy-driver.exe`` (the rustc-shim
## that performs the actual lint pass; cargo-clippy spawns it via
## the prefix's bin/ entry).
##
## The realization intentionally pins Rust 1.94.0 to match the
## recorder dev shells' constraint (``rustc >=1.85``). Bumping the
## pin requires harvesting fresh ``static.rust-lang.org/dist/`` SHAs.
##
## Note that ``cargo clippy`` at runtime also requires ``rustc`` and
## ``cargo`` on PATH; the recorder dev shells declare them via
## separate ``uses:`` entries and each has its own tarball realization.
## Installing clippy alone does not give a working linter.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
export packages_schema

package clippy:
  provisioning:
    nixPackage "nixpkgs#clippy", executablePath = "bin/cargo-clippy",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

    # Direct-download: the SAME rust standalone-distribution tarball
    # ``rustc.nim`` / ``cargo.nim`` / ``rustfmt.nim`` name, because upstream
    # publishes no standalone clippy archive — the component ships inside
    # the per-channel toolchain archive under ``clippy-preview/bin/``.
    #
    # ``executablePath`` is ``bin/cargo-clippy`` rather than the
    # ``clippy-preview/bin/...`` the retired ``clippyCatalog`` record used
    # (GM4b merged it into this statement): that record's realizer extracted
    # the archive and pointed at the component in place, while the realize
    # loop behind ``tarball`` detects the rust-installer layout (the
    # ``rust-installer-version`` + ``components`` sentinel files) and merges
    # every component into one flat prefix, exactly as upstream's
    # ``install.sh`` does. After that merge clippy sits beside rustc and
    # cargo at ``<prefix>/bin/``. See ``mergeRustInstallerComponents`` in
    # ``repro_tool_profiles.nim``.
    #
    # That merge is also what makes the entry WORK rather than merely
    # resolve: ``cargo-clippy`` spawns ``clippy-driver``, which is a rustc
    # shim and needs libstd at the canonical ``<exe>/../lib/rustlib/<triple>``
    # sysroot location. The flat prefix puts it there; an extract-in-place of
    # ``clippy-preview/`` alone would not, which is why the retired catalog
    # record carried explicit ``move-item`` pre-install actions to reproduce it.
    #
    # Naming the same URL + digest as ``rustc.nim`` is deliberate and not a
    # duplicated download: the realize step keys the fetch on the digest, so
    # a project that names rustc, cargo, rustfmt and clippy together pays for
    # one archive.
    tarball url = "https://static.rust-lang.org/dist/rust-1.94.0-x86_64-pc-windows-msvc.tar.xz",
      sha256 = "2e65904a4340df11a1ed8a86a7cc5c08e09f65453ce822ef36159c605a97f6a5",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/cargo-clippy.exe",
      packageId = "rust@1.94.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:rust@1.94.0:sha256:2e65904a4340df11a1ed8a86a7cc5c08e09f65453ce822ef36159c605a97f6a5",
      version = "1.94.0",
      extraExecutable = "bin/clippy-driver.exe"

    tarball url = "https://static.rust-lang.org/dist/rust-1.94.0-x86_64-unknown-linux-gnu.tar.xz",
      sha256 = "e8fa4185f3ef6ae32725ff638b1ecdbff28f5d651dc0b3111e2539350d03b15a",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/cargo-clippy",
      packageId = "rust@1.94.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:rust@1.94.0:linux:sha256:e8fa4185f3ef6ae32725ff638b1ecdbff28f5d651dc0b3111e2539350d03b15a",
      version = "1.94.0",
      extraExecutable = "bin/clippy-driver"

    tarball url = "https://static.rust-lang.org/dist/rust-1.94.0-aarch64-apple-darwin.tar.xz",
      sha256 = "9e55893e014e6aa76924b4cc244a289ad56de4d89d3721fbd5c7f497b31ea33c",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/cargo-clippy",
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
      executablePath = "clippy-preview/bin/cargo-clippy",
      extraExecutable = "clippy-preview/bin/clippy-driver",
      version = "1.94.0",
      packageId = "clippy@1.94.0",
      extractPath = "rust-1.94.0-x86_64-apple-darwin",
      preInstall = preInstallAction("move-item", "$dir/rust-std-x86_64-pc-windows-msvc/lib/rustlib/x86_64-pc-windows-msvc/lib", "$dir/rustc/lib/rustlib/x86_64-pc-windows-msvc/lib", false, ""),
      preInstall = preInstallAction("move-item", "$dir/rust-std-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu/lib", "$dir/rustc/lib/rustlib/x86_64-unknown-linux-gnu/lib", false, ""),
      preInstall = preInstallAction("move-item", "$dir/rust-std-x86_64-apple-darwin/lib/rustlib/x86_64-apple-darwin/lib", "$dir/rustc/lib/rustlib/x86_64-apple-darwin/lib", false, ""),
      cpu = "x86_64",
      os = "macos"
