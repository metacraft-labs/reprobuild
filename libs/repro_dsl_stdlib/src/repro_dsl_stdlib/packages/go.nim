import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# Pre-existing Nix-first DSL declaration (CLI surface + Nix provisioning).
# ---------------------------------------------------------------------------

package go:
  provisioning:
    nixPackage "nixpkgs#go", executablePath = "bin/go",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

# ---------------------------------------------------------------------------
# Versioned catalog (M63/M67 shape) consumed by the cakBuiltin adapter on
# non-Nix hosts and by the env.ps1 migration classifier (``GO_VERSION`` in
# ``windows/toolchain-versions.env`` pins the version below). The official
# go.dev archives unpack to a top-level ``go/`` directory; strip it via
# ``extract_path`` so the binary resolves at ``bin/go(.exe)``. Windows ships
# a ``.zip``; Linux/macOS ship ``.tar.gz`` (per-platform override).
# SHA-256s are the upstream values published at https://go.dev/dl/.
# Versions (newest-first): 1.23.4
# ---------------------------------------------------------------------------

let goCatalog* = @[
  VersionedProvisioning(
    version: "1.23.4",
    archive_format: afZip,
    install_method: imExtract,
    bin_relpath: @["bin\\go.exe"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows,
        url: "https://go.dev/dl/go1.23.4.windows-amd64.zip",
        sha256: "16c59ac9196b63afb872ce9b47f945b9821a3e1542ec125f16f6085a1c0f3c39",
        sha512: "", extract_path: "go"),
      PlatformBinary(cpu: pcAArch64, os: poWindows,
        url: "https://go.dev/dl/go1.23.4.windows-arm64.zip",
        sha256: "db69cae5006753c785345c3215ad941f8b6224e2f81fec471c42d6857bee0e6f",
        sha512: "", extract_path: "go"),
      PlatformBinary(cpu: pcX86_64, os: poLinux,
        url: "https://go.dev/dl/go1.23.4.linux-amd64.tar.gz",
        sha256: "6924efde5de86fe277676e929dc9917d466efa02fb934197bc2eba35d5680971",
        sha512: "", sha1: "", extract_path: "go",
        archive_format_override: afTarGz, has_archive_format_override: true,
        bin_relpath_override: @["bin/go"]),
      PlatformBinary(cpu: pcAArch64, os: poLinux,
        url: "https://go.dev/dl/go1.23.4.linux-arm64.tar.gz",
        sha256: "16e5017863a7f6071363782b1b8042eb12c6ca4f4cd71528b2123f0a1275b13e",
        sha512: "", sha1: "", extract_path: "go",
        archive_format_override: afTarGz, has_archive_format_override: true,
        bin_relpath_override: @["bin/go"]),
      PlatformBinary(cpu: pcX86_64, os: poMacos,
        url: "https://go.dev/dl/go1.23.4.darwin-amd64.tar.gz",
        sha256: "6700067389a53a1607d30aa8d6e01d198230397029faa0b109e89bc871ab5a0e",
        sha512: "", sha1: "", extract_path: "go",
        archive_format_override: afTarGz, has_archive_format_override: true,
        bin_relpath_override: @["bin/go"]),
      PlatformBinary(cpu: pcAArch64, os: poMacos,
        url: "https://go.dev/dl/go1.23.4.darwin-arm64.tar.gz",
        sha256: "87d2bb0ad4fe24d2a0685a55df321e0efe4296419a9b3de03369dbe60b8acd3a",
        sha512: "", sha1: "", extract_path: "go",
        archive_format_override: afTarGz, has_archive_format_override: true,
        bin_relpath_override: @["bin/go"])
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]
