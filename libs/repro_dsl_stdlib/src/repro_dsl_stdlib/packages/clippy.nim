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
## The catalog intentionally pins Rust 1.94.0 to match the
## recorder dev shells' constraint (``rustc >=1.85``). Bumping the
## pin requires harvesting fresh ``static.rust-lang.org/dist/`` SHAs.
##
## Note that ``cargo clippy`` at runtime also requires ``rustc`` and
## ``cargo`` on PATH; the recorder dev shells declare them via
## separate ``uses:`` entries and each has its own catalog block.
## Installing clippy alone does not give a working linter.

import std/tables
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
    # ``clippy-preview/bin/...`` the ``clippyCatalog`` slice below uses,
    # because the two adapters see different trees. The cakBuiltin adapter
    # extracts the archive and points at the component in place; the realize
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
    # ``clippy-preview/`` alone would not, which is why the catalog slice
    # below carries explicit ``piaMoveItem`` actions to reproduce it.
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
      lockIdentity = "tarball:rust@1.94.0:sha256:2e65904a4340df11a1ed8a86a7cc5c08e09f65453ce822ef36159c605a97f6a5"

    tarball url = "https://static.rust-lang.org/dist/rust-1.94.0-x86_64-unknown-linux-gnu.tar.xz",
      sha256 = "e8fa4185f3ef6ae32725ff638b1ecdbff28f5d651dc0b3111e2539350d03b15a",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/cargo-clippy",
      packageId = "rust@1.94.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:rust@1.94.0:linux:sha256:e8fa4185f3ef6ae32725ff638b1ecdbff28f5d651dc0b3111e2539350d03b15a"

    tarball url = "https://static.rust-lang.org/dist/rust-1.94.0-aarch64-apple-darwin.tar.xz",
      sha256 = "9e55893e014e6aa76924b4cc244a289ad56de4d89d3721fbd5c7f497b31ea33c",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/cargo-clippy",
      packageId = "rust@1.94.0",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:rust@1.94.0:macos-aarch64:sha256:9e55893e014e6aa76924b4cc244a289ad56de4d89d3721fbd5c7f497b31ea33c"

let clippyCatalog* = @[
  VersionedProvisioning(
    version: "1.94.0",
    archive_format: afTarXz,
    install_method: imExtract,
    bin_relpath: @[
      "clippy-preview\\bin\\cargo-clippy.exe",
      "clippy-preview\\bin\\clippy-driver.exe"
    ],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows,
        url: "https://static.rust-lang.org/dist/rust-1.94.0-x86_64-pc-windows-msvc.tar.xz",
        sha256: "2e65904a4340df11a1ed8a86a7cc5c08e09f65453ce822ef36159c605a97f6a5",
        sha512: "",
        extract_path: "rust-1.94.0-x86_64-pc-windows-msvc"),
      PlatformBinary(cpu: pcX86_64, os: poLinux,
        url: "https://static.rust-lang.org/dist/rust-1.94.0-x86_64-unknown-linux-gnu.tar.xz",
        sha256: "e8fa4185f3ef6ae32725ff638b1ecdbff28f5d651dc0b3111e2539350d03b15a",
        sha512: "",
        sha1: "",
        extract_path: "rust-1.94.0-x86_64-unknown-linux-gnu",
        bin_relpath_override: @[
          "clippy-preview/bin/cargo-clippy",
          "clippy-preview/bin/clippy-driver"
        ]),
      PlatformBinary(cpu: pcX86_64, os: poMacos,
        url: "https://static.rust-lang.org/dist/rust-1.94.0-x86_64-apple-darwin.tar.xz",
        sha256: "63fe27931d4b8da0b0069f13d4d2c04792203a5cabb4df17ff15495aaaab0ef7",
        sha512: "",
        sha1: "",
        extract_path: "rust-1.94.0-x86_64-apple-darwin",
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
