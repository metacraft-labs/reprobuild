import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# Pre-existing Nix-first DSL declaration (CLI surface + Nix provisioning).
# ---------------------------------------------------------------------------

package go:
  provisioning:
    nixPackage "nixpkgs#go", executablePath = "bin/go",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: go.dev's own release zip. It carries a `go/` wrapper holding
    # bin, pkg and src; the toolchain locates GOROOT relative to the
    # executable, so stripComponents=1 flattens the wrapper and keeps that
    # tree together. Digest is Agent Harbor's `GO_SHA256_WINDOWS_AMD64`.
    tarball url = "https://go.dev/dl/go1.25.11.windows-amd64.zip",
      sha256 = "b7401f1b41517428e537493316256fb7cf03c66a130a0103ab07f3a2152e2112",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "bin/go.exe",
      packageId = "go@1.25.11",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:go@1.25.11:windows-x86_64:sha256:b7401f1b41517428e537493316256fb7cf03c66a130a0103ab07f3a2152e2112",
      version = "1.25.11"
    # GM4b: archive realizations formerly held by the retired
    # `VersionedProvisioning` catalog record (see the conflict notes
    # in the Gradual-Nix-To-Reprobuild-Migration GM4b milestone).
    tarball url = "https://go.dev/dl/go1.23.4.windows-amd64.zip",
      sha256 = "16c59ac9196b63afb872ce9b47f945b9821a3e1542ec125f16f6085a1c0f3c39",
      archiveType = "zip",
      executablePath = "bin\\go.exe",
      version = "1.23.4",
      packageId = "go@1.23.4",
      extractPath = "go",
      cpu = "x86_64",
      os = "windows"
    tarball url = "https://go.dev/dl/go1.23.4.windows-arm64.zip",
      sha256 = "db69cae5006753c785345c3215ad941f8b6224e2f81fec471c42d6857bee0e6f",
      archiveType = "zip",
      executablePath = "bin\\go.exe",
      version = "1.23.4",
      packageId = "go@1.23.4",
      extractPath = "go",
      cpu = "aarch64",
      os = "windows"
    tarball url = "https://go.dev/dl/go1.23.4.linux-amd64.tar.gz",
      sha256 = "6924efde5de86fe277676e929dc9917d466efa02fb934197bc2eba35d5680971",
      archiveType = "tar.gz",
      executablePath = "bin/go",
      version = "1.23.4",
      packageId = "go@1.23.4",
      extractPath = "go",
      cpu = "x86_64",
      os = "linux"
    tarball url = "https://go.dev/dl/go1.23.4.linux-arm64.tar.gz",
      sha256 = "16e5017863a7f6071363782b1b8042eb12c6ca4f4cd71528b2123f0a1275b13e",
      archiveType = "tar.gz",
      executablePath = "bin/go",
      version = "1.23.4",
      packageId = "go@1.23.4",
      extractPath = "go",
      cpu = "aarch64",
      os = "linux"
    tarball url = "https://go.dev/dl/go1.23.4.darwin-amd64.tar.gz",
      sha256 = "6700067389a53a1607d30aa8d6e01d198230397029faa0b109e89bc871ab5a0e",
      archiveType = "tar.gz",
      executablePath = "bin/go",
      version = "1.23.4",
      packageId = "go@1.23.4",
      extractPath = "go",
      cpu = "x86_64",
      os = "macos"
    tarball url = "https://go.dev/dl/go1.23.4.darwin-arm64.tar.gz",
      sha256 = "87d2bb0ad4fe24d2a0685a55df321e0efe4296419a9b3de03369dbe60b8acd3a",
      archiveType = "tar.gz",
      executablePath = "bin/go",
      version = "1.23.4",
      packageId = "go@1.23.4",
      extractPath = "go",
      cpu = "aarch64",
      os = "macos"
