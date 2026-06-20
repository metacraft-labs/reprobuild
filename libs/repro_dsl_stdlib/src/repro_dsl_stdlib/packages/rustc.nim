## Rustc -- the Rust compiler driver.
##
## The ``package rustc:`` block declares the Nix provisioning
## consumed by the cakNix adapter on Linux/macOS Nix hosts; the
## ``rustcCatalog`` slice below is consumed by the M65 cakBuiltin
## adapter on Windows and non-Nix Linux. The catalog downloads the
## per-channel Rust toolchain archive
## (``rust-<ver>-<triple>.tar.xz``) and surfaces ``rustc`` plus its
## supporting binaries on the realized prefix's PATH.
##
## A correctly working rustc install needs the matching
## ``rust-std-<triple>`` component the archive bundles alongside
## ``rustc/`` (the standard library), so the realize loop extracts
## the archive whole and the bin_relpath just exposes the front
## binaries; the std-lib lives at
## ``rust-std-<triple>/lib/rustlib/<triple>/lib`` inside the same
## prefix and is found via the rustc binary's known-relative search
## path.
##
## The catalog pins Rust 1.92.0 to match the recorder dev shells'
## ``rustc >=1.85`` constraint. ``cargo`` / ``rustfmt`` / ``clippy``
## have their own catalog entries that download the same archive and
## point at their respective ``<component>/bin/`` paths.

import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package rustc:
  provisioning:
    nixPackage "nixpkgs#rustc", executablePath = "bin/rustc",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Windows / non-Nix Linux: same shape as ``cargo.nim``. rustc.exe is
    # a rustup shim at
    # ``<scoop-persist>/rustup-msvc/.cargo/bin/rustc.exe``; reachable
    # through the persist + scoop-app + reprobuild-prefix junction chain
    # at ``<prefix>/bin/.cargo/bin/rustc.exe``.
    scoopApp(bucket = "main", app = "rustup-msvc",
      preferredVersion = ">=1.20",
      executablePath = ".cargo/bin/rustc.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download: same rust standalone-distribution tarball as
    # `cargo.nim`. The tarball ships rustc under `rustc/bin/` and the
    # rust-std component under `rust-std-<triple>/`; the realize loop
    # detects the rust-installer layout (via the
    # `rust-installer-version` + `components` sentinel files) and
    # merges every component into a single flat prefix — the same
    # operation upstream's `install.sh` performs — so rustc lands at
    # `<prefix>/bin/rustc.exe` with libstd at
    # `<prefix>/lib/rustlib/<triple>/lib/` (the exact layout rustc
    # expects via `<exe>/../lib/rustlib/...`). See
    # ``mergeRustInstallerComponents`` in
    # ``repro_tool_profiles.nim``.
    tarball url = "https://static.rust-lang.org/dist/rust-1.92.0-x86_64-pc-windows-msvc.tar.xz",
      sha256 = "7e536d87bb539cdf94a969ecb491e1340f2641a11cf57d6169892f395d68c702",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/rustc.exe",
      packageId = "rust@1.92.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:rust@1.92.0:sha256:7e536d87bb539cdf94a969ecb491e1340f2641a11cf57d6169892f395d68c702"
    # Linux x86_64: same rust standalone-distribution tarball as the
    # Windows entry — different triple. The realize loop's rust-installer
    # auto-merge flattens rustc / cargo / rust-std into a single prefix
    # so `rustc` lands at `<prefix>/bin/rustc` and libstd at the
    # canonical `<prefix>/lib/rustlib/<triple>/lib/` sysroot location.
    tarball url = "https://static.rust-lang.org/dist/rust-1.92.0-x86_64-unknown-linux-gnu.tar.xz",
      sha256 = "d2ccef59dd9f7439f2c694948069f789a044dc1addcc0803613232af8f88ee0c",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/rustc",
      packageId = "rust@1.92.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:rust@1.92.0:linux:sha256:d2ccef59dd9f7439f2c694948069f789a044dc1addcc0803613232af8f88ee0c"
    # macOS aarch64: same rust standalone-distribution tarball — different
    # triple (Apple Silicon). All current GitHub-hosted macOS runners are
    # M1/M2/M3, so aarch64 is the only macOS slice we ship. The
    # rust-installer auto-merge places `rustc` at `<prefix>/bin/rustc`
    # with libstd at `<prefix>/lib/rustlib/aarch64-apple-darwin/lib/`.
    tarball url = "https://static.rust-lang.org/dist/rust-1.92.0-aarch64-apple-darwin.tar.xz",
      sha256 = "22276ecf826b22e718f099d7bf7ddb8c88aa46230fdba74962ab3c5031472268",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/rustc",
      packageId = "rust@1.92.0",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:rust@1.92.0:macos-aarch64:sha256:22276ecf826b22e718f099d7bf7ddb8c88aa46230fdba74962ab3c5031472268"

let rustcCatalog* = @[
  VersionedProvisioning(
    version: "1.92.0",
    archive_format: afTarXz,
    install_method: imExtract,
    bin_relpath: @["rustc\\bin\\rustc.exe"],
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
        bin_relpath_override: @["rustc/bin/rustc"]),
      PlatformBinary(cpu: pcX86_64, os: poMacos,
        url: "https://static.rust-lang.org/dist/rust-1.92.0-x86_64-apple-darwin.tar.xz",
        sha256: "ef71fcdcd50efd3301144e701faf15124113a1b2efe9a111175d7d1e4f2d31d2",
        sha512: "",
        sha1: "",
        extract_path: "rust-1.92.0-x86_64-apple-darwin",
        bin_relpath_override: @["rustc/bin/rustc"])
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string](),
    # Rust's standalone distribution ships ``rustc/`` and
    # ``rust-std-<triple>/`` as sibling top-level dirs inside the
    # tarball; rustc finds its sysroot at
    # ``<rustc-bin>/../lib/rustlib/<triple>/lib`` and so cannot see
    # the libstd rlibs in the unmerged layout. Upstream's ``install.sh``
    # merges the components into a single sysroot tree — we do the
    # equivalent here via piaMoveItem (M3 closed-set allowlist) so the
    # post-extract layout has libstd in the canonical sysroot location.
    # ``piaMoveItem`` is a no-op when the source does not exist, so we
    # can list all three platform triples; only the matching one fires
    # on each host.
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
