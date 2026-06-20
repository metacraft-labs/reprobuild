## M68 merge note (hand-edited): the auto-generated ``justCatalog`` body
## sits below the pre-existing ``package just:`` Nix block. The Nix
## block remains the source of truth for Nix-capable hosts; the
## ``justCatalog`` slice below is consumed by the M64 ``cakBuiltin``
## adapter on Windows. Re-harvest emits ONLY the catalog half;
## re-attach the Nix block by hand if you regenerate.
##
## **M9.5 merge note (hand-edited):** added a ``(pcX86_64, poLinux)``
## platform slice harvested via ``--source gh-releases:casey/just
## --asset-pattern 'just-1\.51\.0-x86_64-unknown-linux-musl\.tar\.gz'
## --platform-os linux``. The Linux tarball is ``afTarGz`` + a flat
## ``just`` binary (vs. the Windows ``afZip`` + ``just.exe``); both
## encoded via the M9.5 per-platform overrides. The musl variant ships
## a statically-linked binary so glibc-floor is not a concern.

import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# Pre-existing M21 Nix provisioning (preserved across the M68 harvest).
# ---------------------------------------------------------------------------

package just:
  provisioning:
    nixPackage "nixpkgs#just", executablePath = "bin/just",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Windows / non-Nix Linux: just via ScoopInstaller/Main. Single
    # static binary at the prefix root.
    scoopApp(bucket = "main", app = "just",
      preferredVersion = ">=1", executablePath = "just.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download: just from GitHub Releases. Archive ships
    # `just.exe` flat at the root (no enclosing directory), so
    # stripComponents defaults to 0.
    tarball url = "https://github.com/casey/just/releases/download/1.51.0/just-1.51.0-x86_64-pc-windows-msvc.zip",
      sha256 = "09d1138b6845e73f04bff5e26be3f57663bddca25e36fe6241d28a5aa310b64e",
      archiveType = "zip",
      executablePath = "just.exe",
      packageId = "just@1.51.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:just@1.51.0:sha256:09d1138b6845e73f04bff5e26be3f57663bddca25e36fe6241d28a5aa310b64e"
    # Linux x86_64: musl static binary from GitHub Releases. Archive
    # ships `just` flat at the root (no enclosing directory). Same
    # source as the `justCatalog` Linux platform slice below.
    tarball url = "https://github.com/casey/just/releases/download/1.51.0/just-1.51.0-x86_64-unknown-linux-musl.tar.gz",
      sha256 = "c8f085ca3e885723c341d06243fc291b5abfdc8bbe3b2c076b117de490387b59",
      archiveType = "tar.gz",
      executablePath = "just",
      packageId = "just@1.51.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:just@1.51.0:linux:sha256:c8f085ca3e885723c341d06243fc291b5abfdc8bbe3b2c076b117de490387b59"
    # macOS aarch64: native Apple Silicon binary from GitHub Releases.
    # Same flat archive shape as the Linux/Windows entries (the `just`
    # binary sits at the archive root, no enclosing directory).
    tarball url = "https://github.com/casey/just/releases/download/1.51.0/just-1.51.0-aarch64-apple-darwin.tar.gz",
      sha256 = "61e3f1b8a545ff064b091eab4b6e14f8cc743ff15549be293b1e92f5b1467002",
      archiveType = "tar.gz",
      executablePath = "just",
      packageId = "just@1.51.0",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:just@1.51.0:macos-aarch64:sha256:61e3f1b8a545ff064b091eab4b6e14f8cc743ff15549be293b1e92f5b1467002"

# ---------------------------------------------------------------------------
# M68 bulk-harvest catalog (cakBuiltin adapter consumer on Windows).
# Harvested from bucket: ScoopInstaller/Main
# Versions (newest-first): 1.51.0
# ---------------------------------------------------------------------------

let justCatalog* = @[
  VersionedProvisioning(
    version: "1.51.0",
    archive_format: afZip,
    install_method: imExtract,
    bin_relpath: @["just.exe"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows, url: "https://github.com/casey/just/releases/download/1.51.0/just-1.51.0-x86_64-pc-windows-msvc.zip", sha256: "09d1138b6845e73f04bff5e26be3f57663bddca25e36fe6241d28a5aa310b64e", sha512: "", extract_path: ""),
      # M9.5: Linux x86_64 slice. afTarGz (vs. Windows afZip) + flat
      # ``just`` binary (vs. Windows ``just.exe``).
      PlatformBinary(cpu: pcX86_64, os: poLinux, url: "https://github.com/casey/just/releases/download/1.51.0/just-1.51.0-x86_64-unknown-linux-musl.tar.gz", sha256: "c8f085ca3e885723c341d06243fc291b5abfdc8bbe3b2c076b117de490387b59", sha512: "", sha1: "", extract_path: "", archive_format_override: afTarGz, has_archive_format_override: true, bin_relpath_override: @["just"])
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]
